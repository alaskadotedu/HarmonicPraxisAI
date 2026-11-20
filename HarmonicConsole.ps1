param(
[ValidateSet('Audit', 'Train', 'Benchmark', 'StartServer', 'QueryServer', 'StopServer', 'Interactive')]
[string]$Action = 'Audit',
[int]$Samples = 5000,
[int]$Seed = 2026
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Join-Path (Get-Location).Path 'HarmonicPraxisAI'
$ManifestPath = Join-Path $BaseDir 'HarmonicPraxisAI.psd1'
$ArtifactPath = Join-Path $BaseDir 'harmonic_surrogate_v4_3.json'
$AuditLogPath = Join-Path $BaseDir 'telemetry_drift_audit.csv'
Import-Module $ManifestPath -Force
function Invoke-TrainPipeline([int]$SampleCount, [int]$RngSeed) {
$ds = New-HarmonicDataset -Samples $SampleCount -Seed $RngSeed
$hp = Invoke-HarmonicHyperparameterTuning -Dataset $ds -Trials 6 -EpochsPerTrial 10 -Seed $RngSeed
if ($hp.HiddenDim -lt 48) { $hp.HiddenDim = 48 }
$hp | Format-Table -AutoSize
$m = Train-HarmonicSurrogateModel -Dataset $ds -Hyperparameters $hp -Epochs 35 -Seed $RngSeed
Export-HarmonicModelArtifact -Model $m -Path $ArtifactPath
}
function Invoke-BenchmarkPipeline {
$m = Import-HarmonicModelArtifact -Path $ArtifactPath
$evalDs = New-HarmonicDataset -Samples 1000 -Seed 9999
$sqErr = [double[]]::new(5)
$correct = 0
for ($i = 0; $i -lt $evalDs.Count; $i++) {
$xVec = [double[]]$evalDs.Features.GetValue($i)
$yTrue = [double[]]$evalDs.Targets.GetValue($i)
$pred = Invoke-HarmonicSurrogateInference -Model $m -FeatureVector $xVec
$predsArr = @($pred.PredictedPhaseError, $pred.PredictedCouplingGain, $pred.PredictedFrequencyThz, $pred.PredictedFusedEstimate, $pred.PredictedWatermarkWt)
for ($k = 0; $k -lt 5; $k++) {
$diff = $predsArr[$k] - $yTrue.GetValue($k)
$sqErr[$k] += ($diff * $diff)
}
$pCls = if ($pred.AutonomousReady) { 1.0 } else { 0.0 }
if ($pCls -eq $yTrue.GetValue(5)) { $correct++ }
}
$tc = $evalDs.Count
[pscustomobject]@{
BenchmarkSamples      = $tc
SettlementAccuracyPct = [math]::Round(($correct / $tc) * 100.0, 2)
PhaseError_RMSE       = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
CouplingGain_RMSE     = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
FrequencyThz_RMSE     = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
FusedEstimate_RMSE    = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
WatermarkWt_RMSE      = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
} | Format-List
}
function Invoke-SiftAuditPipeline {
$m = Import-HarmonicModelArtifact -Path $ArtifactPath
$rng = [System.Random]::new()
$sample = [HarmonicPhysicsKernel]::SimulateSample($rng)
$xVec = [double[]]$sample.X
$yTrue = [double[]]$sample.Y
$pred = Invoke-HarmonicSurrogateInference -Model $m -FeatureVector $xVec
Write-Host "--- HYPERFINE FREQUENCY SIFT DECOMPOSITION ---" -ForegroundColor Yellow
$sample.Sift | Select-Object SiftedFrequencyHz, ResidualNoise, SiftPurity, ZeroCrossings, PhaseLocked | Format-List
Write-Host "--- SURROGATE VS. GROUND-TRUTH TELEMETRY ---" -ForegroundColor Yellow
[pscustomobject]@{
TruePhaseError        = [math]::Round($yTrue.GetValue(0), 6)
PredPhaseError        = $pred.PredictedPhaseError
TrueCouplingGain      = [math]::Round($yTrue.GetValue(1), 6)
PredCouplingGain      = $pred.PredictedCouplingGain
TrueFrequencyThz      = [math]::Round($yTrue.GetValue(2), 6)
PredFrequencyThz      = $pred.PredictedFrequencyThz
TrueFusedEstimate     = [math]::Round($yTrue.GetValue(3), 6)
PredFusedEstimate     = $pred.PredictedFusedEstimate
TrueWatermarkWt       = [math]::Round($yTrue.GetValue(4), 6)
PredWatermarkWt       = $pred.PredictedWatermarkWt
TrueAutonomous        = ($yTrue.GetValue(5) -eq 1.0)
PredAutonomous        = $pred.AutonomousReady
AutonomousProbability = $pred.AutonomousProbability
} | Format-List
}
function Start-BackgroundRestServer {
try {
$check = Invoke-RestMethod -Uri "http://localhost:8085/health" -Method Get -TimeoutSec 1
Write-Host "[INFO] Service already ONLINE (Requests: $($check.TotalRequests))." -ForegroundColor Yellow
return
} catch {}
$null = Start-Job -Name 'HarmonicRestDaemon' -ScriptBlock {
param($MPath, $APath, $LPath)
Import-Module $MPath -Force
$SrvModel = Import-HarmonicModelArtifact -Path $APath
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://localhost:8085/")
$Listener.Start()
$Rng = [System.Random]::new()
$TotalRequests = 0; $AutonomousCount = 0; $DriftAlerts = 0
try {
while ($Listener.IsListening) {
$Context = $Listener.GetContext()
$Req = $Context.Request; $Res = $Context.Response
$Path = $Req.Url.AbsolutePath.ToLowerInvariant()
$Method = $Req.HttpMethod.ToUpperInvariant()
$StatusCode = 200; $ResponseObj = $null
try {
if ($Method -eq 'GET' -and $Path -eq '/health') {
$ResponseObj = [ordered]@{ Status = 'ONLINE'; Version = '4.3.0'; InputDim = 24; HiddenDim = $SrvModel.HiddenDim; TotalRequests = $TotalRequests; AutonomousCount = $AutonomousCount; DriftAlerts = $DriftAlerts }
}
elseif ($Method -eq 'GET' -and $Path -eq '/simulate') {
$sample = [HarmonicPhysicsKernel]::SimulateSample($Rng)
$xVec = [double[]]$sample.X; $yTrue = [double[]]$sample.Y
$pred = Invoke-HarmonicSurrogateInference -Model $SrvModel -FeatureVector $xVec
$drift = [math]::Abs($pred.PredictedWatermarkWt - $yTrue.GetValue(4))
if ($drift -gt 0.08) { $DriftAlerts++ }
if ($pred.AutonomousReady) { $AutonomousCount++ }
$TotalRequests++
[pscustomobject]@{ TimestampUtc = [DateTime]::UtcNow.ToString('o'); SiftPurity = $sample.Sift.SiftPurity; SiftedFreqHz = $sample.Sift.SiftedFrequencyHz; TrueWatermarkWt = [math]::Round($yTrue.GetValue(4), 6); PredictedWatermarkWt = $pred.PredictedWatermarkWt; WatermarkDrift = [math]::Round($drift, 6); AutonomousReady = $pred.AutonomousReady } | Export-Csv -Path $LPath -Append -NoTypeInformation
$ResponseObj = [ordered]@{ SiftTelemetry = $sample.Sift; GroundTruthWatermark = [math]::Round($yTrue.GetValue(4), 6); SurrogatePrediction = $pred; WatermarkDrift = [math]::Round($drift, 6) }
}
elseif ($Method -eq 'POST' -and $Path -eq '/predict') {
$Reader = [System.IO.StreamReader]::new($Req.InputStream, $Req.ContentEncoding)
$Payload = $Reader.ReadToEnd() | ConvertFrom-Json
$Reader.Close()
$pred = Invoke-HarmonicSurrogateInference -Model $SrvModel -FeatureVector ([double[]]$Payload.features)
if ($pred.AutonomousReady) { $AutonomousCount++ }
$TotalRequests++
$ResponseObj = [ordered]@{ Prediction = $pred }
}
elseif ($Method -eq 'POST' -and $Path -eq '/stop') {
$Bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ Status = 'SHUTTING_DOWN' } | ConvertTo-Json))
$Res.StatusCode = 200; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $Bytes.Length
$Res.OutputStream.Write($Bytes, 0, $Bytes.Length); $Res.OutputStream.Close()
break
}
else {
$StatusCode = 404
$ResponseObj = [ordered]@{ Error = 'Unknown endpoint' }
}
}
catch {
$StatusCode = 400
$ResponseObj = [ordered]@{ Error = $_.Exception.Message }
}
$Bytes = [System.Text.Encoding]::UTF8.GetBytes(($ResponseObj | ConvertTo-Json -Depth 6))
$Res.StatusCode = $StatusCode; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $Bytes.Length
$Res.OutputStream.Write($Bytes, 0, $Bytes.Length); $Res.OutputStream.Close()
}
}
finally {
$Listener.Stop(); $Listener.Close()
}
} -ArgumentList $ManifestPath, $ArtifactPath, $AuditLogPath
Start-Sleep -Milliseconds 600
Write-Host "[ACTIVE] Background REST Service v4.3.0 running on http://localhost:8085/" -ForegroundColor Green
}
switch ($Action) {
'Train'       { Invoke-TrainPipeline -SampleCount $Samples -RngSeed $Seed }
'Benchmark'   { Invoke-BenchmarkPipeline }
'Audit'       { Invoke-SiftAuditPipeline }
'StartServer' { Start-BackgroundRestServer }
'QueryServer' {
Invoke-RestMethod -Uri "http://localhost:8085/health" -Method Get | Format-List
$sim = Invoke-RestMethod -Uri "http://localhost:8085/simulate" -Method Get
$sim.SiftTelemetry | Select-Object SiftedFrequencyHz, ResidualNoise, SiftPurity, PhaseLocked | Format-List
$sim.SurrogatePrediction | Format-List
}
'StopServer'  {
try { $null = Invoke-RestMethod -Uri "http://localhost:8085/stop" -Method Post -TimeoutSec 2 } catch {}
Get-Job -Name 'HarmonicRestDaemon' -ErrorAction SilentlyContinue | Remove-Job -Force
Write-Host "[STOPPED] Background HTTP Server terminated." -ForegroundColor Yellow
}
'Interactive' {
while ($true) {
Write-Host "`n=======================================================" -ForegroundColor DarkCyan
Write-Host "   HARMONIC AUTONOMOUS PRAXIS v4.3.0 - SIFT & AI CLI   " -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor DarkCyan
Write-Host " Retrain & Tune 24-Feature Sift-Coupled Surrogate Model"
Write-Host " Run Hold-Out Telemetry RMSE Precision Benchmark"
Write-Host " Execute Live Hyperfine Frequency Sift & Inference Audit"
Write-Host " Start Continuous Background HTTP Server (Port 8085)"
Write-Host " Query Live HTTP Server (/health & /simulate)"
Write-Host " Stop Background HTTP Server & Exit"
Write-Host "=======================================================" -ForegroundColor DarkCyan
$choice = Read-Host "Select an operation [1-6]"
switch ($choice) {
'1' { Invoke-TrainPipeline -SampleCount $Samples -RngSeed $Seed }
'2' { Invoke-BenchmarkPipeline }
'3' { Invoke-SiftAuditPipeline }
'4' { Start-BackgroundRestServer }
'5' {
try {
Invoke-RestMethod -Uri "http://localhost:8085/health" -Method Get | Format-List
$sim = Invoke-RestMethod -Uri "http://localhost:8085/simulate" -Method Get
$sim.SiftTelemetry | Select-Object SiftedFrequencyHz, ResidualNoise, SiftPurity, PhaseLocked | Format-List
$sim.SurrogatePrediction | Format-List
} catch { Write-Host "[WARN] HTTP Server offline. Select Option 4 first." -ForegroundColor Red }
}
'6' {
try { $null = Invoke-RestMethod -Uri "http://localhost:8085/stop" -Method Post -TimeoutSec 2 } catch {}
Get-Job -Name 'HarmonicRestDaemon' -ErrorAction SilentlyContinue | Remove-Job -Force
Write-Host "Exiting HarmonicPraxisAI v4.3.0 Console." -ForegroundColor Green
return
}
default { Write-Host "Invalid selection. Enter 1-6." -ForegroundColor Red }
}
}
}
}