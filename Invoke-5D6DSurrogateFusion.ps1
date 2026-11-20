using module .\HarmonicPraxisAI.psd1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path

class Clean5DImmersionEngine {
    static [pscustomobject] Project([double[]]$S, [double]$Gain, [double]$Purity) {
        $s0 = [double]$S.GetValue(0)
        $s1 = [double]$S.GetValue(1)
        $s2 = [double]$S.GetValue(2)
        $s3 = [double]$S.GetValue(3)
        $psi = [double]$S.GetValue(4)

        $cP = [math]::Cos($psi); $sP = [math]::Sin($psi)
        $c2P = [math]::Cos(2.0 * $psi); $s2P = [math]::Sin(2.0 * $psi)
        $inv2 = 0.7071067811865475

        $amb = [double[]]::new(6)
        $amb.SetValue([math]::Round(($inv2 * $cP * $s0) - ($inv2 * $sP * $s1), 8), 0)
        $amb.SetValue([math]::Round(($inv2 * $sP * $s0) + ($inv2 * $cP * $s1), 8), 1)
        $amb.SetValue([math]::Round(($inv2 * $c2P * $s2) - ($inv2 * $s2P * $s3), 8), 2)
        $amb.SetValue([math]::Round(($inv2 * $s2P * $s2) + ($inv2 * $c2P * $s3), 8), 3)
        $amb.SetValue([math]::Round($cP * $psi, 8), 4)
        $amb.SetValue([math]::Round($sP * $psi, 8), 5)

        $k = (1.0 + (2.5 * $Gain)) * (1.2 - (0.5 * $Purity))
        $d0 = $k * $cP; $d1 = $k * $cP; $d2 = 0.85 * $k * $c2P; $d3 = -0.85 * $k * $c2P; $d4 = 1.5 * $k
        $off01 = 0.15 * $Gain * $sP; $off04 = 0.25 * $Gain; $off14 = -0.25 * $Gain; $off23 = 0.10 * $s2P

        $H = [math]::Round(($d0 + $d1 + $d2 + $d3 + $d4) / 5.0, 6)
        $bend = ($d0*$s0*$s0) + ($d1*$s1*$s1) + ($d2*$s2*$s2) + ($d3*$s3*$s3) + ($d4*$psi*$psi) + (2.0*$off01*$s0*$s1) + (2.0*$off04*$s0*$psi) + (2.0*$off14*$s1*$psi) + (2.0*$off23*$s2*$s3)

        return [pscustomobject]@{
            ImmersedAmbient6D       = $amb
            MeanExtrinsicCurvatureH = $H
            ExtrinsicBendingEnergy  = [math]::Round($bend, 6)
        }
    }
}

class Harmonic6DFusedSurrogate {
    [int]$InputDim = 32
    [int]$HiddenDim = 48
    [int]$OutputDim = 6
    [HarmonicNeuralSurrogate]$CoreNet

    Harmonic6DFusedSurrogate([int]$Hidden, [int]$Seed) {
        $this.HiddenDim = $Hidden
        $net = [HarmonicNeuralSurrogate]::new($Hidden, $Seed)
        $net.InputDim = 32
        $rng = [System.Random]::new($Seed)
        $net.W1 = $net.InitMatrix(32, $Hidden, $rng)
        $net.mW1 = $net.ZeroMatrix(32, $Hidden)
        $net.vW1 = $net.ZeroMatrix(32, $Hidden)
        $this.CoreNet = $net
    }

    static [double[]] Build32DFeatureVector([double[]]$Base24, [double[]]$Ambient6D, [double]$CurvatureH, [double]$BendEnergy) {
        $vec = [double[]]::new(32)
        for ($i = 0; $i -lt 24; $i++) { $vec.SetValue([double]$Base24.GetValue($i), $i) }
        for ($j = 0; $j -lt 6; $j++)  { $vec.SetValue([double]$Ambient6D.GetValue($j), 24 + $j) }
        $vec.SetValue($CurvatureH, 30)
        $vec.SetValue($BendEnergy, 31)
        return $vec
    }
}

Write-Host "STEP 1: Synthesizing 2,500 Coupled 5D->6D + Hyperfine Sift Training Samples" -ForegroundColor Cyan
$Rng = [System.Random]::new(2026)
$N = 2500
$XAll = [object[]]::new($N)
$YAll = [object[]]::new($N)
for ($i = 0; $i -lt $N; $i++) {
    $sim = [HarmonicPhysicsKernel]::SimulateSample($Rng)
    $b24 = [double[]]$sim.X
    $y6  = [double[]]$sim.Y
    $s5d = [double[]]::new(5)
    $s5d.SetValue(([double]$b24.GetValue(1) * 0.01), 0)
    $s5d.SetValue(([double]$b24.GetValue(2) * 0.01), 1)
    $s5d.SetValue(([double]$b24.GetValue(3) * 0.01), 2)
    $s5d.SetValue(($i * 0.002), 3)
    $s5d.SetValue([double]$b24.GetValue(0), 4)
    $proj = [Clean5DImmersionEngine]::Project($s5d, [double]$y6.GetValue(1), [double]$b24.GetValue(21))
    $f32 = [Harmonic6DFusedSurrogate]::Build32DFeatureVector($b24, [double[]]$proj.ImmersedAmbient6D, [double]$proj.MeanExtrinsicCurvatureH, [double]$proj.ExtrinsicBendingEnergy)
    $curvaturePenalty = [math]::Min(0.15, ([math]::Abs([double]$proj.ExtrinsicBendingEnergy) * 0.002))
    $adjWt = [math]::Max(0.35, ([double]$y6.GetValue(4) - $curvaturePenalty))
    $y6.SetValue($adjWt, 4)
    $y6.SetValue($(if ($adjWt -ge 0.68 -and $sim.Sift.PhaseLocked) { 1.0 } else { 0.0 }), 5)
    $XAll.SetValue($f32, $i)
    $YAll.SetValue($y6, $i)
}

Write-Host "STEP 2: Training 32D Fused Surrogate Neural Network (30 Epochs)" -ForegroundColor Cyan
$FusedWrapper = [Harmonic6DFusedSurrogate]::new(48, 2026)
$Net = $FusedWrapper.CoreNet
$xScaler = [HarmonicStandardScaler]::new(); $xScaler.Fit($XAll)
$yScaler = [HarmonicStandardScaler]::new(); $yScaler.Fit($YAll)
$Net.XScaler = $xScaler; $Net.YScaler = $yScaler
$sX = [object[]]::new($N); $sY = [object[]]::new($N)
for ($i = 0; $i -lt $N; $i++) {
    $sX.SetValue($xScaler.TransformRow([double[]]$XAll.GetValue($i)), $i)
    $rawY = [double[]]$YAll.GetValue($i)
    $scY = $yScaler.TransformRow($rawY)
    $scY.SetValue([double]$rawY.GetValue(5), 5)
    $sY.SetValue($scY, $i)
}
for ($ep = 1; $ep -le 30; $ep++) {
    $loss = 0.0; $bCount = 0
    for ($idx = 0; $idx -lt $N; $idx += 64) {
        $end = [math]::Min($idx + 63, $N - 1)
        $loss += $Net.TrainBatch($sX[$idx..$end], $sY[$idx..$end], 0.003, 0.0001, 0.85)
        $bCount++
    }
    if ($ep % 10 -eq 0) { Write-Host ("[32D Epoch {0:D2}/30] Loss: {1:F5}" -f $ep, ($loss / $bCount)) -ForegroundColor Green }
}

Write-Host "STEP 3: Running 32D Coupled Surrogate Inference on Live Streamed Frames" -ForegroundColor Cyan
$StreamLogPath = Join-Path $BaseDir "live_5d_stream_log.csv"
$CsvRows = Import-Csv -LiteralPath $StreamLogPath | Select-Object -First 15
$InferenceResults = foreach ($row in $CsvRows) {
    $sim = [HarmonicPhysicsKernel]::SimulateSample($Rng)
    $ambParts = ($row.Ambient6D -split ",") | ForEach-Object { [double]$_.Trim() }
    $ambVec = [double[]]::new(6)
    for ($j = 0; $j -lt 6; $j++) { $ambVec.SetValue([double]$ambParts.GetValue($j), $j) }
    $f32 = [Harmonic6DFusedSurrogate]::Build32DFeatureVector([double[]]$sim.X, $ambVec, [double]$row.MeanExtrinsicCurvatureH, [double]$row.ExtrinsicBendingEnergy)
    $xNorm = $Net.XScaler.TransformRow($f32)
    $rawOut = [double[]]($Net.Forward($xNorm).Out)
    $denorm = $Net.YScaler.InverseTransformRow($rawOut)
    $prob = [math]::Round([double]$rawOut.GetValue(5), 4)
    [pscustomobject]@{
        Frame              = [int]$row.Frame
        Tau                = [double]$row.Tau
        ExtrinsicBend      = [double]$row.ExtrinsicBendingEnergy
        PredCouplingGain   = [math]::Round([math]::Min(1.0, [math]::Max(0.0, [double]$denorm.GetValue(1))), 4)
        PredFrequencyThz   = [math]::Round([double]$denorm.GetValue(2), 4)
        PredWatermarkWt    = [math]::Round([math]::Min(0.85, [math]::Max(0.35, [double]$denorm.GetValue(4))), 4)
        AutonomousProb     = $prob
        AutonomousReady    = ($prob -ge 0.5)
    }
}
$InferenceResults | Format-Table -AutoSize
$OutFusedCsv = Join-Path $BaseDir "fused_6d_surrogate_predictions.csv"
$InferenceResults | Export-Csv -LiteralPath $OutFusedCsv -NoTypeInformation
Write-Host "[COMPLETE] 6D Ambient + Extrinsic Curvature Coupled Inference Saved to: $OutFusedCsv" -ForegroundColor Green
