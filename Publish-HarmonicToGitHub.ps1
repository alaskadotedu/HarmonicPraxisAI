param(
    [string]$RepoName = "HarmonicPraxisAI",
    [ValidateSet("private", "public")]
    [string]$Visibility = "private",
    [switch]$PushRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $RootDir

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[INSTALLING GIT] Fetching Git via winget..." -ForegroundColor Cyan
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

$ignoreLines = @("*.db-wal", "*.db-shm", "HyperV_VM/", "*.vhdx", "*.iso", "Snapshots/*.zip")
[System.IO.File]::WriteAllLines((Join-Path $RootDir ".gitignore"), $ignoreLines, (New-Object System.Text.UTF8Encoding($false)))

if (-not (Test-Path (Join-Path $RootDir ".git"))) {
    git init -b main
}

git config user.name "Harmonic Praxis Architect"
git config user.email "architect@harmonicpraxis.local"

git add .
$status = git status --porcelain
if (-not [string]::IsNullOrWhiteSpace($status)) {
    git commit -m "chore(pipeline): ratify Harmonic Praxis AI core, material profiles & GitHub CI"
}

if ($PushRemote) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "[INSTALLING GITHUB CLI] Fetching gh via winget..." -ForegroundColor Cyan
        winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    $authCheck = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[AUTH REQUIRED] Launching GitHub CLI login..." -ForegroundColor Yellow
        gh auth login --web --git-protocol https
    }

    $hasOrigin = (git remote) -contains "origin"
    if (-not $hasOrigin) {
        gh repo create $RepoName --$Visibility --source=. --remote=origin --push
    } else {
        git push -u origin main
    }
    Write-Host "[GITHUB REMOTE SYNCED] Repository pushed & GitHub Actions CI triggered." -ForegroundColor Green
} else {
    Write-Host "[LOCAL GIT PIPELINE READY] Run with -PushRemote to create & push to GitHub." -ForegroundColor Green
}