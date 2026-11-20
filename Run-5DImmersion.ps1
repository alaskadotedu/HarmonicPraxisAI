Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = Join-Path (Get-Location).Path 'HarmonicPraxisAI'
Import-Module (Join-Path $BaseDir 'Harmonic5DImmersion.psd1') -Force

$projection = Invoke-Universal5DImmersionStep -X 1.25 -Y -0.80 -Z 2.40 -Tau 0.002 -Psi 1.0471975512 -CouplingGain 0.68 -SiftPurity 0.91

Write-Host "`n=== 1. EXTRINSIC 5D -> 6D UNIFORM IMMERSION PROJECTION ===" -ForegroundColor Cyan
$projection | Select-Object MeanExtrinsicCurvatureH, ExtrinsicBendingEnergy, IsometryMaxError | Format-List

Write-Host "=== 2. INDUCED RIEMANNIAN METRIC TENSOR (g_ij = J^T * J = I_5) ===" -ForegroundColor Cyan
$metricMap = $projection.InducedMetric5x5
$metricRows = for ($rowIdx = 0; $rowIdx -lt 5; $rowIdx++) {
[pscustomobject]@{
Dim = "e_$($rowIdx + 1)"
C1  = $metricMap["$rowIdx,0"]
C2  = $metricMap["$rowIdx,1"]
C3  = $metricMap["$rowIdx,2"]
C4  = $metricMap["$rowIdx,3"]
C5  = $metricMap["$rowIdx,4"]
}
}
$metricRows | Format-Table -AutoSize
Write-Host "=== 3. EXTRINSIC SECOND FUNDAMENTAL FORM MATRIX (II_ij) ===" -ForegroundColor Cyan
$secondFormMap = $projection.ExtrinsicSecondForm5x5
$iiRows = for ($rowIdx = 0; $rowIdx -lt 5; $rowIdx++) {
[pscustomobject]@{
Dim = "e_$($rowIdx + 1)"
C1  = $secondFormMap["$rowIdx,0"]
C2  = $secondFormMap["$rowIdx,1"]
C3  = $secondFormMap["$rowIdx,2"]
C4  = $secondFormMap["$rowIdx,3"]
C5  = $secondFormMap["$rowIdx,4"]
}
}
$iiRows | Format-Table -AutoSize
Write-Host "=== 4. AMBIENT 6D IMMERSED COORDINATES & NORMAL VECTOR ===" -ForegroundColor Cyan
[pscustomobject]@{
Intrinsic_5D = $projection.Intrinsic5DFormatted
Immersed_6D  = $projection.Immersed6DFormatted
Normal_6D    = $projection.Normal6DFormatted
} | Format-List