param([int]$Port = 8098)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MasterJson = Join-Path $BaseDir 'amalgamated_master_datum.json'
$ParserScript = Join-Path $BaseDir 'Invoke-AmalgamatedIndexParser.ps1'

if (-not (Test-Path -LiteralPath $MasterJson) -and (Test-Path -LiteralPath $ParserScript)) {
    & $ParserScript | Out-Null
}
$Script:MasterData = if (Test-Path -LiteralPath $MasterJson) {
    [System.IO.File]::ReadAllText($MasterJson, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
} else {
    [pscustomobject]@{ TotalFilesParsed = 0; TotalDatumRows = 0; FileCatalog = @(); JsonArtifacts = @{}; GlobalStatistics = @(); UnifiedTelemetry = @() }
}

$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://localhost:$Port/")
$Listener.Start()
try {
    while ($Listener.IsListening) {
        $Ctx = $Listener.GetContext()
        $Req = $Ctx.Request; $Res = $Ctx.Response
        $Path = $Req.Url.AbsolutePath.ToLowerInvariant()
        $Method = $Req.HttpMethod.ToUpperInvariant()
        $Code = 200; $Out = $null
        try {
            if ($Method -eq 'GET' -and $Path -eq '/health') {
                $Out = [ordered]@{ Status = 'ONLINE'; Engine = 'NativePowerShell7SuiteAPI'; Port = $Port; FilesIndexed = $Script:MasterData.TotalFilesParsed; TotalDatumRows = $Script:MasterData.TotalDatumRows }
            }
            elseif ($Method -eq 'GET' -and $Path -eq '/catalog') {
                $Out = [ordered]@{ FileCatalog = $Script:MasterData.FileCatalog; JsonArtifacts = $Script:MasterData.JsonArtifacts }
            }
            elseif ($Method -eq 'GET' -and $Path -eq '/stats') {
                $Out = @($Script:MasterData.GlobalStatistics)
            }
            elseif ($Method -eq 'GET' -and $Path -eq '/datum') {
                $src = $Req.QueryString['source']
                $st  = $Req.QueryString['status']
                $lim = if ($Req.QueryString['limit']) { [int]$Req.QueryString['limit'] } else { 15 }
                $off = if ($Req.QueryString['offset']) { [int]$Req.QueryString['offset'] } else { 0 }
                $rows = @($Script:MasterData.UnifiedTelemetry)
                if ($src) { $rows = @($rows | Where-Object { $_.SourceFile -like "*$src*" }) }
                if ($st)  { $rows = @($rows | Where-Object { $_.Status -like "*$st*" }) }
                $Out = [ordered]@{ MatchedRows = $rows.Count; Offset = $off; Limit = $lim; Records = @($rows | Select-Object -Skip $off -First $lim) }
            }
            elseif ($Method -eq 'POST' -and $Path -eq '/refresh') {
                if (Test-Path -LiteralPath $ParserScript) { & $ParserScript | Out-Null }
                $Script:MasterData = [System.IO.File]::ReadAllText($MasterJson, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                $Out = [ordered]@{ Status = 'REFRESHED'; TotalDatumRows = $Script:MasterData.TotalDatumRows }
            }
            elseif ($Method -eq 'POST' -and $Path -eq '/stop') {
                $b = [System.Text.Encoding]::UTF8.GetBytes((@{ Status = 'STOPPED' } | ConvertTo-Json -Compress))
                $Res.StatusCode = 200; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $b.Length
                $Res.OutputStream.Write($b, 0, $b.Length); $Res.OutputStream.Close(); break
            }
            else { $Code = 404; $Out = @{ Error = 'Route not found' } }
        } catch { $Code = 400; $Out = @{ Error = $_.Exception.Message } }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Out | ConvertTo-Json -Depth 6 -Compress))
        $Res.StatusCode = $Code; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $bytes.Length
        $Res.OutputStream.Write($bytes, 0, $bytes.Length); $Res.OutputStream.Close()
    }
} finally { $Listener.Stop(); $Listener.Close() }