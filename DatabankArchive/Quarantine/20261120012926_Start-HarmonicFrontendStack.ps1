Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $BaseDir 'HarmonicCore.ps1')

$Port = 8105
while ($true) {
    if (-not (Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)) { break }
    $Port++
}
$Prefix = "http://localhost:$Port/"

$surrPath = Join-Path $BaseDir 'harmonic_surrogate_v4_3.json'
$SurrHash = 'ANALYTICAL_ONLY'; $ModelObj = $null
if (Test-Path -LiteralPath $surrPath) {
    $raw = Get-Content -LiteralPath $surrPath -Raw
    $SurrHash = (Get-Sha256Hex $raw).Substring(0, 16)
    $ModelObj = $raw | ConvertFrom-Json
}

$lockPath = Join-Path $BaseDir 'reproducibility_lock.json'
$LockHash = if (Test-Path -LiteralPath $lockPath) { (Get-Sha256Hex (Get-Content -LiteralPath $lockPath -Raw)).Substring(0, 16) } else { 'NO_LOCK' }
$HtmlPath = Join-Path $BaseDir 'hub.html'

function Save-FrameToVault {
    param($StateObj)
    $auditLine = ([ordered]@{ ts = $StateObj.TimestampUtc; seq = $StateObj.SequenceId; sha256 = $StateObj.Reproducibility.ShortSignature; status = $StateObj.Telemetry.Status; rb = $StateObj.SystemsHeuristics.RbDominanceRatio; bend = $StateObj.Telemetry.RegulatedBend } | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText((Join-Path $BaseDir 'middleware_audit.jsonl'), ($auditLine + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    $dbPath = Join-Path $BaseDir 'harmonic_praxis_vault.db'
    if (Test-Path -LiteralPath $dbPath) {
        $js = "const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv);try{db.prepare('INSERT INTO telemetry_frames(step_seq,coupling_gain,frequency_thz,watermark_wt,regulated_bend,breach_detected)VALUES(?,?,?,?,?,?)').run(Number(process.argv),Number(process.argv),Number(process.argv),Number(process.argv),Number(process.argv),process.argv==='True'?1:0);console.log('SQLITE_OK');}catch(e){console.log('SQLITE_SKIP:'+e.message);}finally{db.close();}"
        return "$(& node -e $js $dbPath $StateObj.SequenceId $StateObj.Telemetry.CouplingGain $StateObj.Telemetry.FrequencyThz $StateObj.Telemetry.WatermarkWt $StateObj.Telemetry.RegulatedBend $StateObj.Telemetry.BreachDetected 2>&1) | AUDIT_OK"
    }
    return "AUDIT_OK"
}

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Prefix)
$Listener.Start()
Write-Host "[ORCHESTRATED HUB ACTIVE] $Prefix" -ForegroundColor Green
Start-Process $Prefix

try {
    while ($Listener.IsListening) {
        $ctx = $Listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
        try {
            if ($req.Url.AbsolutePath -eq '/api/evaluate') {
                $q = $req.QueryString
                $psi = if ($q['psi']) { [double]$q['psi'] } else { 0.5 }
                $gain = if ($q['gain']) { [double]$q['gain'] } else { 0.7 }
                $purity = if ($q['purity']) { [double]$q['purity'] } else { 0.85 }
                $sides = if ($q['sides']) { [int]$q['sides'] } else { 6 }
                $stateObj = Invoke-EvaluateExhaustiveState -Psi $psi -Gain $gain -Purity $purity -Sides $sides -ModelObj $ModelObj -SurrHash $SurrHash -LockHash $LockHash
                $persisted = if ($q['persist'] -eq '1') { Save-FrameToVault -StateObj $stateObj } else { $null }
                $buf = [System.Text.Encoding]::UTF8.GetBytes(([ordered]@{ state = $stateObj; persisted = $persisted } | ConvertTo-Json -Depth 6))
                $res.ContentType = 'application/json; charset=utf-8'
            } else {
                $buf = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $HtmlPath -Raw))
                $res.ContentType = 'text/html; charset=utf-8'
            }
            $res.ContentLength64 = $buf.Length
            $res.OutputStream.Write($buf, 0, $buf.Length)
        } finally { $res.OutputStream.Close() }
    }
} finally { $Listener.Stop(); $Listener.Close() }
