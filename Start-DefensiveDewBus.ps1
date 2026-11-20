Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaselineJson = Join-Path $BaseDir 'dew_integrity_baseline.json'
$AuditCsv = Join-Path $BaseDir 'dew_security_telemetry.csv'
$Phi = (1.0 + [math]::Sqrt(5.0)) / 2.0

$EventBus = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()

function Get-WorkspaceBaseline([string]$Dir) {
    $files = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -notlike 'dew_*' })
    $map = [ordered]@{}
    foreach ($f in $files) {
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $map[$f.Name] = [ordered]@{ Sha256 = $h; SizeBytes = $f.Length; LastWriteUtc = $f.LastWriteTimeUtc.ToString('o') }
    }
    return $map
}

$CurrentState = Get-WorkspaceBaseline -Dir $BaseDir
if (-not (Test-Path -LiteralPath $BaselineJson)) {
    [System.IO.File]::WriteAllText($BaselineJson, ($CurrentState | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
    Write-Host "[DEW INIT] Sealed cryptographic SHA-256 baseline for $($CurrentState.Count) artifacts." -ForegroundColor Cyan
}
$SavedBaseline = [System.IO.File]::ReadAllText($BaselineJson, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$Step = 0
foreach ($fileName in $CurrentState.Keys) {
    $Step++
    $cur = $CurrentState[$fileName]
    $ref = $SavedBaseline.PSObject.Properties[$fileName]
    $status = 'VERIFIED_INTACT'
    $rawRisk = 0.05
    if ($null -eq $ref) {
        $status = 'UNTRACKED_ARTIFACT_ALERT'
        $rawRisk = 0.75
    } elseif ($ref.Value.Sha256 -ne $cur.Sha256) {
        $status = 'HASH_DRIFT_REMEDIATION_REQUIRED'
        $rawRisk = 0.98
    }
    $phiWeight = [math]::Pow($Phi, -($Step % 5))
    $threatIndex = [math]::Round([math]::Min(1.0, $rawRisk * (1.0 + (0.25 * $phiWeight))), 6)
    $EventBus.Enqueue([pscustomobject]@{
        BusSeq      = $Step
        Timestamp   = [DateTime]::UtcNow.ToString('o')
        Artifact    = $fileName
        Sha256Short = $cur.Sha256.Substring(0, 16)
        PhiWeight   = [math]::Round($phiWeight, 6)
        ThreatIndex = $threatIndex
        Posture     = $status
    })
}

$Telemetry = [System.Collections.Generic.List[object]]::new()
$item = $null
while ($EventBus.TryDequeue([ref]$item)) { $Telemetry.Add($item) }

$Telemetry | Export-Csv -LiteralPath $AuditCsv -NoTypeInformation
$Telemetry | Format-Table BusSeq, Artifact, Sha256Short, PhiWeight, ThreatIndex, Posture -AutoSize
$alerts = @($Telemetry | Where-Object { $_.Posture -ne 'VERIFIED_INTACT' }).Count
Write-Host ("[DEW COMPLETE] Bus Drained: {0} events | Integrity Alerts: {1} | Audit Log: {2}" -f $Telemetry.Count, $alerts, $AuditCsv) -ForegroundColor Green