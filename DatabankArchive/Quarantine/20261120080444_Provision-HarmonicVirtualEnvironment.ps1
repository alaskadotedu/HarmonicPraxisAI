Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $BaseDir

$hasDocker = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
$hasHyperV = $null -ne (Get-Command Get-VM -ErrorAction SilentlyContinue)
$isAdmin   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$dockerReady = $false
if ($hasDocker) {
    try {
        & docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $dockerReady = $true }
    } catch { $dockerReady = $false }
}

if ($dockerReady) {
    Write-Host "[PROVISIONING] Docker Engine active. Building & deploying container..." -ForegroundColor Cyan
    & docker compose up -d --build
    Start-Sleep -Seconds 2
    Start-Process "http://localhost:8110/"
}
elseif ($hasHyperV -and $isAdmin) {
    Write-Host "[PROVISIONING] Provisioning Hyper-V VM 'HarmonicPraxis-VM'..." -ForegroundColor Cyan
    $vmName   = "HarmonicPraxis-VM"
    $vmRoot   = Join-Path $BaseDir "HyperV_VM"
    $vhdxPath = Join-Path $vmRoot "$vmName.vhdx"
    New-Item -ItemType Directory -Path $vmRoot -Force | Out-Null

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        New-VHD -Path $vhdxPath -SizeBytes 20GB -Dynamic | Out-Null
        New-VM -Name $vmName -MemoryStartupBytes 4GB -Generation 2 -VHDPath $vhdxPath -Path $vmRoot | Out-Null
        Set-VMProcessor -VMName $vmName -Count 2
        Set-VMFirmware -VMName $vmName -EnableSecureBoot Off
        $switch = Get-VMSwitch | Select-Object -First 1
        if ($null -ne $switch) { Connect-VMNetworkAdapter -VMName $vmName -SwitchName $switch.Name }
    }
    Write-Host "[HYPER-V READY] VM '$vmName' provisioned at $vmRoot" -ForegroundColor Green
}
else {
    Write-Host "[PROVISIONING] Docker daemon offline & Hyper-V requires Admin. Launching native host stack..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $BaseDir "Start-HarmonicFrontendStack.ps1")
}
