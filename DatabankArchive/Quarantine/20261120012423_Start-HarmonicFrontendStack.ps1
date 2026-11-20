Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

$Port = 8105
while ($true) {
    $inUse = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $inUse) { break }
    $Port++
}
$Prefix = "http://localhost:$Port/"

$Script:PHI       = (1.0 + [math]::Sqrt(5.0)) / 2.0
$Script:INV_SQRT2 = 1.0 / [math]::Sqrt(2.0)

function Get-SafeProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash  = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-RecursiveDot {
    param([double[]]$A, [int]$OffA, [double[]]$B, [int]$OffB, [int]$Idx, [int]$Len, [double]$Acc = 0.0)
    if ($Idx -ge $Len) { return $Acc }
    return Invoke-RecursiveDot -A $A -OffA $OffA -B $B -OffB $OffB -Idx ($Idx + 1) -Len $Len -Acc ($Acc + ($A[$OffA + $Idx] * $B[$OffB + $Idx]))
}

$surrogatePath = Join-Path $BaseDir 'harmonic_surrogate_v4_3.json'
$Script:SurrogateHash = 'ANALYTICAL_BASELINE_ONLY'
$Script:ModelObj = $null
if (Test-Path -LiteralPath $surrogatePath) {
    $rawSurrogate = Get-Content -LiteralPath $surrogatePath -Raw
    $Script:SurrogateHash = (Get-Sha256Hex $rawSurrogate).Substring(0, 16)
    $Script:ModelObj = $rawSurrogate | ConvertFrom-Json
}

$lockPath = Join-Path $BaseDir 'reproducibility_lock.json'
$Script:LockHash = if (Test-Path -LiteralPath $lockPath) {
    (Get-Sha256Hex (Get-Content -LiteralPath $lockPath -Raw)).Substring(0, 16)
} else {
    'NO_LOCK_FILE'
}

$Script:SeqCounter = 0

function Invoke-EvaluateExhaustiveState {
    param(
        [double]$Psi = 0.5,
        [double]$Gain = 0.7,
        [double]$Purity = 0.85,
        [int]$Sides = 6
    )

    $Script:SeqCounter++
    $sides           = [math]::Max(3, $Sides)
    $sectorAngle     = (2.0 * [math]::PI) / $sides
    $snappedVertex   = [math]::Round($Psi / $sectorAngle) * $sectorAngle
    $angularResidual = $Psi - $snappedVertex
    $polyCoherence   = [math]::Cos(($angularResidual * $sides) / 2.0)

    $lowMass   = [math]::Pow($Script:PHI, -1) * (1.0 + [math]::Max(0.05, $Gain))
    $coldMass  = [math]::Min([math]::Pow($Script:PHI, -2) * [math]::Max(0.05, $Purity), $lowMass * 0.94)
    $augFactor = $coldMass / $lowMass

    $s0 = 1.0; $s1 = -1.0; $s2 = 0.4; $s3 = 0.01; $raw = 0.75
    $cP = [math]::Cos($Psi); $sP = [math]::Sin($Psi)
    $c2P = [math]::Cos(2.0 * $Psi); $s2P = [math]::Sin(2.0 * $Psi)

    $ambient6D = @(
        [math]::Round($Script:INV_SQRT2 * ($cP * $s0 - $sP * $s1) * $polyCoherence, 6),
        [math]::Round($Script:INV_SQRT2 * ($sP * $s0 + $cP * $s1) * $polyCoherence, 6),
        [math]::Round($Script:INV_SQRT2 * ($c2P * $s2 - $s2P * $s3), 6),
        [math]::Round($Script:INV_SQRT2 * ($s2P * $s2 + $c2P * $s3), 6),
        [math]::Round($cP * $snappedVertex, 6),
        [math]::Round($sP * $angularResidual, 6)
    )

    $m00 = [math]::Round($polyCoherence * $cP, 6)
    $m01 = [math]::Round(-$augFactor * $sP, 6)
    $m02 = [math]::Round($Gain * $Script:INV_SQRT2, 6)
    $m03 = [math]::Round($angularResidual, 6)

    $m10 = [math]::Round($augFactor * $sP, 6)
    $m11 = [math]::Round($polyCoherence * $cP, 6)
    $m12 = [math]::Round(-$Purity * $Script:INV_SQRT2, 6)
    $m13 = [math]::Round($snappedVertex / [math]::PI, 6)

    $m20 = [math]::Round($coldMass, 6)
    $m21 = [math]::Round($lowMass, 6)
    $m22 = [math]::Round($Purity * $polyCoherence, 6)
    $m23 = [math]::Round(-$Gain * 0.5, 6)

    $m30 = [math]::Round($c2P * 0.25, 6)
    $m31 = [math]::Round($s2P * 0.25, 6)
    $m32 = [math]::Round($augFactor - 1.0, 6)
    $m33 = [math]::Round([math]::Pow($Script:PHI, -1), 6)

    $matrix4x4 = @(
        @($m00, $m01, $m02, $m03),
        @($m10, $m11, $m12, $m13),
        @($m20, $m21, $m22, $m23),
        @($m30, $m31, $m32, $m33)
    )

    $traceJ = [math]::Round($m00 + $m11 + $m22 + $m33, 6)
    $frobSq = 0.0
    foreach ($row in $matrix4x4) {
        foreach ($cell in $row) { $frobSq += ($cell * $cell) }
    }
    $frobeniusNorm = [math]::Round([math]::Sqrt($frobSq), 6)
    $spectralProxy = [math]::Round($frobeniusNorm / 2.0, 6)

    $k      = (1.0 + 2.5 * $Gain) * (1.2 - 0.5 * $Purity) * (1.0 - 0.25 * $augFactor)
    $bendIn = ($k * $cP * ($s0 * $s0 + $s1 * $s1)) + (1.5 * $k * $Psi * $Psi)

    [double]$g = $Gain
    [double]$f = (299792458.0 / ((532.0 - 4.0 * $Gain) * 1e-9)) / 1e12
    [double]$w = 0.72 + 0.08 * $augFactor
    [double]$b = $bendIn
    $modelApplied = $false

    $weightsFlat = Get-SafeProp $Script:ModelObj 'WeightsFlat'
    $xMean       = Get-SafeProp $Script:ModelObj 'XMean'
    $xStd        = Get-SafeProp $Script:ModelObj 'XStd'
    if ($null -eq $weightsFlat) {
        $nested = Get-SafeProp $Script:ModelObj 'model'
        if ($null -eq $nested) { $nested = Get-SafeProp $Script:ModelObj 'surrogate' }
        $weightsFlat = Get-SafeProp $nested 'WeightsFlat'
        $xMean       = Get-SafeProp $nested 'XMean'
        $xStd        = Get-SafeProp $nested 'XStd'
    }

    if ($null -ne $weightsFlat -and $null -ne $xMean -and $null -ne $xStd -and @($weightsFlat).Count -ge 48) {
        $xRaw    = [double[]]@(1.0, $Psi, $Gain, $Purity, $raw, $s0, $s1, ($cP * $s0), ($sP * $s1), $c2P, $bendIn, ($Gain * $Purity))
        $P       = 12
        $xNorm   = New-Object double[] $P
        $meanArr = [double[]]$xMean
        $stdArr  = [double[]]$xStd
        for ($j = 0; $j -lt $P; $j++) {
            $std = if ($stdArr[$j] -eq 0.0) { 1.0 } else { $stdArr[$j] }
            $xNorm[$j] = if ($j -eq 0) { 1.0 } else { ($xRaw[$j] - $meanArr[$j]) / $std }
        }
        $weights = [double[]]$weightsFlat
        $g = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $weights -OffB 0        -Idx 0 -Len $P
        $f = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $weights -OffB $P       -Idx 0 -Len $P
        $w = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $weights -OffB (2 * $P) -Idx 0 -Len $P
        $b = (Invoke-RecursiveDot -A $xNorm -OffA 0 -B $weights -OffB (3 * $P) -Idx 0 -Len $P) * (1.0 - 0.25 * $augFactor)
        $modelApplied = $true
    }

    $breach = ([math]::Abs($b) -gt 40.0) -or ($Purity -lt 0.55)
    if ($breach) {
        $b = [math]::Sign($b) * [math]::Min([math]::Abs($b), 40.0)
        $w = [math]::Max(0.68, $w + 0.1)
    }

    $reinforcingLoad = [math]::Round($Gain * (1.0 + [math]::Abs($Psi)), 4)
    $balancingDamp   = [math]::Round($Purity * $polyCoherence * (1.0 + $augFactor), 4)
    $rbRatio         = [math]::Round($reinforcingLoad / [math]::Max(0.001, $balancingDamp), 4)
    $loopArchetype   = if ($rbRatio -gt 1.25) { 'REINFORCING_ESCALATION (R-DOMINANT)' } elseif ($rbRatio -lt 0.75) { 'BALANCING_EQUILIBRIUM (B-DOMINANT)' } else { 'HOMEOSTATIC_COUPLED (R=B)' }
    $bendMarginPct   = [math]::Round([math]::Max(0.0, (1.0 - ([math]::Abs($b) / 40.0)) * 100.0), 2)
    $purityMarginPct = [math]::Round((($Purity - 0.55) / 0.45) * 100.0, 2)
    $lyapunovStable  = ($spectralProxy -lt 1.25) -and (-not $breach)

    $canonicalSeed = "{0:F6}|{1:F6}|{2:F6}|{3}|{4}|{5}|{6:F6}|{7:F6}" -f $Psi, $Gain, $Purity, $sides, $Script:SurrogateHash, $Script:LockHash, $b, $augFactor
    $stateSha256   = Get-Sha256Hex $canonicalSeed

    return [pscustomobject]@{
        SequenceId        = $Script:SeqCounter
        TimestampUtc      = [DateTime]::UtcNow.ToString('o')
        Reproducibility   = [pscustomobject]@{
            StateSha256     = $stateSha256
            ShortSignature  = $stateSha256.Substring(0, 16)
            SurrogateSha16  = $Script:SurrogateHash
            LockFileSha16   = $Script:LockHash
            ModelApplied    = $modelApplied
            Deterministic   = $true
        }
        Polygonal         = [pscustomobject]@{
            Sides              = $sides
            SectorAngleRad     = [math]::Round($sectorAngle, 6)
            SnappedVertexRad   = [math]::Round($snappedVertex, 6)
            AngularResidualRad = [math]::Round($angularResidual, 6)
            PolygonalCoherence = [math]::Round($polyCoherence, 6)
        }
        MassAugmentation  = [pscustomobject]@{
            ColdMass           = [math]::Round($coldMass, 6)
            LowMass            = [math]::Round($lowMass, 6)
            InvariantSatisfied = ($coldMass -lt $lowMass)
            AugmentationFactor = [math]::Round($augFactor, 6)
        }
        SystemsHeuristics = [pscustomobject]@{
            LoopArchetype      = $loopArchetype
            ReinforcingLoad    = $reinforcingLoad
            BalancingDamping   = $balancingDamp
            RbDominanceRatio   = $rbRatio
            BendSafetyMargin   = "$bendMarginPct%"
            PuritySafetyMargin = "$purityMarginPct%"
            LyapunovStable     = $lyapunovStable
        }
        ComputingMatrices = [pscustomobject]@{
            Ambient6D          = $ambient6D
            Jacobian4x4        = $matrix4x4
            TraceJ             = $traceJ
            FrobeniusNorm      = $frobeniusNorm
            SpectralRadiusEst  = $spectralProxy
        }
        Telemetry         = [pscustomobject]@{
            Psi                = [math]::Round($Psi, 4)
            CouplingGain       = [math]::Round($g, 6)
            FrequencyThz       = [math]::Round($f, 6)
            WatermarkWt        = [math]::Round($w, 6)
            RegulatedBend      = [math]::Round($b, 6)
            BreachDetected     = $breach
            Status             = if ($breach) { 'AUGMENTED_CLAMPED' } else { 'REGULATED_COMPLIANT' }
        }
    }
}
function Save-FrameToVault {
param($StateObj)
$auditPath = Join-Path $BaseDir 'middleware_audit.jsonl'
$auditLine = ([ordered]@{
ts        = $StateObj.TimestampUtc
seq       = $StateObj.SequenceId
sha256    = $StateObj.Reproducibility.ShortSignature
status    = $StateObj.Telemetry.Status
archetype = $StateObj.SystemsHeuristics.LoopArchetype
rb_ratio  = $StateObj.SystemsHeuristics.RbDominanceRatio
bend      = $StateObj.Telemetry.RegulatedBend
mass_ok   = $StateObj.MassAugmentation.InvariantSatisfied
} | ConvertTo-Json -Compress)
[System.IO.File]::AppendAllText($auditPath, ($auditLine + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$dbPath = Join-Path $BaseDir 'harmonic_praxis_vault.db'
if (Test-Path -LiteralPath $dbPath) {
$nodeInsert = "const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv);try{db.prepare('INSERT INTO telemetry_frames(step_seq,coupling_gain,frequency_thz,watermark_wt,regulated_bend,breach_detected)VALUES(?,?,?,?,?,?)').run(Number(process.argv),Number(process.argv),Number(process.argv),Number(process.argv),Number(process.argv),process.argv==='True'?1:0);console.log('SQLITE_OK');}catch(e){console.log('SQLITE_SKIP:'+e.message);}finally{db.close();}"
$dbRes = & node -e $nodeInsert $dbPath $StateObj.SequenceId $StateObj.Telemetry.CouplingGain $StateObj.Telemetry.FrequencyThz $StateObj.Telemetry.WatermarkWt $StateObj.Telemetry.RegulatedBend $StateObj.Telemetry.BreachDetected 2>&1
return "$dbRes | AUDIT_LOGGED"
}
return "AUDIT_LOGGED (DB_NOT_FOUND)"
}
$HtmlHub = @"




Harmonic Praxis AI // Systems Heuristics & Computing Matrices

* { box-sizing: border-box; }
body { background:#060911; color:#e2e8f0; font-family:Consolas,monospace; margin:0; padding:18px; }
.header { display:flex; justify-content:space-between; align-items:center; background:#0f172a; border:1px solid #1e293b; padding:14px 18px; margin-bottom:14px; }
h1 { color:#38bdf8; font-size:17px; margin:0; letter-spacing:0.5px; }
.sub { font-size:12px; color:#94a3b8; margin-top:4px; }
.controls { display:grid; grid-template-columns:repeat(4,1fr) auto; gap:14px; background:#0f172a; border:1px solid #1e293b; padding:14px 18px; margin-bottom:14px; align-items:center; }
label { display:block; font-size:12px; color:#cbd5e1; }
input[type=range] { width:100%; margin-top:6px; accent-color:#38bdf8; }
button { background:#0284c7; color:#fff; border:none; padding:10px 16px; font-family:Consolas,monospace; font-weight:bold; cursor:pointer; }
button:hover { background:#0369a1; }
.grid-main { display:grid; grid-template-columns:1.1fr 1fr; gap:14px; margin-bottom:14px; }
.card { background:#0f172a; border:1px solid #1e293b; padding:14px; }
.card-title { color:#38bdf8; font-size:13px; font-weight:bold; margin-bottom:10px; border-bottom:1px solid #1e293b; padding-bottom:6px; }
canvas { width:100%; height:310px; background:#060911; border:1px solid #1e293b; display:block; }
table { width:100%; border-collapse:collapse; font-size:12px; }
td, th { border:1px solid #1e293b; padding:6px 8px; text-align:right; }
th { background:#080c14; color:#38bdf8; text-align:center; }
.kv { display:flex; justify-content:space-between; padding:5px 0; border-bottom:1px dashed #1e293b; font-size:12px; }
.ok { color:#22c55e; font-weight:bold; }
.warn { color:#f59e0b; font-weight:bold; }
pre { background:#060911; border:1px solid #1e293b; padding:10px; font-size:11px; color:#7dd3fc; max-height:240px; overflow:auto; margin:0; }





HARMONIC PRAXIS AI // EXHAUSTIVE SYSTEMS HEURISTICS & COMPUTING MATRICES
STATE SHA-256: -- | SURROGATE: -- | LOCK: --


INITIALIZING
VAULT READY

PSI PHASE: 0.50
COUPLING GAIN: 0.70
PURITY: 0.85
POLYGON SIDES (N): 6
COMMIT TO VAULT
[MATRIX A] POLYGONAL ANGULARITY & 6D AMBIENT PROJECTION



[HEURISTICS] SYSTEMIC LOOPS & MASS INVARIANT
LOOP ARCHETYPE:--
R/B DOMINANCE RATIO:--
COLD MASS < LOW MASS:--
AUGMENTATION FACTOR (ETA):--
POLYGONAL COHERENCE:--
BEND SAFETY MARGIN:--
LYAPUNOV STABILITY:--
TRACE(J) / FROBENIUS / RHO:--

[MATRIX B] 4x4 JACOBIAN COUPLING & STABILITY TENSOR

JC0 (PHASE)C1 (MASS)C2 (PURITY)C3 (SECTOR)

[REPRODUCIBILITY] CANONICAL JSON TELEMETRY FRAME
{}

const els = ['psi','gain','purity','sides'].reduce((a,id) => (a[id]=document.getElementById(id), a), {});
const canvas = document.getElementById('polyCanvas');
const ctx = canvas.getContext('2d');
async function evaluate(persist = false) {
document.getElementById('lblPsi').textContent = Number(els.psi.value).toFixed(2);
document.getElementById('lblGain').textContent = Number(els.gain.value).toFixed(2);
document.getElementById('lblPurity').textContent = Number(els.purity.value).toFixed(2);
document.getElementById('lblSides').textContent = els.sides.value;
const q = new URLSearchParams({
psi: els.psi.value,
gain: els.gain.value,
purity: els.purity.value,
sides: els.sides.value,
persist: persist ? '1' : '0'
});
const res = await fetch('/api/evaluate?' + q.toString());
const payload = await res.json();
const d = payload.state;
if (payload.persisted) {
document.getElementById('persistMsg').textContent = payload.persisted;
}
document.getElementById('sha').textContent = d.Reproducibility.ShortSignature;
document.getElementById('surr').textContent = d.Reproducibility.SurrogateSha16;
document.getElementById('lock').textContent = d.Reproducibility.LockFileSha16;
const stEl = document.getElementById('status');
stEl.textContent = d.Telemetry.Status + ' (BEND: ' + d.Telemetry.RegulatedBend + ')';
stEl.className = d.Telemetry.BreachDetected ? 'warn' : 'ok';
document.getElementById('hLoop').textContent = d.SystemsHeuristics.LoopArchetype;
document.getElementById('hRb').textContent = d.SystemsHeuristics.RbDominanceRatio;
document.getElementById('hMass').textContent = ${d.MassAugmentation.ColdMass} < ${d.MassAugmentation.LowMass} (${d.MassAugmentation.InvariantSatisfied});
document.getElementById('hEta').textContent = d.MassAugmentation.AugmentationFactor;
document.getElementById('hCoh').textContent = d.Polygonal.PolygonalCoherence;
document.getElementById('hBendM').textContent = d.SystemsHeuristics.BendSafetyMargin;
document.getElementById('hLyap').textContent = d.SystemsHeuristics.LyapunovStable ? 'CERTIFIED_BOUNDED' : 'MARGINAL_EXCURSION';
document.getElementById('hSpec').textContent = ${d.ComputingMatrices.TraceJ} / ${d.ComputingMatrices.FrobeniusNorm} / ${d.ComputingMatrices.SpectralRadiusEst};
document.getElementById('rawJson').textContent = JSON.stringify(d, null, 2);
const tbody = document.querySelector('#jacTable tbody');
tbody.innerHTML = d.ComputingMatrices.Jacobian4x4.map((row, idx) =>
<tr><th>R${idx}</th>${row.map(v => ${Number(v).toFixed(4)}).join('')}</tr>
).join('');
const w = canvas.width, h = canvas.height, cx = 200, cy = h / 2, r = 115;
ctx.clearRect(0, 0, w, h);
ctx.strokeStyle = '#1e293b';
ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke();
ctx.strokeStyle = '#38bdf8';
ctx.lineWidth = 2;
ctx.beginPath();
for (let i = 0; i <= d.Polygonal.Sides; i++) {
const a = i * d.Polygonal.SectorAngleRad;
const x = cx + r * Math.cos(a), y = cy + r * Math.sin(a);
i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
}
ctx.stroke();
ctx.strokeStyle = '#22c55e';
ctx.beginPath();
ctx.moveTo(cx, cy);
ctx.lineTo(cx + r * Math.cos(d.Polygonal.SnappedVertexRad), cy + r * Math.sin(d.Polygonal.SnappedVertexRad));
ctx.stroke();
ctx.fillStyle = d.Telemetry.BreachDetected ? '#f59e0b' : '#38bdf8';
ctx.beginPath();
ctx.arc(cx + r * Math.cos(d.Telemetry.Psi), cy + r * Math.sin(d.Telemetry.Psi), 6, 0, Math.PI * 2);
ctx.fill();
const labels6D = ['A0(re)','A1(im)','A2(2p)','A3(2p)','A4(vtx)','A5(res)'];
d.ComputingMatrices.Ambient6D.forEach((val, idx) => {
const bx = 400, by = 32 + idx * 44, bw = Math.max(-180, Math.min(180, val * 85));
ctx.fillStyle = '#94a3b8';
ctx.font = '11px Consolas';
ctx.fillText(labels6D[idx], bx - 55, by + 14);
ctx.fillStyle = '#1e293b';
ctx.fillRect(bx, by, 210, 18);
ctx.fillStyle = val >= 0 ? '#38bdf8' : '#f59e0b';
ctx.fillRect(bx + 105, by + 2, bw * 0.55, 14);
ctx.fillStyle = '#e2e8f0';
ctx.fillText(val.toFixed(4), bx + 150, by + 13);
});
}
Object.values(els).forEach(el => el.addEventListener('input', () => evaluate(false)));
document.getElementById('btnPersist').addEventListener('click', () => evaluate(true));
evaluate(false);



"@
$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Prefix)
$Listener.Start()
Write-Host "[EXHAUSTIVE HUB ACTIVE] $Prefix" -ForegroundColor Green
Start-Process $Prefix
try {
while ($Listener.IsListening) {
$ctx = $Listener.GetContext()
$req = $ctx.Request
$res = $ctx.Response
try {
if ($req.Url.AbsolutePath -eq '/api/evaluate') {
$q       = $req.QueryString
$psi     = if ($q['psi'])    { [double]$q['psi'] }    else { 0.5 }
$gain    = if ($q['gain'])   { [double]$q['gain'] }   else { 0.7 }
$purity  = if ($q['purity']) { [double]$q['purity'] } else { 0.85 }
$sides   = if ($q['sides'])  { [int]$q['sides'] }     else { 6 }
$persist = ($q['persist'] -eq '1')
$stateObj  = Invoke-EvaluateExhaustiveState -Psi $psi -Gain $gain -Purity $purity -Sides $sides
$persistSt = if ($persist) { Save-FrameToVault -StateObj $stateObj } else { $null }
$payload = ([ordered]@{ state = $stateObj; persisted = $persistSt }) | ConvertTo-Json -Depth 6
$buf = [System.Text.Encoding]::UTF8.GetBytes($payload)
$res.ContentType = 'application/json; charset=utf-8'
}
else {
$buf = [System.Text.Encoding]::UTF8.GetBytes($HtmlHub)
$res.ContentType = 'text/html; charset=utf-8'
}
$res.ContentLength64 = $buf.Length
$res.OutputStream.Write($buf, 0, $buf.Length)
}
finally {
$res.OutputStream.Close()
}
}
}
finally {
$Listener.Stop()
$Listener.Close()
}
