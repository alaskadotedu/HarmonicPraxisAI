param(
    [string]$BaseUrl = "http://127.0.0.1:8086",
    [int]$Frames = 100,
    [int]$IntervalMs = 100
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StreamLogPath = Join-Path $BaseDir "live_5d_stream_log.csv"
if (Test-Path -LiteralPath $StreamLogPath) { Remove-Item -LiteralPath $StreamLogPath -Force }
$health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get -TimeoutSec 2
Write-Host "[STREAM CONNECTED] Server Active | Streaming $Frames frames @ ${IntervalMs}ms interval" -ForegroundColor Green
Write-Host ("{0,-6} | {1,-10} | {2,-12} | {3,-12} | {4,-12} | {5}" -f "FRAME", "TAU (s)", "PSI (rad)", "CURVATURE H", "BEND ENERGY", "AMBIENT 6D [X0, X1, X2, X3, X4, X5]") -ForegroundColor Cyan
Write-Host ("-" * 115) -ForegroundColor DarkCyan
for ($step = 1; $step -le $Frames; $step++) {
    $tau = [math]::Round($step * ($IntervalMs / 1000.0), 4)
    $psi = [math]::Round((($step * 0.2617993878) % (2.0 * [math]::PI)), 6)
    $x = [math]::Round(2.5 * [math]::Cos($psi), 5)
    $y = [math]::Round(2.5 * [math]::Sin($psi), 5)
    $z = [math]::Round(1.2 * [math]::Sin(2.0 * $psi), 5)
    $gain = [math]::Round(0.35 + (0.45 * [math]::Abs([math]::Sin($psi))), 4)
    $purity = [math]::Round(0.82 + (0.16 * [math]::Cos($psi)), 4)
    $reqBody = @{ x = $x; y = $y; z = $z; tau = $tau; psi = $psi; couplingGain = $gain; siftPurity = $purity } | ConvertTo-Json -Compress
    $res = Invoke-RestMethod -Uri "$BaseUrl/immerse5d" -Method Post -Body $reqBody -ContentType "application/json" -TimeoutSec 3
    $ambFmt = ($res.ImmersedAmbient6D | ForEach-Object { "{0:F3}" -f [double]$_ }) -join ", "
    Write-Host ("{0,-6} | {1,-10:F3} | {2,-12:F4} | {3,-12:F6} | {4,-12:F6} | [{5}]" -f $step, $tau, $psi, $res.MeanExtrinsicCurvatureH, $res.ExtrinsicBendingEnergy, $ambFmt)
    [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString("o")
        Frame = $step
        X = $x; Y = $y; Z = $z; Tau = $tau; Psi = $psi
        CouplingGain = $gain; SiftPurity = $purity
        MeanExtrinsicCurvatureH = $res.MeanExtrinsicCurvatureH
        ExtrinsicBendingEnergy = $res.ExtrinsicBendingEnergy
        IsometryMaxError = $res.IsometryMaxError
        Ambient6D = $ambFmt
    } | Export-Csv -Path $StreamLogPath -Append -NoTypeInformation
    if ($step -lt $Frames) { Start-Sleep -Milliseconds $IntervalMs }
}
Write-Host "`n[STREAM COMPLETE] Logged $Frames frames to $StreamLogPath" -ForegroundColor Green
