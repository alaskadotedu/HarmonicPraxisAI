param([int]$Port = 8090)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Artifact = Get-Content -LiteralPath (Join-Path $BaseDir 'harmonic_recursive_remediation_v5_1.json') -Raw | ConvertFrom-Json
[double[]]$WFlat = $Artifact.WeightsFlat
[double[]]$XMean = $Artifact.XMean
[double[]]$XStd  = $Artifact.XStd
$P = 12

function Invoke-RecursiveDot([double[]]$A, [int]$OffA, [double[]]$B, [int]$OffB, [int]$Idx, [int]$Len, [double]$Acc) {
    if ($Idx -ge $Len) { return $Acc }
    return (Invoke-RecursiveDot -A $A -OffA $OffA -B $B -OffB $OffB -Idx ($Idx + 1) -Len $Len -Acc ($Acc + ([double]$A.GetValue($OffA + $Idx) * [double]$B.GetValue($OffB + $Idx))))
}

$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://127.0.0.1:$Port/")
$Listener.Start()
$Requests = 0; $BreachesFixed = 0
try {
    while ($Listener.IsListening) {
        $Ctx = $Listener.GetContext()
        $Req = $Ctx.Request; $Res = $Ctx.Response
        $Path = $Req.Url.AbsolutePath.ToLowerInvariant()
        $Method = $Req.HttpMethod.ToUpperInvariant()
        $Code = 200; $OutObj = $null
        try {
            if ($Method -eq 'GET' -and $Path -eq '/health') {
                $OutObj = [ordered]@{ Status = 'ONLINE'; Version = $Artifact.Version; Port = $Port; RecursiveSolver = $true; RequestsServed = $Requests; BreachesRemediated = $BreachesFixed }
            }
            elseif ($Method -eq 'POST' -and $Path -eq '/remediate') {
                $Rdr = [System.IO.StreamReader]::new($Req.InputStream, $Req.ContentEncoding)
                $In = $Rdr.ReadToEnd() | ConvertFrom-Json; $Rdr.Close()
                $psi = [double]$In.psi; $gain = [double]$In.gain; $purity = [double]$In.purity; $raw = [double]$In.rawScore; $s0 = [double]$In.s0; $s1 = [double]$In.s1
                $cP = [math]::Cos($psi); $sP = [math]::Sin($psi); $c2P = [math]::Cos(2.0 * $psi)
                $k = (1.0 + 2.5 * $gain) * (1.2 - 0.5 * $purity)
                $bendIn = ($k * $cP * ($s0 * $s0 + $s1 * $s1)) + (1.5 * $k * $psi * $psi)
                $xRaw = [double[]]::new($P)
                $xRaw.SetValue(1.0, 0); $xRaw.SetValue($psi, 1); $xRaw.SetValue($gain, 2); $xRaw.SetValue($purity, 3); $xRaw.SetValue($raw, 4); $xRaw.SetValue($s0, 5)
                $xRaw.SetValue($s1, 6); $xRaw.SetValue(($cP * $s0), 7); $xRaw.SetValue(($sP * $s1), 8); $xRaw.SetValue($c2P, 9); $xRaw.SetValue($bendIn, 10); $xRaw.SetValue(($gain * $purity), 11)
                $xNorm = [double[]]::new($P)
                $xNorm.SetValue(1.0, 0)
                for ($j = 1; $j -lt $P; $j++) { $xNorm.SetValue((([double]$xRaw.GetValue($j) - [double]$XMean.GetValue($j)) / [double]$XStd.GetValue($j)), $j) }
                $g = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $WFlat -OffB (0 * $P) -Idx 0 -Len $P -Acc 0.0
                $f = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $WFlat -OffB (1 * $P) -Idx 0 -Len $P -Acc 0.0
                $w = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $WFlat -OffB (2 * $P) -Idx 0 -Len $P -Acc 0.0
                $b = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $WFlat -OffB (3 * $P) -Idx 0 -Len $P -Acc 0.0
                $breach = ([math]::Abs($b) -gt 40.0 -or $purity -lt 0.55)
                if ($breach) { $BreachesFixed++; $b = [math]::Sign($b) * [math]::Min([math]::Abs($b), 40.0); $w = [math]::Max(0.68, $w + 0.10) }
                $Requests++
                $OutObj = [ordered]@{ CouplingGain = [math]::Round($g, 6); FrequencyThz = [math]::Round($f, 6); WatermarkWt = [math]::Round($w, 6); RegulatedBend = [math]::Round($b, 6); BreachDetected = $breach; Status = 'REGULATED_COMPLIANT' }
            }
            elseif ($Method -eq 'POST' -and $Path -eq '/stop') {
                $Bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ Status = 'STOPPED' } | ConvertTo-Json -Compress))
                $Res.StatusCode = 200; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $Bytes.Length
                $Res.OutputStream.Write($Bytes, 0, $Bytes.Length); $Res.OutputStream.Close(); break
            }
            else { $Code = 404; $OutObj = @{ Error = 'Endpoint not found' } }
        } catch { $Code = 400; $OutObj = @{ Error = $_.Exception.Message } }
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes(($OutObj | ConvertTo-Json -Depth 4 -Compress))
        $Res.StatusCode = $Code; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $Bytes.Length
        $Res.OutputStream.Write($Bytes, 0, $Bytes.Length); $Res.OutputStream.Close()
    }
} finally { $Listener.Stop(); $Listener.Close() }