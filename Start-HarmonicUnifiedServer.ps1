param(
    [ValidateSet('Start', 'Stop', 'VerifyAll')]
    [string]$Mode = 'VerifyAll',
    [int]$Port = 8085
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = Join-Path (Get-Location).Path 'HarmonicPraxisAI'
$AiManifestPath = Join-Path $BaseDir 'HarmonicPraxisAI.psd1'
$ImmersionManifestPath = Join-Path $BaseDir 'Harmonic5DImmersion.psd1'
$ArtifactPath = Join-Path $BaseDir 'harmonic_surrogate_v4_3.json'
$AuditLogPath = Join-Path $BaseDir 'telemetry_drift_audit.csv'

function Start-UnifiedServerDaemon {
    try {
        $check = Invoke-RestMethod -Uri "http://localhost:$Port/health" -Method Get -TimeoutSec 1
        Write-Host "[INFO] Unified Server already ONLINE on port $Port (Requests: $($check.TotalRequests))." -ForegroundColor Yellow
        return
    } catch {}

    if (-not (Test-Path -LiteralPath $ArtifactPath)) {
        Import-Module $AiManifestPath -Force
        $ds = New-HarmonicDataset -Samples 2500 -Seed 2026
        $hp = Invoke-HarmonicHyperparameterTuning -Dataset $ds -Trials 4 -EpochsPerTrial 8 -Seed 2026
        if ($hp.HiddenDim -lt 48) { $hp.HiddenDim = 48 }
        $m = Train-HarmonicSurrogateModel -Dataset $ds -Hyperparameters $hp -Epochs 20 -Seed 2026
        Export-HarmonicModelArtifact -Model $m -Path $ArtifactPath
    }

    $null = Start-Job -Name 'HarmonicUnifiedDaemon' -ScriptBlock {
        param($AiMPath, $ImmMPath, $APath, $LPath, $ListenPort)
        Import-Module $AiMPath -Force
        Import-Module $ImmMPath -Force

        $SrvModel = Import-HarmonicModelArtifact -Path $APath
        $Listener = [System.Net.HttpListener]::new()
        $Listener.Prefixes.Add("http://localhost:$ListenPort/")
        $Listener.Start()

        $Rng = [System.Random]::new()
        $TotalRequests = 0
        $AutonomousCount = 0
        $ImmersionCalls = 0
        $DriftAlerts = 0

        try {
            while ($Listener.IsListening) {
                $Context = $Listener.GetContext()
                $Req = $Context.Request
                $Res = $Context.Response
                $Path = $Req.Url.AbsolutePath.ToLowerInvariant()
                $Method = $Req.HttpMethod.ToUpperInvariant()
                $StatusCode = 200
                $ResponseObj = $null

                try {
                    if ($Method -eq 'GET' -and $Path -eq '/health') {
                        $ResponseObj = [ordered]@{
                            Status          = 'ONLINE'
                            Version         = '4.6.0-UNIFIED'
                            Endpoints       = @('GET /health', 'GET /simulate', 'POST /predict', 'POST /immerse5d', 'POST /stop')
                            TotalRequests   = $TotalRequests
                            AutonomousCount = $AutonomousCount
                            ImmersionCalls  = $ImmersionCalls
                            DriftAlerts     = $DriftAlerts
                            TimestampUtc    = [DateTime]::UtcNow.ToString('o')
                        }
                    }
                    elseif ($Method -eq 'GET' -and $Path -eq '/simulate') {
                        $sample = [HarmonicPhysicsKernel]::SimulateSample($Rng)
                        $xVec = [double[]]$sample.X
                        $yTrue = [double[]]$sample.Y
                        $pred = Invoke-HarmonicSurrogateInference -Model $SrvModel -FeatureVector $xVec

                        $theta = $xVec.GetValue(0)
                        $ex = $xVec.GetValue(1)
                        $ey = $xVec.GetValue(2)
                        $ez = $xVec.GetValue(3)
                        $immersion = Invoke-Universal5DImmersionStep -X ($ex * 0.01) -Y ($ey * 0.01) -Z ($ez * 0.01) -Tau 0.002 -Psi $theta -CouplingGain $pred.PredictedCouplingGain -SiftPurity $sample.Sift.SiftPurity

                        $drift = [math]::Abs($pred.PredictedWatermarkWt - $yTrue.GetValue(4))
                        if ($drift -gt 0.08) { $DriftAlerts++ }
                        if ($pred.AutonomousReady) { $AutonomousCount++ }
                        $TotalRequests++

                        [pscustomobject]@{
                            TimestampUtc            = [DateTime]::UtcNow.ToString('o')
                            SiftPurity              = $sample.Sift.SiftPurity
                            MeanExtrinsicCurvatureH = $immersion.MeanExtrinsicCurvatureH
                            TrueWatermarkWt         = [math]::Round($yTrue.GetValue(4), 6)
                            PredictedWatermarkWt    = $pred.PredictedWatermarkWt
                            WatermarkDrift          = [math]::Round($drift, 6)
                            AutonomousReady         = $pred.AutonomousReady
                        } | Export-Csv -Path $LPath -Append -NoTypeInformation

                        $ResponseObj = [ordered]@{
                            SiftTelemetry       = $sample.Sift
                            SurrogatePrediction = $pred
                            Immersion5DTo6D     = [ordered]@{
                                Intrinsic5D             = $immersion.Intrinsic5DFormatted
                                Ambient6D               = $immersion.Immersed6DFormatted
                                Normal6D                = $immersion.Normal6DFormatted
                                MeanExtrinsicCurvatureH = $immersion.MeanExtrinsicCurvatureH
                                ExtrinsicBendingEnergy  = $immersion.ExtrinsicBendingEnergy
                                IsometryMaxError        = $immersion.IsometryMaxError
                            }
                            WatermarkDrift      = [math]::Round($drift, 6)
                        }
                    }
                    elseif ($Method -eq 'POST' -and $Path -eq '/predict') {
                        $Reader = [System.IO.StreamReader]::new($Req.InputStream, $Req.ContentEncoding)
                        $Payload = $Reader.ReadToEnd() | ConvertFrom-Json
                        $Reader.Close()

                        $pred = Invoke-HarmonicSurrogateInference -Model $SrvModel -FeatureVector ([double[]]$Payload.features)
                        if ($pred.AutonomousReady) { $AutonomousCount++ }
                        $TotalRequests++

                        $ResponseObj = [ordered]@{
                            Prediction   = $pred
                            TimestampUtc = [DateTime]::UtcNow.ToString('o')
                        }
                    }
                    elseif ($Method -eq 'POST' -and $Path -eq '/immerse5d') {
                        $Reader = [System.IO.StreamReader]::new($Req.InputStream, $Req.ContentEncoding)
                        $Payload = $Reader.ReadToEnd() | ConvertFrom-Json
                        $Reader.Close()

                        $xVal = [double]$Payload.x
                        $yVal = [double]$Payload.y
                        $zVal = [double]$Payload.z
                        $tauVal = [double]$Payload.tau
                        $psiVal = [double]$Payload.psi
                        $gainVal = if ($null -ne $Payload.couplingGain) { [double]$Payload.couplingGain } else { 0.45 }
                        $purityVal = if ($null -ne $Payload.siftPurity) { [double]$Payload.siftPurity } else { 0.92 }

                        $imm = Invoke-Universal5DImmersionStep -X $xVal -Y $yVal -Z $zVal -Tau $tauVal -Psi $psiVal -CouplingGain $gainVal -SiftPurity $purityVal
                        $ImmersionCalls++
                        $TotalRequests++

                        $gMat = $imm.InducedMetric5x5
                        $iiMat = $imm.ExtrinsicSecondForm5x5
                        $jMat = $imm.ImmersionJacobian6x5

                        $metricDiag = @(
                            $gMat["0,0"], $gMat["1,1"], $gMat["2,2"], $gMat["3,3"], $gMat["4,4"]
                        )

                        $secondFormRows = for ($r = 0; $r -lt 5; $r++) {
                            ,@($iiMat["$r,0"], $iiMat["$r,1"], $iiMat["$r,2"], $iiMat["$r,3"], $iiMat["$r,4"])
                        }

                        $jacobianRows = for ($r = 0; $r -lt 6; $r++) {
                            ,@([math]::Round($jMat["$r,0"], 8), [math]::Round($jMat["$r,1"], 8), [math]::Round($jMat["$r,2"], 8), [math]::Round($jMat["$r,3"], 8), [math]::Round($jMat["$r,4"], 8))
                        }

                        $ResponseObj = [ordered]@{
                            Intrinsic5D             = @($xVal, $yVal, $zVal, $tauVal, $psiVal)
                            ImmersedAmbient6D       = @(
                                $imm.ImmersedAmbient6D["0,0"],
                                $imm.ImmersedAmbient6D["0,1"],
                                $imm.ImmersedAmbient6D["0,2"],
                                $imm.ImmersedAmbient6D["0,3"],
                                $imm.ImmersedAmbient6D["0,4"],
                                $imm.ImmersedAmbient6D["0,5"]
                            )
                            AmbientNormal6D         = @(
                                $imm.AmbientNormal6D["0,0"],
                                $imm.AmbientNormal6D["0,1"],
                                $imm.AmbientNormal6D["0,2"],
                                $imm.AmbientNormal6D["0,3"],
                                $imm.AmbientNormal6D["0,4"],
                                $imm.AmbientNormal6D["0,5"]
                            )
                            MeanExtrinsicCurvatureH = $imm.MeanExtrinsicCurvatureH
                            ExtrinsicBendingEnergy  = $imm.ExtrinsicBendingEnergy
IsometryMaxError        = $imm.IsometryMaxError
InducedMetricDiagonal   = $metricDiag
ExtrinsicSecondForm5x5  = $secondFormRows
ImmersionJacobian6x5    = $jacobianRows
TimestampUtc            = [DateTime]::UtcNow.ToString('o')
}
}
elseif ($Method -eq 'POST' -and $Path -eq '/stop') {
$Bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ Status = 'SHUTTING_DOWN' } | ConvertTo-Json))
$Res.StatusCode = 200
$Res.ContentType = 'application/json'
$Res.ContentLength64 = $Bytes.Length
$Res.OutputStream.Write($Bytes, 0, $Bytes.Length)
$Res.OutputStream.Close()
break
}
else {
$StatusCode = 404
$ResponseObj = [ordered]@{ Error = 'Endpoint not found. Available: GET /health, GET /simulate, POST /predict, POST /immerse5d, POST /stop' }
}
}
catch {
$StatusCode = 400
$ResponseObj = [ordered]@{ Error = $_.Exception.Message }
}
$Bytes = [System.Text.Encoding]::UTF8.GetBytes(($ResponseObj | ConvertTo-Json -Depth 8))
$Res.StatusCode = $StatusCode
$Res.ContentType = 'application/json'
$Res.ContentLength64 = $Bytes.Length
$Res.OutputStream.Write($Bytes, 0, $Bytes.Length)
$Res.OutputStream.Close()
}
}
finally {
$Listener.Stop()
$Listener.Close()
}
} -ArgumentList $AiManifestPath, $ImmersionManifestPath, $ArtifactPath, $AuditLogPath, $Port
for ($w = 0; $w -lt 30; $w++) {
Start-Sleep -Milliseconds 300
try {
$null = Invoke-RestMethod -Uri "http://localhost:$Port/health" -Method Get -TimeoutSec 1
Write-Host "[ACTIVE] Unified HarmonicPraxisAI v4.6.0 Server listening on http://localhost:$Port/" -ForegroundColor Green
return
} catch {}
}
throw "Timed out waiting for Unified HTTP Server on port $Port."
}
function Stop-UnifiedServerDaemon {
try {
$null = Invoke-RestMethod -Uri "http://localhost:$Port/stop" -Method Post -TimeoutSec 2
} catch {}
Get-Job -Name 'HarmonicUnifiedDaemon' -ErrorAction SilentlyContinue | Remove-Job -Force
Write-Host "[STOPPED] Unified HarmonicPraxisAI Server terminated." -ForegroundColor Yellow
}
switch ($Mode) {
'Start' {
Start-UnifiedServerDaemon
}
'Stop' {
Stop-UnifiedServerDaemon
}
'VerifyAll' {
Start-UnifiedServerDaemon
Write-Host "`n=== 1. POST /immerse5d (5D -> 6D UNIFORM IMMERSION ENDPOINT) ===" -ForegroundColor Cyan
$immersePayload = @{
x            = 1.25
y            = -0.80
z            = 2.40
tau          = 0.002
psi          = 1.0471975512
couplingGain = 0.68
siftPurity   = 0.91
} | ConvertTo-Json
$immerseRes = Invoke-RestMethod -Uri "http://localhost:$Port/immerse5d" -Method Post -Body $immersePayload -ContentType "application/json"
$immerseRes | Select-Object MeanExtrinsicCurvatureH, ExtrinsicBendingEnergy, IsometryMaxError, InducedMetricDiagonal, ImmersedAmbient6D, AmbientNormal6D | Format-List
Write-Host "=== 2. GET /simulate (COUPLED SIFT + NEURAL + 5D IMMERSION TELEMETRY) ===" -ForegroundColor Cyan
$simRes = Invoke-RestMethod -Uri "http://localhost:$Port/simulate" -Method Get
$simRes.Immersion5DTo6D | Format-List
Write-Host "=== 3. GET /health (UNIFIED SERVICE TELEMETRY) ===" -ForegroundColor Cyan
Invoke-RestMethod -Uri "http://localhost:$Port/health" -Method Get | Format-List
Stop-UnifiedServerDaemon
}
}