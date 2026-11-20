param(
    [string]$TaskName = "HarmonicPraxis-EndToEnd-Pipeline",
    [int]$IntervalMinutes = 60,
    [switch]$Elevate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$shellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }

if ($Elevate -and -not $isAdmin) {
    Start-Process $shellExe -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TaskName `"$TaskName`" -IntervalMinutes $IntervalMinutes"
    exit
}

$runnerScript = Join-Path $RootDir "Invoke-AutonomousPipelineCycle.ps1"
$runnerLines = @(
    "Set-StrictMode -Version Latest"
    "`$ErrorActionPreference = 'Stop'"
    "`$Dir = if (`$PSScriptRoot) { `$PSScriptRoot } else { (Get-Location).Path }"
    "Set-Location `$Dir"
    "& (Join-Path `$Dir 'Invoke-EdlTokenizedTransit.ps1') | Out-Null"
    "& (Join-Path `$Dir 'Invoke-HarmonicOneShot.ps1') -Headless"
)
[System.IO.File]::WriteAllLines($runnerScript, $runnerLines, (New-Object System.Text.UTF8Encoding($false)))

$action   = New-ScheduledTaskAction -Execute $shellExe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerScript`"" -WorkingDirectory $RootDir
$repTrig  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

if ($isAdmin) {
    $logonTrig = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logonTrig, $repTrig) -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "[ADMIN TASK REGISTERED] '$TaskName' active with Highest privileges (AtLogOn + every $IntervalMinutes min)." -ForegroundColor Green
} else {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $repTrig -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "[USER TASK REGISTERED] '$TaskName' active under $env:USERNAME (every $IntervalMinutes min). Pass -Elevate for Admin/AtLogOn." -ForegroundColor Green
}

Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State, @{N='RunLevel';E={$_.Principal.RunLevel}}