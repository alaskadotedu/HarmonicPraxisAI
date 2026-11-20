param(
    [string]$Profile = 'PHOTONIC_CRYSTAL_HEX',
    [int]$Rows = 4,
    [int]$Cols = 4,
    [switch]$PushGitHub,
    [string]$RepoName = 'HarmonicPraxisAI',
    [ValidateSet('private', 'public')]
    [string]$Visibility = 'private',
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $RootDir

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "[1/5] LOADING JACOBIAN & MATERIAL SYNTHESIS KERNEL..." -ForegroundColor Cyan
. (Join-Path $RootDir 'HarmonicMaterialApplicationEngine.ps1')

$matState = Invoke-MaterialSynthesis -Profile $Profile -SolveEquilibrium -Persist
Write-Host "      -> Equilibrium Solved | Bend: $($matState.JacobianCore.ObservableY.RegulatedBend) | Spectral Radius: $($matState.JacobianCore.JacobianTensor.SpectralRadius) | SHA16: $($matState.JacobianCore.StateHash16)" -ForegroundColor Gray

Write-Host "[2/5] COMPILING 4-LAYER BINARY GDSII & CIF WAFER STACK ($($Rows)x$($Cols))..." -ForegroundColor Cyan
$cadState = Export-CadGdsiiLattice -MaterialState $matState -Rows $Rows -Cols $Cols
Write-Host "      -> GDSII Compiled | Polygons: $($cadState.TotalPolygons) | Artifact: $($cadState.BinaryGdsPath)" -ForegroundColor Gray

Write-Host "[3/5] SEALING SHA-256 MERKLE WORKSPACE SNAPSHOT..." -ForegroundColor Cyan
$snapScript = Join-Path $RootDir 'Export-WorkspaceSnapshot.ps1'
$snapData = if (Test-Path -LiteralPath $snapScript) { (& $snapScript) | ConvertFrom-Json } else { $null }
if ($null -ne $snapData) {
    Write-Host "      -> Snapshot Sealed | Root SHA256: $($snapData.RootSha256.Substring(0, 16))... | Files: $($snapData.FileCount)" -ForegroundColor Gray
}

Write-Host "[4/5] SYNCHRONIZING GIT REPOSITORY & GITHUB CI WORKFLOWS..." -ForegroundColor Cyan
$pubScript = Join-Path $RootDir 'Publish-HarmonicToGitHub.ps1'
if (Test-Path -LiteralPath $pubScript) {
    if ($PushGitHub) {
        & $pubScript -RepoName $RepoName -Visibility $Visibility -PushRemote
    } else {
        & $pubScript
    }
}

$sw.Stop()
$summary = [pscustomobject]@{
    IntegrationStatus = 'ONE_SHOT_COMPLETE'
    TotalElapsedMs    = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
    ActiveProfile     = $matState.MaterialProfile
    RefractiveIndex   = $matState.ConstitutiveTensor.RefractiveIndex
    ResonanceQFactor  = $matState.ConstitutiveTensor.ResonanceQFactor
    JacobianStatus    = $matState.JacobianCore.Status
    GdsiiPolygons     = $cadState.TotalPolygons
    SnapshotRootSha16 = if ($null -ne $snapData) { $snapData.RootSha256.Substring(0, 16) } else { 'N/A' }
    GitHubPushed      = [bool]$PushGitHub
}

$summary | ConvertTo-Json -Depth 4

if (-not $Headless) {
    Write-Host "[5/5] LAUNCHING INTERACTIVE WAFER & MATERIAL STUDIO..." -ForegroundColor Green
    $srvScript = Join-Path $RootDir 'Start-HarmonicFrontendStack.ps1'
    if (Test-Path -LiteralPath $srvScript) {
        $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        Start-Process $shell -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", $srvScript
    }
}