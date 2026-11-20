Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $BaseDir 'HarmonicJacobianEngine.ps1')

$Port = 8120
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

$HtmlPath = Join-Path $BaseDir 'jacobian_hub.html'

function Save-JacobianVault {
    param($StateObj)
    $audit = ([ordered]@{ ts = $StateObj.TimestampUtc; sha = $StateObj.StateHash16; det = $StateObj.JacobianTensor.Determinant; rho = $StateObj.JacobianTensor.SpectralRadius; cond = $StateObj.JacobianTensor.ConditionNumber; bend = $StateObj.ObservableY.RegulatedBend } | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText((Join-Path $BaseDir 'middleware_audit.jsonl'), ($audit + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    $dbPath = Join-Path $BaseDir 'harmonic_praxis_vault.db'
    if (Test-Path -LiteralPath $dbPath) {
        $js = "const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);try{db.prepare('INSERT INTO telemetry_frames(step_seq,coupling_gain,frequency_thz,watermark_wt,regulated_bend,breach_detected)VALUES(?,?,?,?,?,?)').run(Number(process.argv[2]),Number(process.argv[3]),Number(process.argv[4]),Number(process.argv[5]),Number(process.argv[6]),process.argv[7]==='True'?1:0);console.log('SQLITE_OK');}catch(e){console.log('SQLITE_SKIP:'+e.message);}finally{db.close();}"
        return "$(& node -e $js $dbPath $StateObj.EvalId $StateObj.ObservableY.CouplingGain $StateObj.ObservableY.FrequencyThz $StateObj.ObservableY.WatermarkWt $StateObj.ObservableY.RegulatedBend $StateObj.BreachDetected 2>&1) | AUDIT_OK"
    }
    return "AUDIT_OK"
}

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Prefix)
$Listener.Start()
Write-Host "[JACOBIAN MATRIX ENGINE ACTIVE] $Prefix" -ForegroundColor Green
Start-Process $Prefix

try {
    while ($Listener.IsListening) {
        $ctx = $Listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
        try {
            if ($req.Url.AbsolutePath -eq '/api/jacobian') {
                $q      = $req.QueryString
                $psi    = if ($q['psi'])    { [double]$q['psi'] }    else { 0.5 }
                $gain   = if ($q['gain'])   { [double]$q['gain'] }   else { 0.7 }
                $purity = if ($q['purity']) { [double]$q['purity'] } else { 0.85 }
                $alpha  = if ($q['alpha'])  { [double]$q['alpha'] }  else { 0.5 }
                $sides  = if ($q['sides'])  { [int]$q['sides'] }     else { 6 }
                $solve  = ($q['solve'] -eq '1')

                $stateObj  = Invoke-JacobianEngine -Psi $psi -Gain $gain -Purity $purity -Alpha $alpha -Sides $sides -SolveEquilibrium:$solve -ModelObj $ModelObj -SurrHash $SurrHash
                $persisted = if ($q['persist'] -eq '1') { Save-JacobianVault -StateObj $stateObj } else { $null }

                $buf = [System.Text.Encoding]::UTF8.GetBytes(([ordered]@{ state = $stateObj; persisted = $persisted } | ConvertTo-Json -Depth 6))
                $res.ContentType = 'application/json; charset=utf-8'
            } else {
                $buf = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $HtmlPath -Raw))
                $res.ContentType = 'text/html; charset=utf-8'
            }
            $res.ContentLength64 = $buf.Length
            $res.OutputStream.Write($buf, 0, $buf.Length)
        } catch {
            $errBuf = [System.Text.Encoding]::UTF8.GetBytes((@{ error = $_.Exception.Message } | ConvertTo-Json))
            $res.StatusCode = 500
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($errBuf, 0, $errBuf.Length)
        } finally {
            $res.OutputStream.Close()
        }
    }
} finally {
    $Listener.Stop()
    $Listener.Close()
}
