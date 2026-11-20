param([int]$Port = 8099)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HtmlFile = Join-Path $BaseDir 'index.html'
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://localhost:$Port/")
$Listener.Start()
try {
    while ($Listener.IsListening) {
        $Ctx = $Listener.GetContext()
        $Req = $Ctx.Request; $Res = $Ctx.Response
        $Path = $Req.Url.AbsolutePath.ToLowerInvariant()
        $Method = $Req.HttpMethod.ToUpperInvariant()
        if ($Method -eq 'GET' -and $Path -eq '/') {
            $bytes = [System.IO.File]::ReadAllBytes($HtmlFile)
            $Res.StatusCode = 200; $Res.ContentType = 'text/html; charset=utf-8'; $Res.ContentLength64 = $bytes.Length
            $Res.OutputStream.Write($bytes, 0, $bytes.Length); $Res.OutputStream.Close(); continue
        }
        $Code = 200; $Out = $null
        try {
            if ($Method -eq 'GET' -and $Path -eq '/api/dashboard') {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem
                $ram = [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100.0, 2)
                $procs = @(Get-Process).Count
                $mCsv = Join-Path $BaseDir 'dew_actionable_remediation_matrix.csv'
                $matrix = if (Test-Path -LiteralPath $mCsv) { @(Import-Csv -LiteralPath $mCsv) } else { @() }
                $aCsv = Join-Path $BaseDir 'amalgamated_telemetry_index.csv'
                $tRows = if (Test-Path -LiteralPath $aCsv) { @(Import-Csv -LiteralPath $aCsv).Count } else { 0 }
                $Out = [ordered]@{ TimestampUtc = [DateTime]::UtcNow.ToString('o'); FreeMemPct = $ram; ProcCount = $procs; TotalDatumRows = $tRows; Matrix = $matrix }
            }
            elseif ($Method -eq 'POST' -and $Path -eq '/api/audit') {
                $auditScript = Join-Path $BaseDir 'Invoke-PerennialDewFullStack.ps1'
                if (Test-Path -LiteralPath $auditScript) { & $auditScript | Out-Null }
                $Out = @{ Status = 'AUDIT_EXECUTED' }
            }
            elseif ($Method -eq 'POST' -and $Path -eq '/stop') {
                $b = [System.Text.Encoding]::UTF8.GetBytes((@{ Status = 'STOPPED' } | ConvertTo-Json -Compress))
                $Res.StatusCode = 200; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $b.Length
                $Res.OutputStream.Write($b, 0, $b.Length); $Res.OutputStream.Close(); break
            }
            else { $Code = 404; $Out = @{ Error = 'Not found' } }
        } catch { $Code = 500; $Out = @{ Error = $_.Exception.Message } }
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes(($Out | ConvertTo-Json -Depth 5 -Compress))
        $Res.StatusCode = $Code; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $jsonBytes.Length
        $Res.OutputStream.Write($jsonBytes, 0, $jsonBytes.Length); $Res.OutputStream.Close()
    }
} finally { $Listener.Stop(); $Listener.Close() }