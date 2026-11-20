Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $Dir
& (Join-Path $Dir 'Invoke-EdlTokenizedTransit.ps1') | Out-Null
& (Join-Path $Dir 'Invoke-HarmonicOneShot.ps1') -Headless
