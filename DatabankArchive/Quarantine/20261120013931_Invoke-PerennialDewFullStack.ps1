Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ArchiveDir = Join-Path $BaseDir 'DatabankArchive'
$QuarantineDir = Join-Path $ArchiveDir 'Quarantine'
foreach ($dir in @($ArchiveDir, $QuarantineDir)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
$BaselineFile = Join-Path $BaseDir 'dew_integrity_baseline.json'
$DatabankJson = Join-Path $ArchiveDir ("databank_snapshot_{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss'))
$ActionCsv    = Join-Path $BaseDir 'dew_actionable_remediation_matrix.csv'
$Phi = (1.0 + [math]::Sqrt(5.0)) / 2.0

$OsInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$FreeMemPct = [math]::Round(($OsInfo.FreePhysicalMemory / $OsInfo.TotalVisibleMemorySize) * 100.0, 2)
$ProcCount = @(Get-Process).Count

$Files = @(Get-ChildItem -LiteralPath $BaseDir -File | Where-Object { $_.Name -notlike 'dew_*' -and $_.Name -notlike 'amalgamated_*' })
if (-not (Test-Path -LiteralPath $BaselineFile)) {
    $initMap = [ordered]@{}
    foreach ($f in $Files) { $initMap[$f.Name] = @{ Sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash; Size = $f.Length } }
    [System.IO.File]::WriteAllText($BaselineFile, ($initMap | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
}
$Baseline = [System.IO.File]::ReadAllText($BaselineFile, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$N = [math]::Max(1, $Files.Count); $P = 4
$X = [double[]]::new($N * $P); $Y = [double[]]::new($N)
$MatrixRows = [System.Collections.Generic.List[object]]::new()
$QuarantinedCount = 0

for ($i = 0; $i -lt $N; $i++) {
    $f = $Files[$i]
    $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    $ref = $Baseline.PSObject.Properties[$f.Name]
    $ageSec = [math]::Max(1.0, ([DateTime]::UtcNow - $f.LastWriteTimeUtc).TotalSeconds)
    $sizeKb = [math]::Round($f.Length / 1KB, 4)
    $phiW = [math]::Pow($Phi, -($i % 6))
    $hashDrift = if ($null -eq $ref) { 0.65 } elseif ($ref.Value.Sha256 -ne $hash) { 1.0 } else { 0.0 }

    $X[$i * $P + 0] = 1.0
    $X[$i * $P + 1] = [math]::Log10($sizeKb + 1.0)
    $X[$i * $P + 2] = [math]::Log10($ageSec + 1.0)
    $X[$i * $P + 3] = $phiW
    $Y[$i] = [math]::Min(1.0, (0.08 * $phiW) + (0.85 * $hashDrift))

    $action = 'VERIFIED_NOMINAL'
    if ($hashDrift -gt 0.0) {
        $qDest = Join-Path $QuarantineDir ("{0}_{1}" -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'), $f.Name)
        Copy-Item -LiteralPath $f.FullName -Destination $qDest -Force
        $QuarantinedCount++
        $action = if ($hashDrift -ge 1.0) { 'HASH_DRIFT_SNAPSHOT_QUARANTINED' } else { 'UNTRACKED_ARTIFACT_AUDITED' }
    }
    $MatrixRows.Add([pscustomobject]@{ Seq=$i+1; Artifact=$f.Name; SizeKB=$sizeKb; Sha256Prefix=$hash.Substring(0,14); PhiWeight=[math]::Round($phiW,4); RiskScore=[math]::Round($Y[$i],4); RemediationAction=$action })
}

$XtX = [double[]]::new($P * $P); $XtY = [double[]]::new($P)
for ($r = 0; $r -lt $P; $r++) {
    for ($c = 0; $c -lt $P; $c++) {
        $acc = 0.0; for ($i = 0; $i -lt $N; $i++) { $acc += $X[$i*$P+$r] * $X[$i*$P+$c] }
        if ($r -eq $c) { $acc += 1e-4 }; $XtX[$r*$P+$c] = $acc
    }
    $ay = 0.0; for ($i = 0; $i -lt $N; $i++) { $ay += $X[$i*$P+$r] * $Y[$i] }; $XtY[$r] = $ay
}

$DatabankPayload = [ordered]@{
    TimestampUtc       = [DateTime]::UtcNow.ToString('o')
    HostTelemetry      = @{ FreeMemoryPct = $FreeMemPct; ActiveProcesses = $ProcCount; ArtifactsAudited = $N }
    RidgeNormalMatrix  = @{ XtX = $XtX; XtY = $XtY; Lambda = 1e-4 }
    QuarantinedEvents  = $QuarantinedCount
    RemediationMatrix  = $MatrixRows
}
[System.IO.File]::WriteAllText($DatabankJson, ($DatabankPayload | ConvertTo-Json -Depth 6 -Compress), [System.Text.UTF8Encoding]::new($false))
$MatrixRows | Export-Csv -LiteralPath $ActionCsv -NoTypeInformation

$TaskName = 'HarmonicPraxisDefensiveDewAudit'
$ActionObj = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -WindowStyle Hidden -File `"$PSCommandPath`""
$TriggerObj = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName $TaskName -Action $ActionObj -Trigger $TriggerObj -Description 'Perennial Defensive Integrity & Telemetry Audit' -Force | Out-Null

Write-Host "`n=== FULL-STACK DEFENSIVE REMEDIATION & DATABANK MATRIX ===" -ForegroundColor Cyan
$MatrixRows | Format-Table Seq, Artifact, SizeKB, Sha256Prefix, PhiWeight, RiskScore, RemediationAction -AutoSize
Write-Host ("[PERENNIAL COMPLETE] Host Free RAM: {0}% | Procs: {1} | Audited: {2} | Quarantined Snapshots: {3}" -f $FreeMemPct, $ProcCount, $N, $QuarantinedCount) -ForegroundColor Green
Write-Host ("[TASK REGISTERED] Scheduled Task '{0}' active (hourly) | Databank: {1}" -f $TaskName, $DatabankJson) -ForegroundColor Yellow