Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $BaseDir "Harmonic5DImmersion.psd1") -Force
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://127.0.0")
$Listener.Start()
$ImmersionCalls = 0
try {
    while ($Listener.IsListening) {
        $Context = $Listener.GetContext()
        $Req = $Context.Request; $Res = $Context.Response
        $Path = $Req.Url.AbsolutePath.ToLowerInvariant()
        $Method = $Req.HttpMethod.ToUpperInvariant()
        $StatusCode = 200; $ResponseObj = $null
        try {
            if ($Method -eq "GET" -and $Path -eq "/health") {
                $ResponseObj = [ordered]@{ Status = "ONLINE"; ImmersionCalls = $ImmersionCalls; Pid = $PID }
            }
            elseif ($Method -eq "POST" -and $Path -eq "/immerse5d") {
                $Reader = [System.IO.StreamReader]::new($Req.InputStream, $Req.ContentEncoding)
                $Payload = $Reader.ReadToEnd() | ConvertFrom-Json
                $Reader.Close()
                $s5d = [double[]]::new(5)
                $s5d.SetValue([double]$Payload.x, 0)
                $s5d.SetValue([double]$Payload.y, 1)
                $s5d.SetValue([double]$Payload.z, 2)
                $s5d.SetValue([double]$Payload.tau, 3)
                $s5d.SetValue([double]$Payload.psi, 4)
                $proj = Invoke-Universal5DImmersionStep -State5D $s5d -CouplingGain ([double]$Payload.couplingGain) -SiftPurity ([double]$Payload.siftPurity)
                $ImmersionCalls++
                $ResponseObj = [ordered]@{
                    MeanExtrinsicCurvatureH = $proj.MeanExtrinsicCurvatureH
                    ExtrinsicBendingEnergy  = $proj.ExtrinsicBendingEnergy
                    IsometryMaxError        = $proj.IsometryMaxError
                    ImmersedAmbient6D       = $proj.ImmersedAmbient6D
                }
            }
            elseif ($Method -eq "POST" -and $Path -eq "/stop") {
                $Bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ Status = "SHUTTING_DOWN" } | ConvertTo-Json))
                $Res.StatusCode = 200; $Res.ContentType = "application/json"; $Res.ContentLength64 = $Bytes.Length
                $Res.OutputStream.Write($Bytes, 0, $Bytes.Length); $Res.OutputStream.Close()
                break
            }
            else { $StatusCode = 404; $ResponseObj = @{ Error = "Unknown endpoint" } }
        } catch { $StatusCode = 400; $ResponseObj = @{ Error = $_.Exception.Message } }
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes(($ResponseObj | ConvertTo-Json -Depth 5))
        $Res.StatusCode = $StatusCode; $Res.ContentType = "application/json"; $Res.ContentLength64 = $Bytes.Length
        $Res.OutputStream.Write($Bytes, 0, $Bytes.Length); $Res.OutputStream.Close()
    }
} finally { $Listener.Stop(); $Listener.Close() }
