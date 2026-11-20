Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Join-Path (Get-Location).Path 'HarmonicPraxisAI'
Import-Module (Join-Path $BaseDir 'HarmonicPraxisAI.psd1') -Force
Write-Host "PHASE 1: Synthesizing 5,000-Sample Physics & FDIR Manifold" -ForegroundColor Cyan
$Dataset = New-HarmonicDataset -Samples 5000 -Seed 2026
Write-Host "PHASE 2: Autonomous Hyperparameter Search (6 Trials)" -ForegroundColor Cyan
$BestParams = Invoke-HarmonicHyperparameterTuning -Dataset $Dataset -Trials 6 -EpochsPerTrial 10 -Seed 2026
if ($BestParams.HiddenDim -lt 48) { $BestParams.HiddenDim = 48 }
$BestParams | Format-Table -AutoSize
Write-Host "PHASE 3: Two-Stage High-Precision Training & LR Annealing" -ForegroundColor Cyan
$Model = Train-HarmonicSurrogateModel -Dataset $Dataset -Hyperparameters $BestParams -Epochs 35 -Seed 2026
Write-Host "PHASE 4: Hold-Out Telemetry RMSE Precision Audit" -ForegroundColor Cyan
$n = $Dataset.Count
$splitIdx = [int][math]::Floor($n * 0.85)
$testX = $Dataset.Features[$splitIdx..($n - 1)]
$testY = $Dataset.Targets[$splitIdx..($n - 1)]
$sqErr = [double[]]::new(5)
for ($i = 0; $i -lt $testX.Count; $i++) {
$xVec = [double[]]$testX.GetValue($i)
$yTrue = [double[]]$testY.GetValue($i)
$pred = Invoke-HarmonicSurrogateInference -Model $Model -FeatureVector $xVec
$predsArr = @($pred.PredictedPhaseError, $pred.PredictedCouplingGain, $pred.PredictedFrequencyThz, $pred.PredictedFusedEstimate, $pred.PredictedWatermarkWt)
for ($k = 0; $k -lt 5; $k++) {
$diff = $predsArr[$k] - $yTrue.GetValue($k)
$sqErr[$k] += ($diff * $diff)
}
}
$tc = $testX.Count
[pscustomobject]@{
HoldOutSamples     = $tc
PhaseError_RMSE    = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
CouplingGain_RMSE  = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
FrequencyThz_RMSE  = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
FusedEstimate_RMSE = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
WatermarkWt_RMSE   = [math]::Round([math]::Sqrt($sqErr / $tc), 5)
} | Format-List
$ArtifactPath = Join-Path $BaseDir 'harmonic_surrogate_v4_2.json'
Export-HarmonicModelArtifact -Model $Model -Path $ArtifactPath
Write-Host "PHASE 5: Launching REST Microservice & End-to-End Verification" -ForegroundColor Cyan
$ManifestPath = Join-Path $BaseDir 'HarmonicPraxisAI.psd1'
$AuditLogPath = Join-Path $BaseDir 'telemetry_drift_audit.csv'
$ServerJob = Start-Job -ScriptBlock {
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
if ($Method -eq 'GET' -and $Path -eq '/health') {
$ResponseObj = [ordered]@{ Status = 'ONLINE'; Version = '4.2.2'; HiddenDim = $SrvModel.HiddenDim; TotalRequests = $TotalRequests; AutonomousCount = $AutonomousCount; DriftAlerts = $DriftAlerts }
}
elseif ($Method -eq 'GET' -and $Path -eq '/simulate') {
$sample = [HarmonicPhysicsKernel]::SimulateSample($Rng)
$xVec = [double[]]$sample.X; $yTrue = [double[]]$sample.Y
$pred = Invoke-HarmonicSurrogateInference -Model $SrvModel -FeatureVector $xVec
$drift = [math]::Abs($pred.PredictedWatermarkWt - $yTrue.GetValue(4))
if ($drift -gt 0.08) { $DriftAlerts++ }
if ($pred.AutonomousReady) { $AutonomousCount++ }
$TotalRequests++
[pscustomobject]@{ TimestampUtc = [DateTime]::UtcNow.ToString('o'); TrueWatermarkWt = [math]::Round($yTrue.GetValue(4), 6); PredictedWatermarkWt = $pred.PredictedWatermarkWt; WatermarkDrift = [math]::Round($drift, 6); AutonomousReady = $pred.AutonomousReady } | Export-Csv -Path $LPath -Append -NoTypeInformation
$ResponseObj = [ordered]@{ GroundTruthWatermark = [math]::Round($yTrue.GetValue(4), 6); SurrogatePrediction = $pred; WatermarkDrift = [math]::Round($drift, 6) }
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
$Bytes = [System.Text.Encoding]::UTF8.GetBytes(($ResponseObj | ConvertTo-Json -Depth 6))
$Res.StatusCode = $StatusCode; $Res.ContentType = 'application/json'; $Res.ContentLength64 = $Bytes.Length
$Res.OutputStream.Write($Bytes, 0, $Bytes.Length); $Res.OutputStream.Close()
}
}
finally {
$Listener.Stop(); $Listener.Close()
}
} -ArgumentList $ManifestPath, $ArtifactPath, $AuditLogPath
for ($w = 0; $w -lt 30; $w++) {
Start-Sleep -Milliseconds 400
try {
$null = Invoke-RestMethod -Uri "http://localhost:8085/health" -Method Get -TimeoutSec 1
break
} catch {}
}
Invoke-RestMethod -Uri "http://localhost:8085/health" -Method Get | Format-List
(Invoke-RestMethod -Uri "http://localhost:8085/simulate" -Method Get).SurrogatePrediction | Format-List
$body = @{ features = @(0.5, 120.0, -45.0, 10.0, 12.0, -5.0, 3.0, 0.001, -0.002, 0.005, 3, 4, 98.2, 101.4, 99.8, 97.5, 0.92, 0.88, 0.45, 0.95, 0.82) } | ConvertTo-Json
(Invoke-RestMethod -Uri "http://localhost:8085/predict" -Method Post -Body $body -ContentType "application/json").Prediction | Format-List
Invoke-RestMethod -Uri "http://localhost:8085/stop" -Method Post | Format-List
Receive-Job -Job $ServerJob -Wait -AutoRemoveJob
Write-Host "[COMPLETE] HarmonicPraxisAI v4.2.2 One-Shot Suite Executed Successfully." -ForegroundColor Green