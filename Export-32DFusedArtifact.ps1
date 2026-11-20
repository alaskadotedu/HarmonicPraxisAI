using module .\HarmonicPraxisAI.psd1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ArtifactPath = Join-Path $BaseDir "harmonic_surrogate_32d_fused_v4_5.json"
class Clean5DImmersionEngine {
    static [pscustomobject] Project([double[]]$S, [double]$Gain, [double]$Purity) {
        $s0 = [double]$S.GetValue(0); $s1 = [double]$S.GetValue(1); $s2 = [double]$S.GetValue(2); $s3 = [double]$S.GetValue(3); $psi = [double]$S.GetValue(4)
        $cP = [math]::Cos($psi); $sP = [math]::Sin($psi); $c2P = [math]::Cos(2.0 * $psi); $s2P = [math]::Sin(2.0 * $psi); $inv2 = 0.7071067811865475
        $amb = [double[]]::new(6)
        $amb.SetValue([math]::Round(($inv2 * $cP * $s0) - ($inv2 * $sP * $s1), 8), 0); $amb.SetValue([math]::Round(($inv2 * $sP * $s0) + ($inv2 * $cP * $s1), 8), 1)
        $amb.SetValue([math]::Round(($inv2 * $c2P * $s2) - ($inv2 * $s2P * $s3), 8), 2); $amb.SetValue([math]::Round(($inv2 * $s2P * $s2) + ($inv2 * $c2P * $s3), 8), 3)
        $amb.SetValue([math]::Round($cP * $psi, 8), 4); $amb.SetValue([math]::Round($sP * $psi, 8), 5)
        $k = (1.0 + (2.5 * $Gain)) * (1.2 - (0.5 * $Purity))
        $d0 = $k * $cP; $d1 = $k * $cP; $d2 = 0.85 * $k * $c2P; $d3 = -0.85 * $k * $c2P; $d4 = 1.5 * $k
        $off01 = 0.15 * $Gain * $sP; $off04 = 0.25 * $Gain; $off14 = -0.25 * $Gain; $off23 = 0.10 * $s2P
        $H = [math]::Round(($d0 + $d1 + $d2 + $d3 + $d4) / 5.0, 6)
        $bend = ($d0*$s0*$s0) + ($d1*$s1*$s1) + ($d2*$s2*$s2) + ($d3*$s3*$s3) + ($d4*$psi*$psi) + (2.0*$off01*$s0*$s1) + (2.0*$off04*$s0*$psi) + (2.0*$off14*$s1*$psi) + (2.0*$off23*$s2*$s3)
        return [pscustomobject]@{ ImmersedAmbient6D = $amb; MeanExtrinsicCurvatureH = $H; ExtrinsicBendingEnergy = [math]::Round($bend, 6) }
    }
}
class Harmonic6DFusedSurrogate {
    [int]$InputDim = 32; [int]$HiddenDim = 48; [int]$OutputDim = 6; [HarmonicNeuralSurrogate]$CoreNet
    Harmonic6DFusedSurrogate([int]$Hidden, [int]$Seed) {
        $this.HiddenDim = $Hidden; $net = [HarmonicNeuralSurrogate]::new($Hidden, $Seed); $net.InputDim = 32; $rng = [System.Random]::new($Seed)
        $net.W1 = $net.InitMatrix(32, $Hidden, $rng); $net.mW1 = $net.ZeroMatrix(32, $Hidden); $net.vW1 = $net.ZeroMatrix(32, $Hidden); $this.CoreNet = $net
    }
    static [double[]] Build32D([double[]]$B24, [double[]]$Amb6, [double]$H, [double]$Bend) {
        $vec = [double[]]::new(32)
        for ($i = 0; $i -lt 24; $i++) { $vec.SetValue([double]$B24.GetValue($i), $i) }
        for ($j = 0; $j -lt 6; $j++)  { $vec.SetValue([double]$Amb6.GetValue($j), 24 + $j) }
        $vec.SetValue($H, 30); $vec.SetValue($Bend, 31); return $vec
    }
    static [void] Export32D([HarmonicNeuralSurrogate]$Net, [string]$Path) {
        $p = [ordered]@{ Schema="HarmonicPraxisAI.Fused32D.v4.5"; InputDim=32; HiddenDim=$Net.HiddenDim; OutputDim=6; XMean=$Net.XScaler.Mean; XStd=$Net.XScaler.Std; YMean=$Net.YScaler.Mean; YStd=$Net.YScaler.Std; W1=$Net.W1; B1=$Net.B1; W2=$Net.W2; B2=$Net.B2; W3=$Net.W3; B3=$Net.B3 }
        [System.IO.File]::WriteAllText($Path, ($p | ConvertTo-Json -Depth 10 -Compress), [System.Text.UTF8Encoding]::new($false))
    }
    static [HarmonicNeuralSurrogate] Import32D([string]$Path) {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $w = [Harmonic6DFusedSurrogate]::new([int]$raw.HiddenDim, 42); $net = $w.CoreNet
        $net.XScaler = [HarmonicStandardScaler]::new(); $net.XScaler.Mean = [double[]]$raw.XMean; $net.XScaler.Std = [double[]]$raw.XStd
        $net.YScaler = [HarmonicStandardScaler]::new(); $net.YScaler.Mean = [double[]]$raw.YMean; $net.YScaler.Std = [double[]]$raw.YStd
        for ($r = 0; $r -lt $raw.W1.Count; $r++) { $net.W1.SetValue([double[]]$raw.W1.GetValue($r), $r) }; $net.B1 = [double[]]$raw.B1
        for ($r = 0; $r -lt $raw.W2.Count; $r++) { $net.W2.SetValue([double[]]$raw.W2.GetValue($r), $r) }; $net.B2 = [double[]]$raw.B2
        for ($r = 0; $r -lt $raw.W3.Count; $r++) { $net.W3.SetValue([double[]]$raw.W3.GetValue($r), $r) }; $net.B3 = [double[]]$raw.B3
        return $net
    }
}
$Rng = [System.Random]::new(2026); $N = 2500; $XAll = [object[]]::new($N); $YAll = [object[]]::new($N)
for ($i = 0; $i -lt $N; $i++) {
    $sim = [HarmonicPhysicsKernel]::SimulateSample($Rng); $b24 = [double[]]$sim.X; $y6 = [double[]]$sim.Y
    $s5d = [double[]]::new(5); $s5d.SetValue(([double]$b24.GetValue(1)*0.01),0); $s5d.SetValue(([double]$b24.GetValue(2)*0.01),1); $s5d.SetValue(([double]$b24.GetValue(3)*0.01),2); $s5d.SetValue(($i*0.002),3); $s5d.SetValue([double]$b24.GetValue(0),4)
    $proj = [Clean5DImmersionEngine]::Project($s5d, [double]$y6.GetValue(1), [double]$b24.GetValue(21))
    $f32 = [Harmonic6DFusedSurrogate]::Build32D($b24, [double[]]$proj.ImmersedAmbient6D, [double]$proj.MeanExtrinsicCurvatureH, [double]$proj.ExtrinsicBendingEnergy)
    $pen = [math]::Min(0.15, ([math]::Abs([double]$proj.ExtrinsicBendingEnergy) * 0.002)); $adj = [math]::Max(0.35, ([double]$y6.GetValue(4) - $pen))
    $y6.SetValue($adj, 4); $y6.SetValue($(if ($adj -ge 0.68 -and $sim.Sift.PhaseLocked) { 1.0 } else { 0.0 }), 5); $XAll.SetValue($f32, $i); $YAll.SetValue($y6, $i)
}
$Wrap = [Harmonic6DFusedSurrogate]::new(48, 2026); $Net = $Wrap.CoreNet
$xs = [HarmonicStandardScaler]::new(); $xs.Fit($XAll); $ys = [HarmonicStandardScaler]::new(); $ys.Fit($YAll); $Net.XScaler = $xs; $Net.YScaler = $ys
$sX = [object[]]::new($N); $sY = [object[]]::new($N)
for ($i = 0; $i -lt $N; $i++) { $sX.SetValue([double[]]($xs.TransformRow([double[]]$XAll.GetValue($i))), $i); $ry = [double[]]$YAll.GetValue($i); $sy = $ys.TransformRow($ry); $sy.SetValue([double]$ry.GetValue(5), 5); $sY.SetValue([double[]]$sy, $i) }
for ($ep = 1; $ep -le 30; $ep++) { $loss = 0.0; $bc = 0; for ($idx = 0; $idx -lt $N; $idx += 64) { $end = [math]::Min($idx+63, $N-1); $loss += $Net.TrainBatch($sX[$idx..$end], $sY[$idx..$end], 0.003, 0.0001, 0.85); $bc++ }; if ($ep % 10 -eq 0) { Write-Host ("[32D Epoch {0:D2}/30] Loss: {1:F5}" -f $ep, ($loss/$bc)) -ForegroundColor Green } }
[Harmonic6DFusedSurrogate]::Export32D($Net, $ArtifactPath)
$fi = Get-Item -LiteralPath $ArtifactPath; $rel = [Harmonic6DFusedSurrogate]::Import32D($ArtifactPath)
$pv = [double[]]$XAll.GetValue(0); $o1 = [double[]]($Net.Forward($Net.XScaler.TransformRow($pv)).Out); $o2 = [double[]]($rel.Forward($rel.XScaler.TransformRow($pv)).Out)
$err = 0.0; for ($k = 0; $k -lt 6; $k++) { $d = [math]::Abs([double]$o1.GetValue($k) - [double]$o2.GetValue($k)); if ($d -gt $err) { $err = $d } }
[pscustomobject]@{ ArtifactFile=$fi.Name; SizeKB=[math]::Round($fi.Length/1KB, 2); InputDim=$rel.InputDim; HiddenDim=$rel.HiddenDim; MaxParityError=$err; ParityVerified=($err -lt 1e-12) } | Format-List
