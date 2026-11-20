Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = Join-Path (Get-Location).Path 'HarmonicPraxisAI'
Import-Module (Join-Path $BaseDir 'Harmonic5DImmersion.psd1') -Force

$Batch = New-Universal5DManifoldBatch -Samples 500 -Seed 2026
$ExportPath = Join-Path $BaseDir 'universal_5d_manifold_500.csv'
$Batch | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding utf8

$curvStats = $Batch | Measure-Object -Property MeanExtrinsicCurvatureH -Minimum -Maximum -Average
$bendStats = $Batch | Measure-Object -Property ExtrinsicBendingEnergy -Minimum -Maximum -Average
$isoStats  = $Batch | Measure-Object -Property IsometryMaxError -Maximum

Write-Host "`n=== 1. 500-STEP 5D MANIFOLD BATCH SUMMARY ===" -ForegroundColor Cyan
[pscustomobject]@{
    TotalSteps             = $Batch.Count
    ExportedCsvPath        = $ExportPath
    MeanCurvatureH_Avg     = [math]::Round($curvStats.Average, 6)
    MeanCurvatureH_Min     = [math]::Round($curvStats.Minimum, 6)
    MeanCurvatureH_Max     = [math]::Round($curvStats.Maximum, 6)
    BendingEnergy_Avg      = [math]::Round($bendStats.Average, 6)
    BendingEnergy_Max      = [math]::Round($bendStats.Maximum, 6)
    MaxIsometryDriftError  = $isoStats.Maximum
} | Format-List

Write-Host "=== 2. SAMPLE TRAJECTORY STEPS (FIRST 10 OF 500) ===" -ForegroundColor Cyan
$Batch | Select-Object -First 10 | Format-Table -AutoSize