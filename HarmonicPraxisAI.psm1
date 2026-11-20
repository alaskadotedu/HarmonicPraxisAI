Set-StrictMode -Version Latest

class HyperfineFrequencySifter {
    static [double]$F0 = 9192631770.0
    static [double]$DeltaT = 0.002

    static [pscustomobject] Sift([double[]]$SignalSeries, [double]$FieldCouplingGain, [int]$MaxIterations = 4) {
        $n = $SignalSeries.Count
        if ($n -lt 4) {
            throw "SignalSeries must contain at least 4 samples for hyperfine envelope sifting."
        }

        $totalEnergy = 0.0
        for ($i = 0; $i -lt $n; $i++) {
            $v = $SignalSeries.GetValue($i)
            $totalEnergy += ($v * $v)
        }
        if ($totalEnergy -lt 1e-18) { $totalEnergy = 1e-18 }

        $imf = [double[]]::new($n)
        for ($i = 0; $i -lt $n; $i++) { $imf[$i] = $SignalSeries.GetValue($i) }

        for ($iter = 0; $iter -lt $MaxIterations; $iter++) {
            $upper = [double[]]::new($n)
            $lower = [double[]]::new($n)
            for ($i = 0; $i -lt $n; $i++) {
                $prevIdx = [math]::Max(0, $i - 1)
                $nextIdx = [math]::Min($n - 1, $i + 1)
                $vPrev = $imf.GetValue($prevIdx)
                $vCurr = $imf.GetValue($i)
                $vNext = $imf.GetValue($nextIdx)
                $upper[$i] = [math]::Max($vCurr, [math]::Max($vPrev, $vNext))
                $lower[$i] = [math]::Min($vCurr, [math]::Min($vPrev, $vNext))
            }
            for ($i = 0; $i -lt $n; $i++) {
                $meanEnv = 0.5 * ($upper.GetValue($i) + $lower.GetValue($i))
                $imf[$i] = $imf.GetValue($i) - $meanEnv
            }
        }

        $imfEnergy = 0.0
        $zeroCrossings = 0
        for ($i = 0; $i -lt $n; $i++) {
            $val = $imf.GetValue($i)
            $imfEnergy += ($val * $val)
            if ($i -gt 0) {
                $prevVal = $imf.GetValue($i - 1)
                if (($prevVal -ge 0.0 -and $val -lt 0.0) -or ($prevVal -lt 0.0 -and $val -ge 0.0)) {
                    $zeroCrossings++
                }
            }
        }

        $residualNoise = [math]::Sqrt([math]::Max(0.0, ($totalEnergy - $imfEnergy)) / $n)
        $combAttenuation = 1.0 - (0.15 * $FieldCouplingGain)
        $rawPurity = ($imfEnergy / $totalEnergy) * $combAttenuation
        $siftPurity = [math]::Round([math]::Min(1.0, [math]::Max(0.05, $rawPurity)), 6)

        $crossingRate = $zeroCrossings / [math]::Max(1.0, ($n - 1.0))
        $siftedFreqHz = [HyperfineFrequencySifter]::F0 + (($crossingRate - 0.5) * 125.0 * (1.0 - $siftPurity))
        $phaseLocked = ($siftPurity -ge 0.42 -and $residualNoise -lt 12.0)

        return [pscustomobject]@{
            SiftedFrequencyHz = [math]::Round($siftedFreqHz, 6)
            ResidualNoise     = [math]::Round($residualNoise, 6)
            SiftPurity        = $siftPurity
            ZeroCrossings     = $zeroCrossings
            PhaseLocked       = $phaseLocked
            ExtractedImf      = $imf
        }
    }
}

class HarmonicPhysicsKernel {
    static [double]$F0 = 9192631770.0
    static [double]$DeltaT = 0.002
    static [double]$Q = 1.602176634e-19
    static [double]$C = 299792458.0

    static [hashtable] SimulateSample([System.Random]$Rng) {
        $theta = ($Rng.NextDouble() * 2.0 * [math]::PI) - [math]::PI
        $ex = ($Rng.NextDouble() - 0.5) * 2000.0
        $ey = ($Rng.NextDouble() - 0.5) * 2000.0
        $ez = ($Rng.NextDouble() - 0.5) * 2000.0

        $vx = ($Rng.NextDouble() - 0.5) * 200.0
        $vy = ($Rng.NextDouble() - 0.5) * 200.0
        $vz = ($Rng.NextDouble() - 0.5) * 200.0

        $bx = ($Rng.NextDouble() - 0.5) * 0.02
        $by = ($Rng.NextDouble() - 0.5) * 0.02
        $bz = ($Rng.NextDouble() - 0.5) * 0.02

        $branchFactor = $Rng.Next(1, 9)
        $stateDim = $Rng.Next(1, 11)

        $sVals = [double[]]::new(4)
        $sConfs = [double[]]::new(4)
        for ($i = 0; $i -lt 4; $i++) {
            $sVals[$i] = 85.0 + ($Rng.NextDouble() * 30.0)
            $sConfs[$i] = 0.30 + ($Rng.NextDouble() * 0.70)
        }
        $anchorIdx = $Rng.Next(0, 4)
        $sConfs[$anchorIdx] = 0.75 + ($Rng.NextDouble() * 0.24)
        $rawScore = $Rng.NextDouble()

        $damping = 1.0 - (1e-9 * [math]::Abs([math]::Sin($theta)))
        $leap = [math]::Floor(($Rng.Next(0, 50) + 27) / 50)
        $deltaN = 18385263 + $leap
        $exactCycles = [HarmonicPhysicsKernel]::F0 * [HarmonicPhysicsKernel]::DeltaT
        $phaseError = ($damping * 0.0) + ($deltaN - $exactCycles)

        $fx = [HarmonicPhysicsKernel]::Q * ($ex + ($vy * $bz - $vz * $by))
        $fy = [HarmonicPhysicsKernel]::Q * ($ey + ($vz * $bx - $vx * $bz))
        $fz = [HarmonicPhysicsKernel]::Q * ($ez + ($vx * $by - $vy * $bx))
        $mag = [math]::Sqrt(($fx * $fx) + ($fy * $fy) + ($fz * $fz))
        $couplingGain = [math]::Min(1.0, $mag * 1e15)

        $waveform = [double[]]::new(8)
        for ($w = 0; $w -lt 8; $w++) {
            $carrier = [math]::Sin($theta + ($w * 1.57079632679))
            $jitter = ($Rng.NextDouble() - 0.5) * 0.45 * (1.0 + $couplingGain)
            $sensorPerturb = ($sVals.GetValue($w % 4) - 100.0) * 0.02
            $waveform[$w] = $carrier + $jitter + $sensorPerturb
        }
        $siftResult = [HyperfineFrequencySifter]::Sift($waveform, $couplingGain, 4)

        $isPTractable = ($branchFactor -le 2 -or $stateDim -le 3)
        $settlementFactor = if ($isPTractable) { 1.00 } else { 0.88 }

        $deltaNm = if (-not $isPTractable) { -(6.0 + (4.0 * $couplingGain)) } else { 6.5 - (2.0 * $couplingGain) }
        $lambdaNm = [math]::Min(580.0, [math]::Max(475.0, 532.0 + $deltaNm))
        $freqThz = ([HarmonicPhysicsKernel]::C / ($lambdaNm * 1e-9)) / 1e12

        $num = 0.0
        $den = 0.0
        for ($i = 0; $i -lt 4; $i++) {
            if ($sConfs[$i] -ge 0.70) {
                $val = $sVals[$i]
                $wt = $sConfs[$i]
            } else {
                $bestDist = 999.0
                $nearest = $anchorIdx
                for ($j = 0; $j -lt 4; $j++) {
                    if ($sConfs[$j] -ge 0.70) {
                        $dist = [math]::Abs($j - $i)
                        if ($dist -lt $bestDist) {
                            $bestDist = $dist
                            $nearest = $j
                        }
                    }
                }
                $val = $sVals[$nearest]
                $wt = 0.95 * $sConfs[$nearest]
            }
            $num += ($wt * $val)
            $den += $wt
        }
        $fusedEstimate = $num / $den

        $siftedCompositeScore = (0.65 * $rawScore) + (0.35 * $siftResult.SiftPurity)
        $wtRaw = (0.30 * 0.35) + (0.70 * $siftedCompositeScore * $settlementFactor)
        $watermarkWt = [math]::Min(0.85, [math]::Max(0.35, $wtRaw))
        $autonomous = if ($watermarkWt -ge 0.68 -and $siftResult.PhaseLocked) { 1.0 } else { 0.0 }

        [double[]]$features = @(
            $theta, $ex, $ey, $ez, $vx, $vy, $vz, $bx, $by, $bz,
            [double]$branchFactor, [double]$stateDim,
            $sVals.GetValue(0), $sVals.GetValue(1), $sVals.GetValue(2), $sVals.GetValue(3),
            $sConfs.GetValue(0), $sConfs.GetValue(1), $sConfs.GetValue(2), $sConfs.GetValue(3),
            $rawScore,
            $siftResult.SiftPurity,
            $siftResult.ResidualNoise,
            ($siftResult.SiftedFrequencyHz - [HarmonicPhysicsKernel]::F0)
        )

        [double[]]$targets = @(
            $phaseError,
            $couplingGain,
            $freqThz,
            $fusedEstimate,
            $watermarkWt,
            $autonomous
        )

        return @{
            X    = $features
            Y    = $targets
            Sift = $siftResult
        }
    }
}

class HarmonicStandardScaler {
    [double[]]$Mean
    [double[]]$Std

    [void] Fit([object[]]$Matrix) {
        $rows = $Matrix.Count
        $firstRow = [double[]]$Matrix.GetValue(0)
        $cols = $firstRow.Count
        $this.Mean = [double[]]::new($cols)
        $this.Std = [double[]]::new($cols)

        for ($c = 0; $c -lt $cols; $c++) {
            $sum = 0.0
            for ($r = 0; $r -lt $rows; $r++) {
                $row = [double[]]$Matrix.GetValue($r)
                $sum += $row[$c]
            }
            $m = $sum / $rows
            $this.Mean[$c] = $m

            $sqSum = 0.0
            for ($r = 0; $r -lt $rows; $r++) {
                $row = [double[]]$Matrix.GetValue($r)
                $diff = $row[$c] - $m
                $sqSum += ($diff * $diff)
            }
            $s = [math]::Sqrt($sqSum / [math]::Max(1, $rows - 1))
            $this.Std[$c] = if ($s -lt 1e-12) { 1.0 } else { $s }
        }
    }

[double[]] TransformRow([double[]]$Row) {
$cols = $Row.Count
$out = [double[]]::new($cols)
for ($c = 0; $c -lt $cols; $c++) {
$out[$c] = ($Row[$c] - $this.Mean[$c]) / $this.Std[$c]
}
return $out
}
[double[]] InverseTransformRow([double[]]$Row) {
$cols = $Row.Count
$out = [double[]]::new($cols)
for ($c = 0; $c -lt $cols; $c++) {
$out[$c] = ($Row[$c] * $this.Std[$c]) + $this.Mean[$c]
}
return $out
}
}
class HarmonicNeuralSurrogate {
[int]$InputDim = 24
[int]$HiddenDim
[int]$OutputDim = 6
[object[]]$W1
[double[]]$B1
[object[]]$mW1
[object[]]$vW1
[double[]]$mB1
[double[]]$vB1
[object[]]$W2
[double[]]$B2
[object[]]$mW2
[object[]]$vW2
[double[]]$mB2
[double[]]$vB2
[object[]]$W3
[double[]]$B3
[object[]]$mW3
[object[]]$vW3
[double[]]$mB3
[double[]]$vB3
[int]$TimeStep = 0
[HarmonicStandardScaler]$XScaler
[HarmonicStandardScaler]$YScaler
[hashtable]$Hyperparameters
HarmonicNeuralSurrogate([int]$HiddenDim, [int]$Seed) {
$this.HiddenDim = $HiddenDim
$rng = [System.Random]::new($Seed)
$this.W1 = $this.InitMatrix($this.InputDim, $HiddenDim, $rng)
$this.B1 = [double[]]::new($HiddenDim)
$this.mW1 = $this.ZeroMatrix($this.InputDim, $HiddenDim)
$this.vW1 = $this.ZeroMatrix($this.InputDim, $HiddenDim)
$this.mB1 = [double[]]::new($HiddenDim)
$this.vB1 = [double[]]::new($HiddenDim)
$this.W2 = $this.InitMatrix($HiddenDim, $HiddenDim, $rng)
$this.B2 = [double[]]::new($HiddenDim)
$this.mW2 = $this.ZeroMatrix($HiddenDim, $HiddenDim)
$this.vW2 = $this.ZeroMatrix($HiddenDim, $HiddenDim)
$this.mB2 = [double[]]::new($HiddenDim)
$this.vB2 = [double[]]::new($HiddenDim)
$this.W3 = $this.InitMatrix($HiddenDim, $this.OutputDim, $rng)
$this.B3 = [double[]]::new($this.OutputDim)
$this.mW3 = $this.ZeroMatrix($HiddenDim, $this.OutputDim)
$this.vW3 = $this.ZeroMatrix($HiddenDim, $this.OutputDim)
$this.mB3 = [double[]]::new($this.OutputDim)
$this.vB3 = [double[]]::new($this.OutputDim)
}
hidden [object[]] InitMatrix([int]$Rows, [int]$Cols, [System.Random]$Rng) {
$scale = [math]::Sqrt(2.0 / ($Rows + $Cols))
$mat = [object[]]::new($Rows)
for ($r = 0; $r -lt $Rows; $r++) {
$rowArr = [double[]]::new($Cols)
for ($c = 0; $c -lt $Cols; $c++) {
$u1 = 1.0 - $Rng.NextDouble()
$u2 = 1.0 - $Rng.NextDouble()
$gauss = [math]::Sqrt(-2.0 * [math]::Log($u1)) * [math]::Cos(2.0 * [math]::PI * $u2)
$rowArr[$c] = $gauss * $scale
}
$mat[$r] = $rowArr
}
return $mat
}
hidden [object[]] ZeroMatrix([int]$Rows, [int]$Cols) {
$mat = [object[]]::new($Rows)
for ($r = 0; $r -lt $Rows; $r++) {
$mat[$r] = [double[]]::new($Cols)
}
return $mat
}
hidden [double] Sigmoid([double]$x) {
if ($x -ge 0) {
return 1.0 / (1.0 + [math]::Exp(-$x))
} else {
$ez = [math]::Exp($x)
return $ez / (1.0 + $ez)
}
}
[hashtable] Forward([double[]]$X) {
$h = $this.HiddenDim
$z1 = [double[]]::new($h)
$a1 = [double[]]::new($h)
for ($j = 0; $j -lt $h; $j++) {
$sum = $this.B1[$j]
for ($i = 0; $i -lt $this.InputDim; $i++) {
$wRow = [double[]]$this.W1.GetValue($i)
$sum += $X[$i] * $wRow[$j]
}
$z1[$j] = $sum
$a1[$j] = $sum * $this.Sigmoid($sum)
}
$z2 = [double[]]::new($h)
$a2 = [double[]]::new($h)
for ($j = 0; $j -lt $h; $j++) {
$sum = $this.B2[$j]
for ($i = 0; $i -lt $h; $i++) {
$wRow = [double[]]$this.W2.GetValue($i)
$sum += $a1[$i] * $wRow[$j]
}
$z2[$j] = $sum
$a2[$j] = $sum * $this.Sigmoid($sum)
}
$out = [double[]]::new($this.OutputDim)
for ($k = 0; $k -lt $this.OutputDim; $k++) {
$sum = $this.B3[$k]
for ($j = 0; $j -lt $h; $j++) {
$wRow = [double[]]$this.W3.GetValue($j)
$sum += $a2[$j] * $wRow[$k]
}
if ($k -eq 5) {
$out[$k] = $this.Sigmoid($sum)
} else {
$out[$k] = $sum
}
}
return @{ Z1 = $z1; A1 = $a1; Z2 = $z2; A2 = $a2; Out = $out }
}
[double] TrainBatch([object[]]$BatchX, [object[]]$BatchY, [double]$Lr, [double]$WeightDecay, [double]$ClsWeight) {
$bSize = $BatchX.Count
$h = $this.HiddenDim
$gW1 = $this.ZeroMatrix($this.InputDim, $h); $gB1 = [double[]]::new($h)
$gW2 = $this.ZeroMatrix($h, $h); $gB2 = [double[]]::new($h)
$gW3 = $this.ZeroMatrix($h, $this.OutputDim); $gB3 = [double[]]::new($this.OutputDim)
$batchLoss = 0.0
for ($n = 0; $n -lt $bSize; $n++) {
$x = [double[]]$BatchX.GetValue($n)
$y = [double[]]$BatchY.GetValue($n)
$fwd = $this.Forward($x)
$pred = [double[]]$fwd.Out
$a1 = [double[]]$fwd.A1
$a2 = [double[]]$fwd.A2
$z1 = [double[]]$fwd.Z1
$z2 = [double[]]$fwd.Z2
$dOut = [double[]]::new($this.OutputDim)
for ($k = 0; $k -lt 5; $k++) {
$err = $pred[$k] - $y[$k]
$batchLoss += 0.5 * $err * $err
$dOut[$k] = [math]::Max(-1.0, [math]::Min(1.0, $err))
}
$predCls = $pred.GetValue(5)
$p = [math]::Min(1.0 - 1e-7, [math]::Max(1e-7, $predCls))
$targetCls = $y.GetValue(5)
$bce = -($targetCls * [math]::Log($p) + (1.0 - $targetCls) * [math]::Log(1.0 - $p))
$batchLoss += $ClsWeight * $bce
$dOut.SetValue(($ClsWeight * ($predCls - $targetCls)), 5)
$dA2 = [double[]]::new($h)
for ($j = 0; $j -lt $h; $j++) {
$acc = 0.0
$gw3Row = [double[]]$gW3.GetValue($j)
$w3Row = [double[]]$this.W3.GetValue($j)
for ($k = 0; $k -lt $this.OutputDim; $k++) {
$gw3Row[$k] += $a2[$j] * $dOut[$k]
$acc += $dOut[$k] * $w3Row[$k]
}
$dA2[$j] = $acc
}
for ($k = 0; $k -lt $this.OutputDim; $k++) { $gB3[$k] += $dOut[$k] }
$dZ2 = [double[]]::new($h)
for ($j = 0; $j -lt $h; $j++) {
$sig = $this.Sigmoid($z2[$j])
$siluGrad = $sig + ($z2[$j] * $sig * (1.0 - $sig))
$dZ2[$j] = $dA2[$j] * $siluGrad
$gB2[$j] += $dZ2[$j]
}
$dA1 = [double[]]::new($h)
for ($i = 0; $i -lt $h; $i++) {
$acc = 0.0
$gw2Row = [double[]]$gW2.GetValue($i)
$w2Row = [double[]]$this.W2.GetValue($i)
for ($j = 0; $j -lt $h; $j++) {
$gw2Row[$j] += $a1[$i] * $dZ2[$j]
$acc += $dZ2[$j] * $w2Row[$j]
}
$dA1[$i] = $acc
}
for ($j = 0; $j -lt $h; $j++) {
$sig = $this.Sigmoid($z1[$j])
$siluGrad = $sig + ($z1[$j] * $sig * (1.0 - $sig))
$dz1 = $dA1[$j] * $siluGrad
$gB1[$j] += $dz1
for ($i = 0; $i -lt $this.InputDim; $i++) {
$gw1Row = [double[]]$gW1.GetValue($i)
$gw1Row[$j] += $x[$i] * $dz1
}
}
}
$this.TimeStep++
$beta1 = 0.9; $beta2 = 0.999; $eps = 1e-8
$bc1 = 1.0 - [math]::Pow($beta1, $this.TimeStep)
$bc2 = 1.0 - [math]::Pow($beta2, $this.TimeStep)
$this.StepAdamMatrix($this.W1, $gW1, $this.mW1, $this.vW1, $bSize, $Lr, $WeightDecay, $beta1, $beta2, $bc1, $bc2, $eps)
$this.StepAdamVector($this.B1, $gB1, $this.mB1, $this.vB1, $bSize, $Lr, $beta1, $beta2, $bc1, $bc2, $eps)
$this.StepAdamMatrix($this.W2, $gW2, $this.mW2, $this.vW2, $bSize, $Lr, $WeightDecay, $beta1, $beta2, $bc1, $bc2, $eps)
$this.StepAdamVector($this.B2, $gB2, $this.mB2, $this.vB2, $bSize, $Lr, $beta1, $beta2, $bc1, $bc2, $eps)
$this.StepAdamMatrix($this.W3, $gW3, $this.mW3, $this.vW3, $bSize, $Lr, $WeightDecay, $beta1, $beta2, $bc1, $bc2, $eps)
$this.StepAdamVector($this.B3, $gB3, $this.mB3, $this.vB3, $bSize, $Lr, $beta1, $beta2, $bc1, $bc2, $eps)
return ($batchLoss / $bSize)
}
hidden [void] StepAdamMatrix([object[]]$W, [object[]]$G, [object[]]$M, [object[]]$V, [int]$BSize, [double]$Lr, [double]$Wd, [double]$B1, [double]$B2, [double]$Bc1, [double]$Bc2, [double]$Eps) {
$rows = $W.Count
$firstRow = [double[]]$W.GetValue(0)
$cols = $firstRow.Count
for ($r = 0; $r -lt $rows; $r++) {
$wRow = [double[]]$W.GetValue($r)
$gRow = [double[]]$G.GetValue($r)
$mRow = [double[]]$M.GetValue($r)
$vRow = [double[]]$V.GetValue($r)
for ($c = 0; $c -lt $cols; $c++) {
$grad = ($gRow[$c] / $BSize) + ($Wd * $wRow[$c])
$mRow[$c] = ($B1 * $mRow[$c]) + ((1.0 - $B1) * $grad)
$vRow[$c] = ($B2 * $vRow[$c]) + ((1.0 - $B2) * $grad * $grad)
$mHat = $mRow[$c] / $Bc1
$vHat = $vRow[$c] / $Bc2
$wRow[$c] -= $Lr * ($mHat / ([math]::Sqrt($vHat) + $Eps))
}
}
}
hidden [void] StepAdamVector([double[]]$B, [double[]]$G, [double[]]$M, [double[]]$V, [int]$BSize, [double]$Lr, [double]$B1, [double]$B2, [double]$Bc1, [double]$Bc2, [double]$Eps) {
for ($i = 0; $i -lt $B.Count; $i++) {
$grad = $G[$i] / $BSize
$M[$i] = ($B1 * $M[$i]) + ((1.0 - $B1) * $grad)
$V[$i] = ($B2 * $V[$i]) + ((1.0 - $B2) * $grad * $grad)
$mHat = $M[$i] / $Bc1
$vHat = $V[$i] / $Bc2
$B[$i] -= $Lr * ($mHat / ([math]::Sqrt($vHat) + $Eps))
}
}
}
function Invoke-HyperfineFrequencySift {
[CmdletBinding()]
param(
[Parameter(Mandatory)] [double[]]$SignalSeries,
[double]$FieldCouplingGain = 0.0,
[int]$MaxIterations = 4
)
return [HyperfineFrequencySifter]::Sift($SignalSeries, $FieldCouplingGain, $MaxIterations)
}
function New-HarmonicDataset {
[CmdletBinding()]
param(
[int]$Samples = 5000,
[int]$Seed = 2026
)
$rng = [System.Random]::new($Seed)
$X = [object[]]::new($Samples)
$Y = [object[]]::new($Samples)
for ($i = 0; $i -lt $Samples; $i++) {
$sample = [HarmonicPhysicsKernel]::SimulateSample($rng)
$X[$i] = $sample.X
$Y[$i] = $sample.Y
}
return [pscustomobject]@{
Features = $X
Targets  = $Y
Count    = $Samples
}
}
function Invoke-HarmonicHyperparameterTuning {
[CmdletBinding()]
param(
[Parameter(Mandatory)] [pscustomobject]$Dataset,
[int]$Trials = 6,
[int]$EpochsPerTrial = 10,
[int]$Seed = 2026
)
$rng = [System.Random]::new($Seed)
$n = $Dataset.Count
$splitIdx = [int][math]::Floor($n * 0.8)
$trainX = $Dataset.Features[0..($splitIdx - 1)]
$trainY = $Dataset.Targets[0..($splitIdx - 1)]
$valX   = $Dataset.Features[$splitIdx..($n - 1)]
$valY   = $Dataset.Targets[$splitIdx..($n - 1)]
$xScaler = [HarmonicStandardScaler]::new(); $xScaler.Fit($trainX)
$yScaler = [HarmonicStandardScaler]::new(); $yScaler.Fit($trainY)
$sTrainX = [object[]]::new($trainX.Count)
$sTrainY = [object[]]::new($trainY.Count)
for ($i = 0; $i -lt $trainX.Count; $i++) {
$sTrainX[$i] = $xScaler.TransformRow([double[]]$trainX.GetValue($i))
$rawY = [double[]]$trainY.GetValue($i)
$scaledY = $yScaler.TransformRow($rawY)
$scaledY.SetValue($rawY.GetValue(5), 5)
$sTrainY[$i] = $scaledY
}
$sValX = [object[]]::new($valX.Count)
$sValY = [object[]]::new($valY.Count)
for ($i = 0; $i -lt $valX.Count; $i++) {
$sValX[$i] = $xScaler.TransformRow([double[]]$valX.GetValue($i))
$rawY = [double[]]$valY.GetValue($i)
$scaledY = $yScaler.TransformRow($rawY)
$scaledY.SetValue($rawY.GetValue(5), 5)
$sValY[$i] = $scaledY
}
$hiddenChoices = @(32, 48, 64)
$batchChoices  = @(32, 64)
$bestLoss = [double]::PositiveInfinity
$bestConfig = $null
for ($t = 1; $t -le $Trials; $t++) {
$hDim = [int]$hiddenChoices.GetValue($rng.Next(0, $hiddenChoices.Count))
$bSize = [int]$batchChoices.GetValue($rng.Next(0, $batchChoices.Count))
$lr = [math]::Pow(10.0, -2.0 - ($rng.NextDouble() * 1.2))
$wd = [math]::Pow(10.0, -5.0 + ($rng.NextDouble() * 1.5))
$clsWt = 0.5 + ($rng.NextDouble() * 0.7)
$model = [HarmonicNeuralSurrogate]::new($hDim, $Seed + $t)
for ($ep = 1; $ep -le $EpochsPerTrial; $ep++) {
for ($idx = 0; $idx -lt $sTrainX.Count; $idx += $bSize) {
$end = [math]::Min($idx + $bSize - 1, $sTrainX.Count - 1)
$null = $model.TrainBatch($sTrainX[$idx..$end], $sTrainY[$idx..$end], $lr, $wd, $clsWt)
}
}
$valLoss = 0.0
for ($v = 0; $v -lt $sValX.Count; $v++) {
$fwdRes = $model.Forward([double[]]$sValX.GetValue($v))
$pred = [double[]]$fwdRes.Out
$target = [double[]]$sValY.GetValue($v)
for ($k = 0; $k -lt 5; $k++) {
$diff = $pred[$k] - $target[$k]
$valLoss += 0.5 * $diff * $diff
}
$p = [math]::Min(1.0 - 1e-7, [math]::Max(1e-7, $pred.GetValue(5)))
$tCls = $target.GetValue(5)
$valLoss += $clsWt * (-($tCls * [math]::Log($p) + (1.0 - $tCls) * [math]::Log(1.0 - $p)))
}
$valLoss /= $sValX.Count
Write-Host ("[Trial {0}/{1}] Hidden={2} | Batch={3} | LR={4:F5} | ValLoss={5:F5}" -f $t, $Trials, $hDim, $bSize, $lr, $valLoss) -ForegroundColor Cyan
if ($valLoss -lt $bestLoss) {
$bestLoss = $valLoss
$bestConfig = @{
HiddenDim    = $hDim
BatchSize    = $bSize
LearningRate = [math]::Round($lr, 6)
WeightDecay  = [math]::Round($wd, 7)
ClsWeight    = [math]::Round($clsWt, 4)
ValLoss      = [math]::Round($valLoss, 6)
}
}
}
return [pscustomobject]$bestConfig
}
function Train-HarmonicSurrogateModel {
[CmdletBinding()]
param(
[Parameter(Mandatory)] [pscustomobject]$Dataset,
[Parameter(Mandatory)] [pscustomobject]$Hyperparameters,
[int]$Epochs = 35,
[int]$Seed = 2026
)
$n = $Dataset.Count
$splitIdx = [int][math]::Floor($n * 0.85)
$trainX = $Dataset.Features[0..($splitIdx - 1)]
$trainY = $Dataset.Targets[0..($splitIdx - 1)]
$testX  = $Dataset.Features[$splitIdx..($n - 1)]
$testY  = $Dataset.Targets[$splitIdx..($n - 1)]
$xScaler = [HarmonicStandardScaler]::new(); $xScaler.Fit($trainX)
$yScaler = [HarmonicStandardScaler]::new(); $yScaler.Fit($trainY)
$sTrainX = [object[]]::new($trainX.Count)
$sTrainY = [object[]]::new($trainY.Count)
for ($i = 0; $i -lt $trainX.Count; $i++) {
$sTrainX[$i] = $xScaler.TransformRow([double[]]$trainX.GetValue($i))
$rawY = [double[]]$trainY.GetValue($i)
$scaledY = $yScaler.TransformRow($rawY)
$scaledY.SetValue($rawY.GetValue(5), 5)
$sTrainY[$i] = $scaledY
}
$model = [HarmonicNeuralSurrogate]::new($Hyperparameters.HiddenDim, $Seed)
$model.XScaler = $xScaler
$model.YScaler = $yScaler
$model.Hyperparameters = @{
HiddenDim    = $Hyperparameters.HiddenDim
BatchSize    = $Hyperparameters.BatchSize
LearningRate = $Hyperparameters.LearningRate
WeightDecay  = $Hyperparameters.WeightDecay
ClsWeight    = $Hyperparameters.ClsWeight
}
$bSize = $Hyperparameters.BatchSize
for ($ep = 1; $ep -le $Epochs; $ep++) {
$epLoss = 0.0
$batches = 0
for ($idx = 0; $idx -lt $sTrainX.Count; $idx += $bSize) {
$end = [math]::Min($idx + $bSize - 1, $sTrainX.Count - 1)
$epLoss += $model.TrainBatch(
$sTrainX[$idx..$end],
$sTrainY[$idx..$end],
$Hyperparameters.LearningRate,
$Hyperparameters.WeightDecay,
$Hyperparameters.ClsWeight
)
$batches++
}
if ($ep % 10 -eq 0 -or $ep -eq $Epochs) {
Write-Host ("[Epoch {0:D2}/{1:D2}] Train Loss: {2:F5}" -f $ep, $Epochs, ($epLoss / $batches)) -ForegroundColor Green
}
}
$fineLr = [math]::Round($Hyperparameters.LearningRate * 0.25, 6)
for ($ep = 1; $ep -le 15; $ep++) {
for ($idx = 0; $idx -lt $sTrainX.Count; $idx += $bSize) {
$end = [math]::Min($idx + $bSize - 1, $sTrainX.Count - 1)
$null = $model.TrainBatch(
$sTrainX[$idx..$end],
$sTrainY[$idx..$end],
$fineLr,
$Hyperparameters.WeightDecay,
$Hyperparameters.ClsWeight
)
}
}
$correct = 0
for ($i = 0; $i -lt $testX.Count; $i++) {
$pred = Invoke-HarmonicSurrogateInference -Model $model -FeatureVector ([double[]]$testX.GetValue($i))
$predClass = if ($pred.AutonomousReady) { 1.0 } else { 0.0 }
$tRow = [double[]]$testY.GetValue($i)
if ($predClass -eq $tRow.GetValue(5)) { $correct++ }
}
$acc = [math]::Round(($correct / $testX.Count) * 100.0, 2)
Write-Host ("[OK] Production Surrogate Hold-Out Settlement Accuracy: {0}%" -f $acc) -ForegroundColor Yellow
return $model
}
function Invoke-HarmonicSurrogateInference {
[CmdletBinding()]
param(
[Parameter(Mandatory)] [HarmonicNeuralSurrogate]$Model,
[Parameter(Mandatory)] [double[]]$FeatureVector
)
if ($FeatureVector.Count -ne 24) {
throw "FeatureVector must contain exactly 24 elements matching HarmonicPhysicsKernel v4.3.0 schema."
}
$xNorm = $Model.XScaler.TransformRow($FeatureVector)
$fwdRes = $Model.Forward($xNorm)
$rawOut = [double[]]$fwdRes.Out
$denorm = $Model.YScaler.InverseTransformRow($rawOut)
$prob = [math]::Round($rawOut.GetValue(5), 6)
return [pscustomobject]@{
PredictedPhaseError     = [math]::Round($denorm.GetValue(0), 6)
PredictedCouplingGain   = [math]::Round([math]::Min(1.0, [math]::Max(0.0, $denorm.GetValue(1))), 6)
PredictedFrequencyThz   = [math]::Round($denorm.GetValue(2), 6)
PredictedFusedEstimate  = [math]::Round($denorm.GetValue(3), 6)
PredictedWatermarkWt    = [math]::Round([math]::Min(0.85, [math]::Max(0.35, $denorm.GetValue(4))), 6)
AutonomousProbability   = $prob
AutonomousReady         = ($prob -ge 0.5)
}
}
function Export-HarmonicModelArtifact {
[CmdletBinding()]
param(
[Parameter(Mandatory)] [HarmonicNeuralSurrogate]$Model,
[Parameter(Mandatory)] [string]$Path
)
$payload = @{
Version         = '4.3.0'
InputDim        = $Model.InputDim
HiddenDim       = $Model.HiddenDim
Hyperparameters = $Model.Hyperparameters
XMean           = $Model.XScaler.Mean
XStd            = $Model.XScaler.Std
YMean           = $Model.YScaler.Mean
YStd            = $Model.YScaler.Std
W1 = $Model.W1; B1 = $Model.B1
W2 = $Model.W2; B2 = $Model.B2
W3 = $Model.W3; B3 = $Model.B3
}
$json = $payload | ConvertTo-Json -Depth 10 -Compress
[System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "[OK] Exported Distillate AI Model Artifact v4.3.0 to: $Path" -ForegroundColor Green
}
function Import-HarmonicModelArtifact {
[CmdletBinding()]
param(
[Parameter(Mandatory)] [string]$Path
)
$raw = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$model = [HarmonicNeuralSurrogate]::new([int]$raw.HiddenDim, 42)
$model.Hyperparameters = @{
HiddenDim    = $raw.Hyperparameters.HiddenDim
BatchSize    = $raw.Hyperparameters.BatchSize
LearningRate = $raw.Hyperparameters.LearningRate
WeightDecay  = $raw.Hyperparameters.WeightDecay
ClsWeight    = $raw.Hyperparameters.ClsWeight
}
$model.XScaler = [HarmonicStandardScaler]::new()
$model.XScaler.Mean = [double[]]$raw.XMean
$model.XScaler.Std  = [double[]]$raw.XStd
$model.YScaler = [HarmonicStandardScaler]::new()
$model.YScaler.Mean = [double[]]$raw.YMean
$model.YScaler.Std  = [double[]]$raw.YStd
for ($r = 0; $r -lt $raw.W1.Count; $r++) { $model.W1[$r] = [double[]]$raw.W1[$r] }
$model.B1 = [double[]]$raw.B1
for ($r = 0; $r -lt $raw.W2.Count; $r++) { $model.W2[$r] = [double[]]$raw.W2[$r] }
$model.B2 = [double[]]$raw.B2
for ($r = 0; $r -lt $raw.W3.Count; $r++) { $model.W3[$r] = [double[]]$raw.W3[$r] }
$model.B3 = [double[]]$raw.B3
return $model
}