Set-StrictMode -Version Latest

class Extrinsic5DImmersionEngine {
    static [double[]] MakeRow5([double]$v0, [double]$v1, [double]$v2, [double]$v3, [double]$v4) {
        $arr = [double[]]::new(5)
        $arr.SetValue($v0, 0); $arr.SetValue($v1, 1); $arr.SetValue($v2, 2); $arr.SetValue($v3, 3); $arr.SetValue($v4, 4)
        return $arr
    }

    static [hashtable] BuildUniformImmersionMatrices([double]$PhasePsi, [double]$CouplingGain, [double]$SiftPurity) {
        $cP = [math]::Cos($PhasePsi); $sP = [math]::Sin($PhasePsi)
        $c2P = [math]::Cos(2.0 * $PhasePsi); $s2P = [math]::Sin(2.0 * $PhasePsi)
        $invSqrt2 = 0.7071067811865475

        $J = [object[]]::new(6)
        $J.SetValue([Extrinsic5DImmersionEngine]::MakeRow5($invSqrt2 * $cP, -$invSqrt2 * $sP, 0.0, 0.0, 0.0), 0)
        $J.SetValue([Extrinsic5DImmersionEngine]::MakeRow5($invSqrt2 * $sP,  $invSqrt2 * $cP, 0.0, 0.0, 0.0), 1)
        $J.SetValue([Extrinsic5DImmersionEngine]::MakeRow5(0.0, 0.0, $invSqrt2 * $c2P, -$invSqrt2 * $s2P, 0.0), 2)
        $J.SetValue([Extrinsic5DImmersionEngine]::MakeRow5(0.0, 0.0, $invSqrt2 * $s2P,  $invSqrt2 * $c2P, 0.0), 3)
        $J.SetValue([Extrinsic5DImmersionEngine]::MakeRow5(0.0, 0.0, 0.0, 0.0, $cP), 4)
        $J.SetValue([Extrinsic5DImmersionEngine]::MakeRow5(0.0, 0.0, 0.0, 0.0, $sP), 5)

        $Gram = [object[]]::new(5)
        $orthogonalityMaxError = 0.0
        for ($i = 0; $i -lt 5; $i++) {
            $gRow = [double[]]::new(5)
            for ($j = 0; $j -lt 5; $j++) {
                $dot = 0.0
                for ($r = 0; $r -lt 6; $r++) {
                    $jRow = [double[]]$J.GetValue($r)
                    $dot += ([double]$jRow.GetValue($i) * [double]$jRow.GetValue($j))
                }
                $gRow.SetValue([math]::Round($dot, 12), $j)
                $expected = if ($i -eq $j) { 1.0 } else { 0.0 }
                $err = [math]::Abs($dot - $expected)
                if ($err -gt $orthogonalityMaxError) { $orthogonalityMaxError = $err }
            }
            $Gram.SetValue($gRow, $i)
        }

        $kBase = (1.0 + (2.5 * $CouplingGain)) * (1.2 - (0.5 * $SiftPurity))
        $II = [object[]]::new(5)
        $II.SetValue([Extrinsic5DImmersionEngine]::MakeRow5([math]::Round($kBase * $cP, 6), [math]::Round(0.15 * $CouplingGain * $sP, 6), 0.0, 0.0, [math]::Round(0.25 * $CouplingGain, 6)), 0)
        $II.SetValue([Extrinsic5DImmersionEngine]::MakeRow5([math]::Round(0.15 * $CouplingGain * $sP, 6), [math]::Round($kBase * $cP, 6), 0.0, 0.0, [math]::Round(-0.25 * $CouplingGain, 6)), 1)
        $II.SetValue([Extrinsic5DImmersionEngine]::MakeRow5(0.0, 0.0, [math]::Round(0.85 * $kBase * $c2P, 6), [math]::Round(0.10 * $s2P, 6), 0.0), 2)
        $II.SetValue([Extrinsic5DImmersionEngine]::MakeRow5(0.0, 0.0, [math]::Round(0.10 * $s2P, 6), [math]::Round(-0.85 * $kBase * $c2P, 6), 0.0), 3)
        $II.SetValue([Extrinsic5DImmersionEngine]::MakeRow5([math]::Round(0.25 * $CouplingGain, 6), [math]::Round(-0.25 * $CouplingGain, 6), 0.0, 0.0, [math]::Round(1.5 * $kBase, 6)), 4)

        $trace = 0.0
        for ($d = 0; $d -lt 5; $d++) {
            $iiRow = [double[]]$II.GetValue($d)
            $trace += [double]$iiRow.GetValue($d)
        }

        return @{
            ImmersionJacobian6x5    = $J
            InducedMetric5x5        = $Gram
            ExtrinsicSecondForm5x5  = $II
            MeanExtrinsicCurvatureH = [math]::Round($trace / 5.0, 6)
            IsometryMaxError        = [math]::Round($orthogonalityMaxError, 15)
        }
    }

    static [pscustomobject] Project5DState([double[]]$State5D, [double]$CouplingGain, [double]$SiftPurity) {
        $psi = [double]$State5D.GetValue(4)
        $mats = [Extrinsic5DImmersionEngine]::BuildUniformImmersionMatrices($psi, $CouplingGain, $SiftPurity)
        $J = [object[]]$mats.ImmersionJacobian6x5
        $II = [object[]]$mats.ExtrinsicSecondForm5x5

        $ambient6D = [double[]]::new(6)
        for ($r = 0; $r -lt 6; $r++) {
            $jRow = [double[]]$J.GetValue($r)
            $acc = 0.0
            for ($c = 0; $c -lt 5; $c++) { $acc += ([double]$jRow.GetValue($c) * [double]$State5D.GetValue($c)) }
            $ambient6D.SetValue([math]::Round($acc, 8), $r)
        }

        $extrinsicBendingEnergy = 0.0
        for ($i = 0; $i -lt 5; $i++) {
            $iiRow = [double[]]$II.GetValue($i)
            $sI = [double]$State5D.GetValue($i)
            for ($j = 0; $j -lt 5; $j++) { $extrinsicBendingEnergy += ($sI * [double]$iiRow.GetValue($j) * [double]$State5D.GetValue($j)) }
        }

        return [pscustomobject]@{
            IntrinsicState5D        = $State5D
            ImmersedAmbient6D       = $ambient6D
            MeanExtrinsicCurvatureH = $mats.MeanExtrinsicCurvatureH
            ExtrinsicBendingEnergy  = [math]::Round($extrinsicBendingEnergy, 6)
            IsometryMaxError        = $mats.IsometryMaxError
        }
    }
}

function New-Extrinsic5DImmersionMatrix {
    param([double]$PhasePsi = 0.78539816339, [double]$CouplingGain = 0.45, [double]$SiftPurity = 0.92)
    return [Extrinsic5DImmersionEngine]::BuildUniformImmersionMatrices($PhasePsi, $CouplingGain, $SiftPurity)
}

function Invoke-Universal5DImmersionStep {
    param([Parameter(Mandatory)][double[]]$State5D, [double]$CouplingGain = 0.45, [double]$SiftPurity = 0.92)
    return [Extrinsic5DImmersionEngine]::Project5DState($State5D, $CouplingGain, $SiftPurity)
}

function New-Universal5DManifoldBatch {
    param([int]$Samples = 500, [int]$Seed = 2026)
    $rng = [System.Random]::new($Seed); $records = [object[]]::new($Samples)
    for ($i = 0; $i -lt $Samples; $i++) {
        $s5d = [Extrinsic5DImmersionEngine]::MakeRow5((($rng.NextDouble()-0.5)*20), (($rng.NextDouble()-0.5)*20), (($rng.NextDouble()-0.5)*20), ($i*0.002), (($rng.NextDouble()*2*[math]::PI)-[math]::PI))
        $proj = [Extrinsic5DImmersionEngine]::Project5DState($s5d, $rng.NextDouble(), (0.4 + ($rng.NextDouble()*0.6)))
        $records.SetValue($proj, $i)
    }
    return $records
}