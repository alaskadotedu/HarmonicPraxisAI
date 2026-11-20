Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:PHI       = (1.0 + [math]::Sqrt(5.0)) / 2.0
$Script:INV_SQRT2 = 1.0 / [math]::Sqrt(2.0)

function Invoke-RecursiveDot {
    param([double[]]$A, [int]$OffA, [double[]]$B, [int]$OffB, [int]$Idx, [int]$Len, [double]$Acc = 0.0)
    if ($Idx -ge $Len) { return $Acc }
    return Invoke-RecursiveDot -A $A -OffA $OffA -B $B -OffB $OffB -Idx ($Idx + 1) -Len $Len -Acc ($Acc + ($A[$OffA + $Idx] * $B[$OffB + $Idx]))
}

function Get-SafeProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Invoke-EvaluateHarmonicState {
    param([hashtable]$InputData = @{}, $Model = $null)

    $psi    = if ($InputData.ContainsKey('psi'))          { [double]$InputData['psi'] }          else { 0.5 }
    $gain   = if ($InputData.ContainsKey('gain'))         { [double]$InputData['gain'] }         else { 0.7 }
    $purity = if ($InputData.ContainsKey('purity'))       { [double]$InputData['purity'] }       else { 0.85 }
    $raw    = if ($InputData.ContainsKey('rawScore'))     { [double]$InputData['rawScore'] }     else { 0.75 }
    $s0     = if ($InputData.ContainsKey('s0'))           { [double]$InputData['s0'] }           else { 1.0 }
    $s1     = if ($InputData.ContainsKey('s1'))           { [double]$InputData['s1'] }           else { -1.0 }
    $s2     = if ($InputData.ContainsKey('s2'))           { [double]$InputData['s2'] }           else { 0.4 }
    $s3     = if ($InputData.ContainsKey('s3'))           { [double]$InputData['s3'] }           else { 0.01 }
    $sides  = if ($InputData.ContainsKey('polygonSides')) { [math]::Max(3, [int]$InputData['polygonSides']) } else { 6 }

    $sectorAngle     = (2.0 * [math]::PI) / $sides
    $snappedVertex   = [math]::Round($psi / $sectorAngle) * $sectorAngle
    $angularResidual = $psi - $snappedVertex
    $polyCoherence   = [math]::Cos(($angularResidual * $sides) / 2.0)

    $lowMass   = [math]::Pow($Script:PHI, -1) * (1.0 + [math]::Max(0.05, $gain))
    $coldMass  = [math]::Min([math]::Pow($Script:PHI, -2) * [math]::Max(0.05, $purity), $lowMass * 0.94)
    $augFactor = $coldMass / $lowMass

    $cP  = [math]::Cos($psi); $sP  = [math]::Sin($psi)
    $c2P = [math]::Cos(2.0 * $psi); $s2P = [math]::Sin(2.0 * $psi)

    $ambient6D = @(
        [math]::Round($Script:INV_SQRT2 * ($cP * $s0 - $sP * $s1) * $polyCoherence, 6),
        [math]::Round($Script:INV_SQRT2 * ($sP * $s0 + $cP * $s1) * $polyCoherence, 6),
        [math]::Round($Script:INV_SQRT2 * ($c2P * $s2 - $s2P * $s3), 6),
        [math]::Round($Script:INV_SQRT2 * ($s2P * $s2 + $c2P * $s3), 6),
        [math]::Round($cP * $snappedVertex, 6),
        [math]::Round($sP * $angularResidual, 6)
    )

    $k      = (1.0 + 2.5 * $gain) * (1.2 - 0.5 * $purity) * (1.0 - 0.25 * $augFactor)
    $bendIn = ($k * $cP * ($s0 * $s0 + $s1 * $s1)) + (1.5 * $k * $psi * $psi)

    [double]$g = $gain
    [double]$f = (299792458.0 / ((532.0 - 4.0 * $gain) * 1e-9)) / 1e12
    [double]$w = 0.72 + 0.08 * $augFactor
    [double]$b = $bendIn
    $modelApplied = $false

    $weightsFlat = Get-SafeProp $Model 'WeightsFlat'
    $xMean       = Get-SafeProp $Model 'XMean'
    $xStd        = Get-SafeProp $Model 'XStd'

    if ($null -eq $weightsFlat) {
        $nested = Get-SafeProp $Model 'model'
        if ($null -eq $nested) { $nested = Get-SafeProp $Model 'surrogate' }
        $weightsFlat = Get-SafeProp $nested 'WeightsFlat'
        $xMean       = Get-SafeProp $nested 'XMean'
        $xStd        = Get-SafeProp $nested 'XStd'
    }

    if ($null -ne $weightsFlat -and $null -ne $xMean -and $null -ne $xStd -and @($weightsFlat).Count -ge 48) {
        $xRaw  = [double[]]@(1.0, $psi, $gain, $purity, $raw, $s0, $s1, ($cP * $s0), ($sP * $s1), $c2P, $bendIn, ($gain * $purity))
        $P     = 12
        $xNorm = New-Object double[] $P
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

    $breach = ([math]::Abs($b) -gt 40.0) -or ($purity -lt 0.55)
    if ($breach) {
        $b = [math]::Sign($b) * [math]::Min([math]::Abs($b), 40.0)
        $w = [math]::Max(0.68, $w + 0.1)
    }

    return [pscustomobject]@{
        TimestampUtc     = [DateTime]::UtcNow.ToString('o')
        Psi              = [math]::Round($psi, 4)
        Ambient6D        = $ambient6D
        Polygonal        = [pscustomobject]@{
            Sides              = $sides
            SectorAngleRad     = [math]::Round($sectorAngle, 6)
            SnappedVertexRad   = [math]::Round($snappedVertex, 6)
            AngularResidualRad = [math]::Round($angularResidual, 6)
            PolygonalCoherence = [math]::Round($polyCoherence, 6)
        }
        MassAugmentation = [pscustomobject]@{
            ColdMass           = [math]::Round($coldMass, 6)
            LowMass            = [math]::Round($lowMass, 6)
            InvariantSatisfied = ($coldMass -lt $lowMass)
            AugmentationFactor = [math]::Round($augFactor, 6)
        }
        ModelApplied     = $modelApplied
        CouplingGain     = [math]::Round($g, 6)
        FrequencyThz     = [math]::Round($f, 6)
        WatermarkWt      = [math]::Round($w, 6)
        RegulatedBend    = [math]::Round($b, 6)
        BreachDetected   = $breach
        Status           = if ($breach) { 'AUGMENTED_CLAMPED' } else { 'REGULATED_COMPLIANT' }
    }
}

$surrogatePath = Join-Path $PSScriptRoot 'harmonic_surrogate_v4_3.json'
$modelObj = if (Test-Path -LiteralPath $surrogatePath) { Get-Content -LiteralPath $surrogatePath -Raw | ConvertFrom-Json } else { $null }

$result = Invoke-EvaluateHarmonicState -InputData @{ psi = 0.5; gain = 0.7; purity = 0.85; polygonSides = 6 } -Model $modelObj
$result | ConvertTo-Json -Depth 4
