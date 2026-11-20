param([int]$Port = 8085)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "[BOOT] Loading modules from: $BaseDir" -ForegroundColor Cyan

Import-Module (Join-Path $BaseDir 'HarmonicPraxisAI.psd1') -Force
Import-Module (Join-Path $BaseDir 'Harmonic5DImmersion.psd1') -Force

$ArtifactPath = Join-Path $BaseDir 'harmonic_surrogate_v4_3.json'
if (-not (Test-Path -LiteralPath $ArtifactPath)) {
    Write-Host "[BOOT] Training initial surrogate artifact..." -ForegroundColor Yellow
    $ds = New-HarmonicDataset -Samples 1200 -Seed 2026
    $hp = Invoke-HarmonicHyperparameterTuning -Dataset $ds -Trials 3 -EpochsPerTrial 5 -Seed 2026
    if ($hp.HiddenDim -lt 48) { $hp.HiddenDim = 48 }
    $m = Train-HarmonicSurrogateModel -Dataset $ds -Hyperparameters $hp -Epochs 12 -Seed 2026
    Export-HarmonicModelArtifact -Model $m -Path $ArtifactPath
}

$AuditLogPath = Join-Path $BaseDir 'telemetry_drift_audit.csv'
$SrvModel = Import-HarmonicModelArtifact -Path $ArtifactPath

$TcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$TcpListener.Start()

Write-Host "[ONLINE] User-Mode HTTP Server active on http://127.0.0.1:$Port/ (PID: $PID)" -ForegroundColor Green

$Rng = [System.Random]::new()
$TotalRequests = 0
$AutonomousCount = 0
$ImmersionCalls = 0
$DriftAlerts = 0
$KeepRunning = $true

try {
    while ($KeepRunning) {
        $Client = $TcpListener.AcceptTcpClient()
        try {
            $Stream = $Client.GetStream()
            $Stream.ReadTimeout = 5000
            $Buffer = [byte[]]::new(65536)
            $BytesRead = $Stream.Read($Buffer, 0, $Buffer.Length)
            if ($BytesRead -le 0) { $Client.Close(); continue }

            $RawRequest = [System.Text.Encoding]::UTF8.GetString($Buffer, 0, $BytesRead)
            $HeaderBodySplit = $RawRequest -split "`r`n`r`n", 2
            $HeaderLines = $HeaderBodySplit[0] -split "`r`n"
            $Body = if ($HeaderBodySplit.Count -gt 1) { $HeaderBodySplit[1] } else { "" }

            $ContentLength = 0
            foreach ($hLine in $HeaderLines) {
                if ($hLine -match '^Content-Length:\s*(\d+)') {
                    $ContentLength = [int]$Matches[1]
                }
            }
            while ([System.Text.Encoding]::UTF8.GetByteCount($Body) -lt $ContentLength) {
                $moreBytes = $Stream.Read($Buffer, 0, $Buffer.Length)
                if ($moreBytes -le 0) { break }
                $Body += [System.Text.Encoding]::UTF8.GetString($Buffer, 0, $moreBytes)
            }

            $RequestLineParts = $HeaderLines[0] -split ' '
            $Method = $RequestLineParts[0].ToUpperInvariant()
            $Path = ($RequestLineParts[1] -split '\?')[0].ToLowerInvariant()

            $StatusCode = 200
            $StatusText = 'OK'
            $ResponseObj = $null

            try {
                if ($Method -eq 'GET' -and $Path -eq '/health') {
                    $ResponseObj = [ordered]@{
                        Status          = 'ONLINE'
                        Version         = '4.7.0-USERMODE-TCP'
                        Port            = $Port
                        Pid             = $PID
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

                    $immersion = Invoke-Universal5DImmersionStep -X ($xVec.GetValue(1) * 0.01) -Y ($xVec.GetValue(2) * 0.01) -Z ($xVec.GetValue(3) * 0.01) -Tau 0.002 -Psi $xVec.GetValue(0) -CouplingGain $pred.PredictedCouplingGain -SiftPurity $sample.Sift.SiftPurity

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
                    } | Export-Csv -Path $AuditLogPath -Append -NoTypeInformation

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
                    $Payload = $Body | ConvertFrom-Json
                    $pred = Invoke-HarmonicSurrogateInference -Model $SrvModel -FeatureVector ([double[]]$Payload.features)
                    if ($pred.AutonomousReady) { $AutonomousCount++ }
                    $TotalRequests++

                    $ResponseObj = [ordered]@{
                        Prediction   = $pred
                        TimestampUtc = [DateTime]::UtcNow.ToString('o')
                    }
                }
                elseif ($Method -eq 'POST' -and $Path -eq '/immerse5d') {
                    $Payload = $Body | ConvertFrom-Json
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

                    $metricDiag = @($gMat["0,0"], $gMat["1,1"], $gMat["2,2"], $gMat["3,3"], $gMat["4,4"])
                    $secondFormRows = for ($r = 0; $r -lt 5; $r++) {
                        ,@($iiMat["$r,0"], $iiMat["$r,1"], $iiMat["$r,2"], $iiMat["$r,3"], $iiMat["$r,4"])
                    }
                    $jacobianRows = for ($r = 0; $r -lt 6; $r++) {
                        ,@([math]::Round($jMat["$r,0"], 8), [math]::Round($jMat["$r,1"], 8), [math]::Round($jMat["$r,2"], 8), [math]::Round($jMat["$r,3"], 8), [math]::Round($jMat["$r,4"], 8))
                    }

                    $ResponseObj = [ordered]@{
                        Intrinsic5D             = @($xVal, $yVal, $zVal, $tauVal, $psiVal)
                        ImmersedAmbient6D       = @($imm.ImmersedAmbient6D["0,0"], $imm.ImmersedAmbient6D["0,1"], $imm.ImmersedAmbient6D["0,2"], $imm.ImmersedAmbient6D["0,3"], $imm.ImmersedAmbient6D["0,4"], $imm.ImmersedAmbient6D["0,5"])
                        AmbientNormal6D         = @($imm.AmbientNormal6D["0,0"], $imm.AmbientNormal6D["0,1"], $imm.AmbientNormal6D["0,2"], $imm.AmbientNormal6D["0,3"], $imm.AmbientNormal6D["0,4"], $imm.AmbientNormal6D["0,5"])
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
$ResponseObj = [ordered]@{ Status = 'SHUTTING_DOWN' }
$KeepRunning = $false
}
else {
$StatusCode = 404
$StatusText = 'Not Found'
$ResponseObj = [ordered]@{ Error = 'Endpoint not found.' }
}
}
catch {
$StatusCode = 400
$StatusText = 'Bad Request'
$ResponseObj = [ordered]@{ Error = $_.Exception.Message }
}
$JsonBody = $ResponseObj | ConvertTo-Json -Depth 8 -Compress
$BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
$HttpHeader = "HTTP/1.1 $StatusCode $StatusTextrnContent-Type: application/json; charset=utf-8rnContent-Length: $($BodyBytes.Length)rnConnection: closernrn"
$HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($HttpHeader)
$Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
$Stream.Write($BodyBytes, 0, $BodyBytes.Length)
$Stream.Flush()
}
finally {
$Client.Close()
}
}
}
finally {
$TcpListener.Stop()
Write-Host "[STOPPED] User-Mode HTTP Server closed cleanly." -ForegroundColor Yellow
}