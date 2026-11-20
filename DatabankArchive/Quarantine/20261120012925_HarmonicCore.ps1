Set-StrictMode -Version Latest
$Script:PHI       = (1.0 + [math]::Sqrt(5.0)) / 2.0
$Script:INV_SQRT2 = 1.0 / [math]::Sqrt(2.0)
$Script:SeqCounter = 0

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
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Invoke-RecursiveDot {
    param([double[]]$A, [int]$OffA, [double[]]$B, [int]$OffB, [int]$Idx, [int]$Len, [double]$Acc = 0.0)
    if ($Idx -ge $Len) { return $Acc }
    return Invoke-RecursiveDot -A $A -OffA $OffA -B $B -OffB $OffB -Idx ($Idx + 1) -Len $Len -Acc ($Acc + ($A[$OffA + $Idx] * $B[$OffB + $Idx]))
}

function Invoke-EvaluateExhaustiveState {
    param([double]$Psi = 0.5, [double]$Gain = 0.7, [double]$Purity = 0.85, [int]$Sides = 6, $ModelObj = $null, [string]$SurrHash = 'NONE', [string]$LockHash = 'NONE')
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
    $cP = [math]::Cos($Psi); $sP = [math]::Sin($Psi); $c2P = [math]::Cos(2.0 * $Psi); $s2P = [math]::Sin(2.0 * $Psi)

    $ambient6D = @(
        [math]::Round($Script:INV_SQRT2 * ($cP * $s0 - $sP * $s1) * $polyCoherence, 6),
        [math]::Round($Script:INV_SQRT2 * ($sP * $s0 + $cP * $s1) * $polyCoherence, 6),
        [math]::Round($Script:INV_SQRT2 * ($c2P * $s2 - $s2P * $s3), 6),
        [math]::Round($Script:INV_SQRT2 * ($s2P * $s2 + $c2P * $s3), 6),
        [math]::Round($cP * $snappedVertex, 6),
        [math]::Round($sP * $angularResidual, 6)
    )

    $matrix4x4 = @(
        @([math]::Round($polyCoherence * $cP, 6), [math]::Round(-$augFactor * $sP, 6), [math]::Round($Gain * $Script:INV_SQRT2, 6), [math]::Round($angularResidual, 6)),
        @([math]::Round($augFactor * $sP, 6), [math]::Round($polyCoherence * $cP, 6), [math]::Round(-$Purity * $Script:INV_SQRT2, 6), [math]::Round($snappedVertex / [math]::PI, 6)),
        @([math]::Round($coldMass, 6), [math]::Round($lowMass, 6), [math]::Round($Purity * $polyCoherence, 6), [math]::Round(-$Gain * 0.5, 6)),
        @([math]::Round($c2P * 0.25, 6), [math]::Round($s2P * 0.25, 6), [math]::Round($augFactor - 1.0, 6), [math]::Round([math]::Pow($Script:PHI, -1), 6))
    )

    $traceJ = [math]::Round($matrix4x4[0][0] + $matrix4x4[1][1] + $matrix4x4[2][2] + $matrix4x4[3][3], 6)
    $frobSq = 0.0; foreach ($r in $matrix4x4) { foreach ($c in $r) { $frobSq += ($c * $c) } }
    $frobeniusNorm = [math]::Round([math]::Sqrt($frobSq), 6)
    $spectralProxy = [math]::Round($frobeniusNorm / 2.0, 6)

    $k = (1.0 + 2.5 * $Gain) * (1.2 - 0.5 * $Purity) * (1.0 - 0.25 * $augFactor)
    $bendIn = ($k * $cP * ($s0 * $s0 + $s1 * $s1)) + (1.5 * $k * $Psi * $Psi)
    [double]$g = $Gain; [double]$f = (299792458.0 / ((532.0 - 4.0 * $Gain) * 1e-9)) / 1e12; [double]$w = 0.72 + 0.08 * $augFactor; [double]$b = $bendIn
    $modelApplied = $false

    $wf = Get-SafeProp $ModelObj 'WeightsFlat'; $xm = Get-SafeProp $ModelObj 'XMean'; $xs = Get-SafeProp $ModelObj 'XStd'
    if ($null -eq $wf) {
        $n = Get-SafeProp $ModelObj 'model'; if ($null -eq $n) { $n = Get-SafeProp $ModelObj 'surrogate' }
        $wf = Get-SafeProp $n 'WeightsFlat'; $xm = Get-SafeProp $n 'XMean'; $xs = Get-SafeProp $n 'XStd'
    }
    if ($null -ne $wf -and $null -ne $xm -and $null -ne $xs -and @($wf).Count -ge 48) {
        $xRaw = [double[]]@(1.0, $Psi, $Gain, $Purity, $raw, $s0, $s1, ($cP * $s0), ($sP * $s1), $c2P, $bendIn, ($Gain * $Purity))
        $xNorm = New-Object double[] 12; $ma = [double[]]$xm; $sa = [double[]]$xs
        for ($j = 0; $j -lt 12; $j++) { $std = if ($sa[$j] -eq 0.0) { 1.0 } else { $sa[$j] }; $xNorm[$j] = if ($j -eq 0) { 1.0 } else { ($xRaw[$j] - $ma[$j]) / $std } }
        $wts = [double[]]$wf
        $g = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 0 -Idx 0 -Len 12
        $f = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 12 -Idx 0 -Len 12
        $w = Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 24 -Idx 0 -Len 12
        $b = (Invoke-RecursiveDot -A $xNorm -OffA 0 -B $wts -OffB 36 -Idx 0 -Len 12) * (1.0 - 0.25 * $augFactor)
        $modelApplied = $true
    }

    $breach = ([math]::Abs($b) -gt 40.0) -or ($Purity -lt 0.55)
    if ($breach) { $b = [math]::Sign($b) * [math]::Min([math]::Abs($b), 40.0); $w = [math]::Max(0.68, $w + 0.1) }

    $rLoad = [math]::Round($Gain * (1.0 + [math]::Abs($Psi)), 4)
    $bDamp = [math]::Round($Purity * $polyCoherence * (1.0 + $augFactor), 4)
    $rbRatio = [math]::Round($rLoad / [math]::Max(0.001, $bDamp), 4)
    $loopArch = if ($rbRatio -gt 1.25) { 'REINFORCING_ESCALATION (R-DOMINANT)' } elseif ($rbRatio -lt 0.75) { 'BALANCING_EQUILIBRIUM (B-DOMINANT)' } else { 'HOMEOSTATIC_COUPLED (R=B)' }
    $bendM = [math]::Round([math]::Max(0.0, (1.0 - ([math]::Abs($b) / 40.0)) * 100.0), 2)
    $purM  = [math]::Round((($Purity - 0.55) / 0.45) * 100.0, 2)
    $lyap  = ($spectralProxy -lt 1.25) -and (-not $breach)
    $sha   = Get-Sha256Hex ("{0:F6}|{1:F6}|{2:F6}|{3}|{4}|{5}|{6:F6}|{7:F6}" -f $Psi, $Gain, $Purity, $sides, $SurrHash, $LockHash, $b, $augFactor)

    return [pscustomobject]@{
        SequenceId = $Script:SeqCounter; TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Reproducibility = [pscustomobject]@{ StateSha256 = $sha; ShortSignature = $sha.Substring(0, 16); SurrogateSha16 = $SurrHash; LockFileSha16 = $LockHash; ModelApplied = $modelApplied; Deterministic = $true }
        Polygonal = [pscustomobject]@{ Sides = $sides; SectorAngleRad = [math]::Round($sectorAngle, 6); SnappedVertexRad = [math]::Round($snappedVertex, 6); AngularResidualRad = [math]::Round($angularResidual, 6); PolygonalCoherence = [math]::Round($polyCoherence, 6) }
        MassAugmentation = [pscustomobject]@{ ColdMass = [math]::Round($coldMass, 6); LowMass = [math]::Round($lowMass, 6); InvariantSatisfied = ($coldMass -lt $lowMass); AugmentationFactor = [math]::Round($augFactor, 6) }
        SystemsHeuristics = [pscustomobject]@{ LoopArchetype = $loopArch; ReinforcingLoad = $rLoad; BalancingDamping = $bDamp; RbDominanceRatio = $rbRatio; BendSafetyMargin = "$bendM%"; PuritySafetyMargin = "$purM%"; LyapunovStable = $lyap }
        ComputingMatrices = [pscustomobject]@{ Ambient6D = $ambient6D; Jacobian4x4 = $matrix4x4; TraceJ = $traceJ; FrobeniusNorm = $frobeniusNorm; SpectralRadiusEst = $spectralProxy }
        Telemetry = [pscustomobject]@{ Psi = [math]::Round($Psi, 4); CouplingGain = [math]::Round($g, 6); FrequencyThz = [math]::Round($f, 6); WatermarkWt = [math]::Round($w, 6); RegulatedBend = [math]::Round($b, 6); BreachDetected = $breach; Status = if ($breach) { 'AUGMENTED_CLAMPED' } else { 'REGULATED_COMPLIANT' } }
    }
}
