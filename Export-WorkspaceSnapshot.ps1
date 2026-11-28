[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'Snapshots')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
$output = [IO.Path]::GetFullPath($OutputDirectory)
$snapshotName = 'workspace-snapshot-{0}.zip' -f (Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ')
$archivePath = Join-Path $output $snapshotName
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('harmonic-workspace-' + [guid]::NewGuid().ToString('N'))
$staging = Join-Path $tempRoot 'workspace'

New-Item -ItemType Directory -Path $output, $staging -Force | Out-Null
try {
    $inventory = [System.Collections.Generic.List[object]]::new()
    $excludedPath = '(?i)(^|/)(\.git|Snapshots|node_modules|\.venv|venv|__pycache__)(/|$)'
    $excludedName = '(?i)(^|/)(\.env[^/]*|harmonic_api_key\.txt|[^/]*(secret|credential|token)[^/]*|[^/]*\.dpapi)$'
    $excludedExtension = '(?i)\.(db|db-wal|db-shm|zip)$'

    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')) -replace '\\', '/'
        if ($relative -match $excludedPath -or $relative -match $excludedName -or $relative -match $excludedExtension) { continue }

        $destination = Join-Path $staging ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $inventory.Add([pscustomobject]@{
            path = $relative
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            size_bytes = $file.Length
        })
    }

    $manifest = [ordered]@{
        format = 'harmonic-workspace-snapshot-v1'
        generated_utc = (Get-Date -AsUTC).ToString('o')
        files = @($inventory | Sort-Object path)
    }
    $manifestPath = Join-Path $staging 'workspace-sha256-manifest.json'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8)

    Add-Type -AssemblyName System.IO.Compression.ZipFile
    $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $staging -File -Recurse -Force) {
            $entryName = $file.FullName.Substring($staging.Length).TrimStart([char[]]@('\', '/')) -replace '\\', '/'
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }

    Write-Host ("Workspace snapshot created: {0} ({1} inventoried files)" -f $archivePath, $inventory.Count)
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
