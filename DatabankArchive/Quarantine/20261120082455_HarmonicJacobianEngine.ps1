Set-StrictMode -Version Latest
$Script:PHI       = (1.0 + [math]::Sqrt(5.0)) / 2.0
$Script:INV_SQRT2 = 1.0 / [math]::Sqrt(2.0)
$Script:EvalCount = 0

function Get-SafeProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-RecursiveDot {
    param([double[]]$A, [int]$OffA, [double[]]$B, [int]$OffB, [int]$Idx, [int]$Len, [double]$Acc = 0.0)
    if ($Idx -ge $Len) { return $Acc }
    return Invoke-RecursiveDot -A $A -OffA $OffA -B $B -OffB $OffB -Idx ($Idx + 1) -Len $Len -Acc ($Acc + ($A[$OffA + $Idx] * $B[$OffB + $Idx]))
}

function Invoke-ForwardManifold {
    param([double]$Psi, [double]$Gain, [double]$Purity, [double]$Alpha, [int]$Sides = 6, $ModelObj = $null)
    $sides = [math]::Max(3, [math]::Min(32, $Sides))
    $sectorAngle = (2.0 * [math]::PI) / $sides
    $snappedVertex = [math]::Round($Psi / $sectorAngle) * $sectorAngle
    $angularResidual = $Psi - $snappedVertex
    $polyCoherence = [math]::Cos(($angularResidual * $sides) / 2.0)

    $lowMass = [math]::Pow($Script:PHI, -1) * (1.0 + [math]::Max(0.05, $Gain))
    $coldMass = [math]::Min([math]::Pow($Script:PHI, -2) * [math]::Max(0.05, $Purity), $lowMass * 0.94)
    $augFactor = $coldMass / $lowMass

    $s0 = 1.0; $s1 = -1.0; $s2 = 0.4; $s3 = 0.01; $raw = 0.75
    $cP = [math]::Cos($Psi); $sP = [math]::Sin($Psi); $c2P = [math]::Cos(2.0 * $Psi); $s2P = [math]::Sin(2.0 * $Psi)
    $ambient6D = @(
        ($Script:INV_SQRT2 * ($cP * $s0 - $sP * $s1) * $polyCoherence),
        ($Script:INV_SQRT2 * ($sP * $s0 + $cP * $s1) * $polyCoherence),
        ($Script:INV_SQRT2 * ($c2P * $s2 - $s2P * $s3)),
        ($Script:INV_SQRT2 * ($s2P * $s2 + $c2P * $s3)),
        ($cP * $snappedVertex),
        ($sP * $angularResidual)
    )

    $k = (1.0 + 2.5 * $Gain) * (1.2 - 0.5 * $Purity) * (1.0 - 0.25 * $augFactor)
    $bendAnalytical = ($k * $cP * ($s0 * $s0 + $s1 * $s1)) + (1.5 * $k * $Psi * $Psi)
    [double]$gEmp = $Gain; [double]$fEmp = (299792458.0 / ((532.0 - 4.0 * $Gain) * 1e-9)) / 1e12
    [double]$wEmp = 0.72 + 0.08 * $augFactor; [double]$bEmp = $bendAnalytical; $modelApplied = $false

    $wf = Get-SafeProp $ModelObj 'WeightsFlat'; $xm = Get-SafeProp $ModelObj 'XMean'; $xs = Get-SafeProp $ModelObj 'XStd'
    if ($null -eq $wf) {
        $n = Get-SafeProp $ModelObj 'model'; if ($null -eq $n) { $n = Get-SafeProp $ModelObj 'surrogate' }
        $wf = Get-SafeProp $n 'WeightsFlat'; $xm = Get-SafeProp $n 'XMean'; $xs = Get-SafeProp $n 'XStd'
    }
    if ($null -ne $wf -and $null -ne $xm -and $null -ne $xs -and @($wf).Count -ge 48) {
        $xRaw = [double[]]@(1.0, $Psi, $Gain, $Purity, $raw, $s0, $s1, ($cP * $s0), ($sP * $s1), $c2P, $bendAnalytical, ($Gain * $Purity))
        $xNorm = New-Object double[] 12; $ma = [double[]]$xm; $sa = [double[]]$xs
        for ($j = 0; $j -lt 12; $j++) { $std = if ($sa[$j] -eq 0.0) { 1.0 } else { $sa[$j] }; $xNorm[$j] = if ($j -eq 0) { 1.0 } else { ($xRaw[$j] - $ma[$j]) / $std } }
        $wts = [double[]]$wf
        $gEmp = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 0 -Idx 0 -Len 12
        $fEmp = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 12 -Idx 0 -Len 12
        $wEmp = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 24 -Idx 0 -Len 12
        $bEmp = (Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 36 -Idx 0 -Len 12) * (1.0 - 0.25 * $augFactor)
        $modelApplied = $true
    }

    $effAlpha = if ($modelApplied) { [math]::Max(0.0, [math]::Min(1.0, $Alpha)) } else { [math]::Max(0.0, [math]::Min(1.0, $Alpha)) * 0.15 }
    [double]$g = ((1.0 - $effAlpha) * $Gain) + ($effAlpha * ($gEmp + 0.12 * $polyCoherence))
    [double]$f = ((1.0 - $effAlpha) * ((299792458.0 / ((532.0 - 4.0 * $Gain) * 1e-9)) / 1e12)) + ($effAlpha * ($fEmp + 0.45 * $augFactor))
    [double]$w = ((1.0 - $effAlpha) * (0.72 + 0.08 * $augFactor)) + ($effAlpha * ($wEmp + 0.04 * $Purity))
    [double]$b = ((1.0 - $effAlpha) * $bendAnalytical) + ($effAlpha * ($bEmp * (1.0 - 0.15 * $augFactor)))

    return [pscustomobject]@{
        YVec = [double[]]@($g, $f, $w, $b); Ambient6D = $ambient6D; ColdMass = $coldMass; LowMass = $lowMass
        AugFactor = $augFactor; Coherence = $polyCoherence; SnappedRad = $snappedVertex; ResidualRad = $angularResidual
        SectorRad = $sectorAngle; ModelApplied = $modelApplied
    }
}

function Invoke-InvertMatrix4x4 {
    param([double[][]]$M)
    $aug = New-Object 'double[][]' 4
    for ($i = 0; $i -lt 4; $i++) {
        $aug[$i] = New-Object double[] 8
        for ($j = 0; $j -lt 4; $j++) { $aug[$i][$j] = $M[$i][$j] }
        $aug[$i][4 + $i] = 1.0
    }
    [double]$det = 1.0
    for ($col = 0; $col -lt 4; $col++) {
        $pivot = $col
        for ($row = $col + 1; $row -lt 4; $row++) {
            if ([math]::Abs($aug[$row][$col]) -gt [math]::Abs($aug[$pivot][$col])) { $pivot = $row }
        }
        if ($pivot -ne $col) { $tmp = $aug[$col]; $aug[$col] = $aug[$pivot]; $aug[$pivot] = $tmp; $det = -$det }
        $diag = $aug[$col][$col]
        if ([math]::Abs($diag) -lt 1e-12) { return [pscustomobject]@{ Singular = $true; Determinant = 0.0; Inverse = $null } }
        $det *= $diag
        for ($j = 0; $j -lt 8; $j++) { $aug[$col][$j] /= $diag }
        for ($row = 0; $row -lt 4; $row++) {
            if ($row -ne $col) {
                $factor = $aug[$row][$col]
                for ($j = 0; $j -lt 8; $j++) { $aug[$row][$j] -= $factor * $aug[$col][$j] }
            }
        }
    }
    $inv = New-Object 'double[][]' 4
    for ($i = 0; $i -lt 4; $i++) {
        $inv[$i] = New-Object double[] 4
        for ($j = 0; $j -lt 4; $j++) { $inv[$i][$j] = $aug[$i][4 + $j] }
    }
    return [pscustomobject]@{ Singular = $false; Determinant = $det; Inverse = $inv }
}

function Get-MatrixFrobenius {
    param([double[][]]$M)
    [double]$sum = 0.0
    for ($i = 0; $i -lt 4; $i++) { for ($j = 0; $j -lt 4; $j++) { $sum += ($M[$i][$j] * $M[$i][$j]) } }
    return [math]::Sqrt($sum)
}

function Get-SpectralRadiusPowerIter {
    param([double[][]]$M)
    $v = [double[]]@(0.5, 0.5, 0.5, 0.5); [double]$lambda = 0.0
    for ($iter = 0; $iter -lt 24; $iter++) {
        $w = New-Object double[] 4
        for ($i = 0; $i -lt 4; $i++) {
            $s = 0.0; for ($j = 0; $j -lt 4; $j++) { $s += $M[$i][$j] * $v[$j] }; $w[$i] = $s
        }
        $norm = 0.0; for ($i = 0; $i -lt 4; $i++) { $norm += $w[$i] * $w[$i] }; $norm = [math]::Sqrt($norm)
        if ($norm -lt 1e-12) { return 0.0 }
        $lambda = $norm; for ($i = 0; $i -lt 4; $i++) { $v[$i] = $w[$i] / $norm }
    }
    return $lambda
}

function Invoke-JacobianEngine {
    param([double]$Psi = 0.5, [double]$Gain = 0.7, [double]$Purity = 0.85, [double]$Alpha = 0.5, [int]$Sides = 6, [double]$StepH = 1e-5, [switch]$SolveEquilibrium, [double]$TargetBend = 8.0, $ModelObj = $null, [string]$SurrHash = 'NONE')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $Script:EvalCount++
    $x = [double[]]@($Psi, $Gain, $Purity, $Alpha)
    $newtonSteps = 0

    if ($SolveEquilibrium) {
        for ($step = 0; $step -lt 12; $step++) {
            $newtonSteps++
            $f0 = (Invoke-ForwardManifold -Psi $x[0] -Gain $x[1] -Purity $x[2] -Alpha $x[3] -Sides $Sides -ModelObj $ModelObj).YVec
            $errBend = $f0[3] - $TargetBend
            if ([math]::Abs($errBend) -lt 1e-4) { break }
            $Jtmp = New-Object 'double[][]' 4
            for ($r = 0; $r -lt 4; $r++) { $Jtmp[$r] = New-Object double[] 4 }
            for ($c = 0; $c -lt 4; $c++) {
                $xp = [double[]]$x.Clone(); $xm = [double[]]$x.Clone(); $xp[$c] += $StepH; $xm[$c] -= $StepH
                $yp = (Invoke-ForwardManifold -Psi $xp[0] -Gain $xp[1] -Purity $xp[2] -Alpha $xp[3] -Sides $Sides -ModelObj $ModelObj).YVec
                $ym = (Invoke-ForwardManifold -Psi $xm[0] -Gain $xm[1] -Purity $xm[2] -Alpha $xm[3] -Sides $Sides -ModelObj $ModelObj).YVec
                for ($r = 0; $r -lt 4; $r++) { $Jtmp[$r][$c] = ($yp[$r] - $ym[$r]) / (2.0 * $StepH) }
            }
            $invRes = Invoke-InvertMatrix4x4 -M $Jtmp
            if ($invRes.Singular) { break }
            $dVec = [double[]]@(0.0, 0.0, 0.0, $errBend)
            for ($i = 0; $i -lt 4; $i++) {
                $delta = 0.0; for ($j = 0; $j -lt 4; $j++) { $delta += $invRes.Inverse[$i][$j] * $dVec[$j] }; $x[$i] -= 0.45 * $delta
            }
            $x[0] = [math]::Max(-3.14, [math]::Min(3.14, $x[0]))
            $x[1] = [math]::Max(0.05, [math]::Min(1.00, $x[1]))
            $x[2] = [math]::Max(0.10, [math]::Min(1.00, $x[2]))
            $x[3] = [math]::Max(0.00, [math]::Min(1.00, $x[3]))
        }
    }

    $base = Invoke-ForwardManifold -Psi $x[0] -Gain $x[1] -Purity $x[2] -Alpha $x[3] -Sides $Sides -ModelObj $ModelObj
    $J = New-Object 'double[][]' 4
    for ($r = 0; $r -lt 4; $r++) { $J[$r] = New-Object double[] 4 }
    for ($c = 0; $c -lt 4; $c++) {
        $xp = [double[]]$x.Clone(); $xm = [double[]]$x.Clone(); $xp[$c] += $StepH; $xm[$c] -= $StepH
        $yp = (Invoke-ForwardManifold -Psi $xp[0] -Gain $xp[1] -Purity $xp[2] -Alpha $xp[3] -Sides $Sides -ModelObj $ModelObj).YVec
        $ym = (Invoke-ForwardManifold -Psi $xm[0] -Gain $xm[1] -Purity $xm[2] -Alpha $xm[3] -Sides $Sides -ModelObj $ModelObj).YVec
        for ($r = 0; $r -lt 4; $r++) { $J[$r][$c] = ($yp[$r] - $ym[$r]) / (2.0 * $StepH) }
    }

    $invData = Invoke-InvertMatrix4x4 -M $J
    $frobJ = Get-MatrixFrobenius -M $J
    $specRad = Get-SpectralRadiusPowerIter -M $J

$traceJ = $J[0][0] + $J[1][1] + $J[2][2] + $J[3][3]
$condNum = if (-not $invData.Singular) { $frobJ * (Get-MatrixFrobenius -M $invData.Inverse) } else { [double]::PositiveInfinity }
$JRounded = @(
@([math]::Round($J[0][0], 5), [math]::Round($J[0][1], 5), [math]::Round($J[0][2], 5), [math]::Round($J[0][3], 5)),
@([math]::Round($J[1][0], 5), [math]::Round($J[1][1], 5), [math]::Round($J[1][2], 5), [math]::Round($J[1][3], 5)),
@([math]::Round($J[2][0], 5), [math]::Round($J[2][1], 5), [math]::Round($J[2][2], 5), [math]::Round($J[2][3], 5)),
@([math]::Round($J[3][0], 5), [math]::Round($J[3][1], 5), [math]::Round($J[3][2], 5), [math]::Round($J[3][3], 5))
)
$invRounded = if (-not $invData.Singular) {
@(
@([math]::Round($invData.Inverse[0][0], 5), [math]::Round($invData.Inverse[0][1], 5), [math]::Round($invData.Inverse[0][2], 5), [math]::Round($invData.Inverse[0][3], 5)),
@([math]::Round($invData.Inverse[1][0], 5), [math]::Round($invData.Inverse[1][1], 5), [math]::Round($invData.Inverse[1][2], 5), [math]::Round($invData.Inverse[1][3], 5)),
@([math]::Round($invData.Inverse[2][0], 5), [math]::Round($invData.Inverse[2][1], 5), [math]::Round($invData.Inverse[2][2], 5), [math]::Round($invData.Inverse[2][3], 5)),
@([math]::Round($invData.Inverse[3][0], 5), [math]::Round($invData.Inverse[3][1], 5), [math]::Round($invData.Inverse[3][2], 5), [math]::Round($invData.Inverse[3][3], 5))
)
} else { $null }
$g = $base.YVec[0]; $f = $base.YVec[1]; $w = $base.YVec[2]; $b = $base.YVec[3]
$breach = ([math]::Abs($b) -gt 40.0) -or ($x[2] -lt 0.55)
if ($breach) { $b = [math]::Sign($b) * [math]::Min([math]::Abs($b), 40.0); $w = [math]::Max(0.68, $w + 0.1) }
$sha = Get-Sha256Hex ("{0:F6}|{1:F6}|{2:F6}|{3:F6}|{4}|{5}" -f $x[0], $x[1], $x[2], $x[3], $Sides, $SurrHash)
$sw.Stop()
return [pscustomobject]@{
EvalId = $Script:EvalCount; TimestampUtc = [DateTime]::UtcNow.ToString('o'); LatencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 4)
StateHash16 = $sha.Substring(0, 16); FullStateSha256 = $sha; NewtonIterations = $newtonSteps
ControlVectorX = [pscustomobject]@{ Psi = [math]::Round($x[0], 4); Gain = [math]::Round($x[1], 4); Purity = [math]::Round($x[2], 4); Alpha = [math]::Round($x[3], 4) }
ObservableY = [pscustomobject]@{ CouplingGain = [math]::Round($g, 6); FrequencyThz = [math]::Round($f, 6); WatermarkWt = [math]::Round($w, 6); RegulatedBend = [math]::Round($b, 6) }
JacobianTensor = [pscustomobject]@{
Matrix4x4 = $JRounded; Inverse4x4 = $invRounded; Singular = $invData.Singular; Determinant = [math]::Round($invData.Determinant, 6)
Trace = [math]::Round($traceJ, 6); FrobeniusNorm = [math]::Round($frobJ, 6); SpectralRadius = [math]::Round($specRad, 6)
ConditionNumber = if ([double]::IsInfinity($condNum)) { 'INF_SINGULAR' } else { [math]::Round($condNum, 4) }; Contractive = ($specRad -lt 1.0)
}
Polygonal = [pscustomobject]@{ Sides = $Sides; SectorAngleRad = [math]::Round($base.SectorRad, 6); SnappedVertexRad = [math]::Round($base.SnappedRad, 6); ResidualRad = [math]::Round($base.ResidualRad, 6); Coherence = [math]::Round($base.Coherence, 6) }
MassAugmentation = [pscustomobject]@{ ColdMass = [math]::Round($base.ColdMass, 6); LowMass = [math]::Round($base.LowMass, 6); InvariantSatisfied = ($base.ColdMass -lt $base.LowMass); AugmentationRatio = [math]::Round($base.AugFactor, 6) }
Ambient6D = @($base.Ambient6D | ForEach-Object { [math]::Round($_, 6) }); BreachDetected = $breach
Status = if ($breach) { 'AUGMENTED_CLAMPED' } else { 'JACOBIAN_CERTIFIED' }
}
}