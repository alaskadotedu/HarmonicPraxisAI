param([int]$Frames = 60, [int]$DelayMs = 100)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogCsv = Join-Path $BaseDir "live_remediation_stream.csv"
if (Test-Path -LiteralPath $LogCsv) { Remove-Item -LiteralPath $LogCsv -Force }
$h = Invoke-RestMethod -Uri "http://localhost:8090/health" -Method Get -TimeoutSec 3
Write-Host ("[CONNECTED] Recursive Solver v{0} | Streaming {1} frames @ {2}ms" -f $h.Version, $Frames, $DelayMs) -ForegroundColor Green
Write-Host ("{0,-6} | {1,-8} | {2,-8} | {3,-11} | {4,-11} | {5,-10} | {6}" -f "FRAME","PSI","PURITY","FREQ (THz)","REG BEND","WATERMARK","BREACH") -ForegroundColor Cyan
$List = [System.Collections.Generic.List[object]]::new()
for ($i = 1; $i -le $Frames; $i++) {
    $psi = [math]::Round((($i * 0.21) % (2.0 * [math]::PI)) - [math]::PI, 4)
    $gain = [math]::Round(0.40 + 0.55 * [math]::Abs([math]::Sin($psi)), 4)
    $purity = [math]::Round(0.45 + 0.50 * [math]::Abs([math]::Cos($psi * 0.5)), 4)
    $s0 = [math]::Round(4.2 * [math]::Cos($psi), 4); $s1 = [math]::Round(-3.9 * [math]::Sin($psi), 4)
    $body = @{ psi=$psi; gain=$gain; purity=$purity; rawScore=0.75; s0=$s0; s1=$s1 } | ConvertTo-Json -Compress
    $res = Invoke-RestMethod -Uri "http://localhost:8090/remediate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3
    Write-Host ("{0,-6} | {1,-8:F3} | {2,-8:F3} | {3,-11:F4} | {4,-11:F4} | {5,-10:F4} | {6}" -f $i, $psi, $purity, $res.FrequencyThz, $res.RegulatedBend, $res.WatermarkWt, $res.BreachDetected)
    $List.Add([pscustomobject]@{ Frame=$i; Psi=$psi; Gain=$gain; Purity=$purity; FrequencyThz=$res.FrequencyThz; RegulatedBend=$res.RegulatedBend; WatermarkWt=$res.WatermarkWt; BreachDetected=$res.BreachDetected })
    Start-Sleep -Milliseconds $DelayMs
}
$List | Export-Csv -LiteralPath $LogCsv -NoTypeInformation
$endH = Invoke-RestMethod -Uri "http://localhost:8090/health" -Method Get -TimeoutSec 3
Write-Host ("`n[STREAM COMPLETE] Logged {0} frames to {1} | Total Server Breaches Remediated: {2}" -f $Frames, $LogCsv, $endH.BreachesRemediated) -ForegroundColor Green
