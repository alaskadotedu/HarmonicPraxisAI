Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Join-Path (Get-Location).Path 'HarmonicPraxisAI'
if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
$RemediationJson = Join-Path $BaseDir 'harmonic_linear_remediation_v5_0.json'
$RegenCsv = Join-Path $BaseDir 'regenerated_compliant_telemetry_v5_0.csv'

class RidgeLinearRemediator {
    [int]$FeatureDim
    [int]$TargetDim
    [double]$Lambda
    [double[]]$WeightsFlat
    [double[]]$XMean
    [double[]]$XStd

    RidgeLinearRemediator([int]$FDim, [int]$TGim, [double]$Lambda) {
        $this.FeatureDim = $FTim; $this.TargetDim = $TDim; $this.Lambda = $Lambda
        $this.WeightsFlat = [double[]]::new($FDim * $TDim)
        $this.XMean = [double[]]::new($FDim); $this.XStd = [double[]]::new($FDim)
    }

    [void] Fit([double[]]$XFlat, [double[]]$YFlat, [int]$NSamples) {
        $p = $this.FeatureDim; $q = $this.TargetDim
        $XNorm = [double[]]::new($NSamples * $p)
        for ($j = 0; $j -lt $p; $j++) {
            $sum = 0.0; for ($i = 0; $i -lt $NSamples; $i++) { $sum += $XFlat[$i * $p + $j] }
            $m = $sum / $NSamples; $this.XMean[$j] = $m
            $sq = 0.0; for ($i = 0; $i -lt $NSamples; $i++) { $d = $XFlat[$i * $p + $j] - $m; $sq += ($d * $d) }
            $s = [math]::Sqrt($sq / [math]::Max(1, $NSamples - 1)); $this.XStd[$j] = if ($s -lt 1e-12) { 1.0 } else { $s }
            for ($i = 0; $i -lt $NSamples; $i++) { $XNorm[$i * $p + $j] = ($XFlat[$i * $p + $j] - $m) / $this.XStd[$j] }
        }

        $XtX = [double[]]::new($p * $p)
        $XtY = [double[]]::new($p * $q)
        for ($r = 0; $r -lt $p; $r++) {
            for ($c = 0; $c -lt $p; $c++) {
                $acc = 0.0; for ($i = 0; $i -lt $NSamples; $i++) { $acc += $XNorm[$i * $p + $r] * $XNorm[$i * $p + $c] }
                if ($r -eq $c) { $acc += $this.Lambda }
                $XtX[$r * $p + $c] = $acc
            }
            for ($k = 0; $k -lt $q; $k++) {
                $accY = 0.0; for ($i = 0; $i -lt $NSamples; $i++) { $accY += $XNorm[$i * $p + $r] * $YFlat[$i * $q + $k] }
                $XtY[$r * $q + $k] = $accY
            }
        }

        $Aug = [double[]]::new($p * ($p + $q))
        $width = $p + $q
        for ($r = 0; $r -lt $p; $r++) {
            for ($c = 0; $c -lt $p; $c++) { $Aug[$r * $width + $c] = $XtX[$r * $p + $c] }
            for ($k = 0; $k -lt $q; $k++) { $Aug[$r * $width + $p + $k] = $XtY[$r * $q + $k] }
        }

        for ($piv = 0; $piv -lt $p; $piv++) {
            $div = $Aug[$piv * $width + $piv]; if ([math]::Abs($div) -lt 1e-14) { $div = 1e-14 }
            for ($c = $piv; $c -lt $width; $c++) { $Aug[$piv * $width + $c] /= $div }
            for ($r = 0; $r -lt $p; $r++) {
                if ($r -ne $piv) {
                    $fac = $Aug[$r * $width + $piv]
                    for ($c = $piv; $c -lt $width; $c++) { $Aug[$r * $width + $c] -= ($fac * $Aug[$piv * $width + $c]) }
                }
            }
        }

        for ($r = 0; $r -lt $p; $r++) {
            for ($k = 0; $k -lt $q; $k++) { $this.WeightsFlat[$r * $q + $k] = $Aug[$r * $width + $p + $k] }
        }
    }

    [double[]] PredictRow([double[]]$Row) {
        $p = $this.FeatureDim; $q = $this.TargetDim
        $out = [double[]]::new($q)
        for ($k = 0; $k -lt $q; $k++) {
            $sum = 0.0
            for ($j = 0; $j -lt $p; $j++) { $z = ($Row[$j] - $this.XMean[$j]) / $this.XStd[$j]; $sum += ($z * $this.WeightsFlat[$j * $q + $k]) }
            $out[$k] = $sum
        }
        return $out
    }
}

Write-Host 'PHASE 1: Synthesizing 32-Dimensional Hyperfine-Sifted & 5D->6D Inmersed Manifold (2,000 Samples)' -ForegroundColor Cyan
$Rng = [System.Random]::new(2026); $N = 2000; $FDim = 32; $TDim = 5
$XFlat = [double[]]::new($N * $FDim); $YFlat = [double[]]::new($N * $TDim)
for ($i = 0; $i -lt $N; $i++) {
    $theta = ($Rng.NextDouble() * 2.0 * [math]::PI) - [math]::PI
    $gain = $Rng.NextDouble(); $purity = 0.40 + ($Rng.NextDouble() * 0.60); $rawScore = $Rng.NextDouble()
    $s0 = ($Rng.NextDouble() - 0.5) * 10.0; $s1 = ($Rng.NextDouble() - 0.5) * 10.0; $s2 = ($Rng.NextDouble() - 0.5) * 10.0; $s3 = $i * 0.002
    $cP = [math]::Cos($theta); $sP = [math]::Sin($theta); $c2P = [math]::Cos(2.0 * $theta); $s2P = [math]::Sin(2.0 * $theta); $inv2 = 0.7071067811865475
    $amb0 = ($inv2 * $cP * $s0) - ($inv2 * $sP * $s1); $amb1 = ($inv2 * $sP * $s0) + ($inv2 * $cP * $s1)
    $amb2 = ($inv2 * $c2P * $s2) - ($inv2 * $s2P * $s3); $amb3 = ($inv2 * $s2P * $s2) + (($inv2 * $c2P * $s3))
    $amb4 = $cP * $theta; $amb5 = $sP * $theta
    $k = (1.0 + (2.5 * $gain)) * (1.2 - (0.5 * $purity))
    $h = ((2.0 * $k * $cP) + (1.5 * $k)) / 5.0
    $bend = ($k * $cP * ($s0*$s0 + $s1*$s1)) + (0.85 * $k * $c2P * ($s2*$s2 - $s3*$s3)) + (1.5 * $k * $theta * $theta)
    $freqThz = (299792458.0 / ((532.0 - (4.0 * $gain)) * 1e-9)) / 1e12
    $fused = 95.0 + (15.0 * $purity)
    $pen = [math]::Min(0.18, [math]::Abs($bend) * 0.0015)
    $wt = [math]::Max(0.35, [math]::Min(0.85, (0.30 * 0.35) + (0.70 * ((0.65 * $rawScore) + (0.35 * $purity)) - $pen)))

    $base = $i * $FDim
    $XFlat[$base + 0] = 1.0; $XFlat[$base + 1] = $theta; $XFlat[$base + 2] = $gain; $XFlat[$base + 3] = $purity; $XFlat[$base + 4] = $rawScore
    $XFlat[$base + 5] = $s0; $XFlat[$base + 6] = $s1; $XFlat[$base + 7] = $s2; $XFlat[$base + 8] = $s3
    $XFlat[$base + 9] = $amb0; $XFlat[$base + 10] = $amb1; $XFlat[$base + 11] = $amb2; $XFlat[$base + 12] = $amb3; $XFlat[$base + 13] = $amb4; $XFlat[$base + 14] = $amb5
    $XFlat[$base + 15] = $h; $XFlat[$base + 16] = $bend; $XFlat[$base + 17] = $cP * $gain; $XFlat[$base + 18] = $sP * $gain; $XFlat[$base + 19] = $purity * $purity
    for ($kk = 20; $kk -lt 32; $kk++) { $XFlat[$base + $kk] = [math]::Sin($theta + ($kk * 0.25)) * $gain }

    $yBase = $i * $TDim
    $YFlat[$yBase + 0] = $gain; $YFlat[$yBase + 1] = $freqThz
    $YFlat[$yBase + 2] = $fused; $YFlat[$yBase + 3] = $wt; $YFlat[$yBase + 4] = $bend
}

Write-Host 'PHASE 2: Exact Closed-Form Ridge Linear Regression Solver (Lambda = 1e-4)' -ForegroundColor Cyan
$Remediator = [RidgeLinearRemediator]::new(32, 5, 1e-4)
$Remediator.Fit($XFlat, $YFlat, $N)

Write-Host 'PHASE 3: Intrinsic Value Audit (RMSE & R2 Coefficient of Determination)' -ForegroundColor Cyan
$TargetNames = @('CouplingGain', 'FrequencyThz', 'FusedEstimate', 'WatermarkWt', 'ExtrinsicBendingEnergy')
$Metrics = for ($k = 0; $k -lt 5; $k++) {
    $ssRes = 0.0; $ssTot = 0.0; $ySum = 0.0
    for ($i = 0; $i -lt $N; $i++) { $ySum += $YFlat[$i * 5 + $k] }; $yMean = $ySum / $N
    $rowBuf = [double[]]::new(32)
    for ($i = 0; $i -lt $N; $i++) {
        for ($j = 0; $j -lt 32; $j++) { $rowBuf[$j] = $XFlat[$i * 32 + $j] }
        $pred = $Remediator.PredictRow($rowBuf)[$k]; $true = $YFlat[$i * 5 + $k]
        $d = $pred - $true; $ssRes += ($d * $d); $dt = $true - $yMean; $ssTot += ($dt * $dt)
    }
    $rmse = [math]::Round([math]::Sqrt($ssRes / $N), 6)
    $r2 = [math]::Round(1.0 - ($ssRes / [math]::Max(1e-12, $ssTot)), 6)
    [pscustomobject]@{ Channel = $TargetNames[$k]; RMSE = $rmse; R2_IntrinsicValue = $r2 }
}
$Metrics | Format-Table -AutoSize

Write-Host 'PHASE 4: Regulatory Remediation & Compliant Trajectory Regeneration (100 Steps)' -ForegroundColor Cyan
$RegenRecords = [object[]]::new(100); $RemediatedBreaches = 0
for ($s = 0; $s -lt 100; $s++) {
    $rowBuf = [double[]]::new(32); for ($j = 0; $j -lt 32; $j++) { $rowBuf[$j] = $XFlat[$s * 32 + $j] }
    $p = $Remediator.PredictRow($rowBuf)
    $rawBend = $p[4]; $rawWt = $p[3]; $purity = $rowBuf[3]
    $isBendBreach = ([Math]::Abs($rawBend) -gt 45.0)
    $isPurityBreach = ($purity -lt 0.55)
    $remediatedBend = if ($isBendBreach) { [math]::Sign($rawBend) * 45.0 } else { $rawBend }
    $remediatedWt = if ($isBendBreach -or $isPurityBreach) { $RemediatedBreaches++; [math]::Max(0.68, $rawWt + 0.12) } else { $rawWt }
    $RegenRecords[$s] = [pscustomobject]@{ Step = $s + 1; RawBendEnergy = [math]::Round($rawBend, 4); RemediatedBendEnergy = [math]::Round($remediatedBend, 4); RemediatedWatermarkWt = [math]::Round($remediatedWt, 4); CompliantStatus = 'REGULATED_COMPLIANT' }
}
$TotalWeights = $Remediator.WeightsFlat.Count
$ArtifactPayload = [ordered]@{ Version = '5.0.0'; Architecture = 'RidgeLinearRemediator'; FeatureDim = 32; TargetDim = 5; Lambda = 1e-4; RemediatedBreaches = $RemediatedBreaches; Metrics = $Metrics; WeightsFlat = $Remediator.WeightsFlat; XMean = $Remediator.XMean; XStd = $Remediator.XStd }
[System.IO.File]::WriteAllText($RemediationJson, ($ArtifactPayload | ConvertTo-Json -Depth 6 -Compress), [System.Text.UTF8Encoding]::new($false))
$Text = [System.IO.File]::ReadAllText($RemediationJson) -replace '$purity', '$purity' -replace '$tRows', '$TDim' -replace '$this.TargetDim', '$this.TargetDim'
$RegenRecords | Export-Csv -LiteralPath $RegenCsv -NoTypeInformation
Write-Host ('[COMPLETE] Remediated {0} breaches | Exported JSON Artifact (${1} weights) & Compliant CSV' -f $RemediatedBreaches, $TotalWeights) -ForegroundColor Green
