[CmdletBinding()]
param(
    [string]$RepoPath = 'C:\Users\dmjal\HarmonicPraxisAI',
    [switch]$ApplyDeterministicFixes
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    throw 'Repository path does not exist.'
}

$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$repoRootOutput = & git -C $resolvedRepoPath rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'The target directory is not a Git repository.'
}
$RepoRoot = [IO.Path]::GetFullPath([string]$repoRootOutput).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)

$secretPatterns = @(
    '(?i)(api[_-]?key|secret|token|password|bearer|authorization)\s*[:=]\s*["'']?[A-Za-z0-9_\-\.]{16,}["'']?',
    'sk-[A-Za-z0-9]{20,}',
    'ghp_[A-Za-z0-9]{36}',
    'github_pat_[A-Za-z0-9_]{22,}',
    'AIza[0-9A-Za-z\-_]{35}'
)
$forbiddenNames = @(
    'harmonic_api_key.txt',
    'edl_token.dpapi',
    'edl_transit_receipt.json',
    'harmonic_praxis_vault.db',
    'mcp.json',
    'middleware_audit.jsonl',
    'perennial_continuity_ledger.json'
)
$ignoreRules = @(
    '*.db',
    '*.db-wal',
    '*.db-shm',
    '*.dpapi',
    '*_key.txt',
    '*api_key*',
    'mcp.json',
    'middleware_audit.jsonl',
    'edl_transit_receipt.json',
    'perennial_continuity_ledger.json',
    '.env',
    'Snapshots/'
)
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)

function Get-TrackedPaths {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($RepoRoot)
    $startInfo.ArgumentList.Add('ls-files')
    $startInfo.ArgumentList.Add('-z')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start Git.'
    }
    $listing = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw 'Unable to enumerate tracked paths.'
    }
    if ([string]::IsNullOrEmpty($listing)) {
        return @()
    }
    return @($listing.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
}

function Get-FileState {
    param(
        [string]$RelativePath,
        [switch]$ApplyFixes
    )

    $leafName = [IO.Path]::GetFileName($RelativePath)
    $isForbidden = ($forbiddenNames -contains $leafName) -or ([IO.Path]::GetExtension($leafName) -in @('.db', '.dpapi'))
    $isMalformed = ($leafName -match "[@'|<>:`"?*]") -or
        ($leafName -like 'ersdmjalHarmonicPraxisAI*') -or
        ($leafName -like 'tZip = Get-ChildItem*') -or
        ($leafName -ceq "rvCode = @'") -or
        ($leafName -ceq 't.files) {') -or
        ($leafName -ceq 'olutePath')
    $hasSecret = $false

    if (-not $isForbidden) {
        $nativeRelativePath = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $fullPath = [IO.Path]::GetFullPath([IO.Path]::Combine($RepoRoot, $nativeRelativePath))
        $rootPrefix = $RepoRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A tracked path resolved outside the repository.'
        }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $item = Get-Item -LiteralPath $fullPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                try {
                    $bytes = [IO.File]::ReadAllBytes($fullPath)
                    if ($bytes -notcontains 0) {
                        $text = $utf8Strict.GetString($bytes)
                        $updatedText = $text
                        foreach ($pattern in $secretPatterns) {
                            if ([regex]::IsMatch($updatedText, $pattern)) {
                                $hasSecret = $true
                                if ($ApplyFixes) {
                                    $updatedText = [regex]::Replace($updatedText, $pattern, '[REDACTED_SECRET]')
                                }
                            }
                        }
                        if ($ApplyFixes -and $hasSecret) {
                            [IO.File]::WriteAllText($fullPath, $updatedText, [Text.UTF8Encoding]::new($false))
                            $hasSecret = $false
                            foreach ($pattern in $secretPatterns) {
                                if ([regex]::IsMatch($updatedText, $pattern)) {
                                    $hasSecret = $true
                                    break
                                }
                            }
                        }
                    }
                }
                catch [Text.DecoderFallbackException] {
                    $hasSecret = $false
                }
                catch {
                    throw "Unable to inspect tracked path: $RelativePath"
                }
            }
        }
    }

    $bitmask = '{0}|{1}|{2}' -f [int]$isForbidden, [int]$isMalformed, [int]$hasSecret
    $legend = switch ($bitmask) {
        '0|0|0' { 'STATE_NOMINAL_CLEAR' }
        '1|0|0' { 'ALERT_FORBIDDEN_ARTIFACT' }
        '0|1|0' { 'ALERT_MALFORMED_PATH' }
        '0|0|1' { 'ALERT_INLINE_SECRET' }
        '1|1|1' { 'CRITICAL_COMPOSITE_BREACH' }
        default { 'ALERT_MULTI_VECTOR_VIOLATION' }
    }
    $orResult = [int]($isForbidden -or $isMalformed -or $hasSecret)
    [pscustomobject]@{
        Path = $RelativePath
        Bitmask = $bitmask
        AutonomousLegend = $legend
        BooleanOrResult = $orResult
    }
}

function Add-IgnoreRules {
    $ignorePath = Join-Path $RepoRoot '.gitignore'
    if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
        $content = [IO.File]::ReadAllText($ignorePath, $utf8Strict)
    }
    else {
        $content = ''
    }
    $existingRules = @($content -split "`r?`n" | ForEach-Object { $_.Trim() })
    $missingRules = @($ignoreRules | Where-Object { $_ -notin $existingRules })
    if ($missingRules.Count -gt 0) {
        $content = $content.TrimEnd("`r", "`n")
        if ($content.Length -gt 0) {
            $content += "`n"
        }
        $content += ($missingRules -join "`n") + "`n"
        [IO.File]::WriteAllText($ignorePath, $content, [Text.UTF8Encoding]::new($false))
    }
}

if ($ApplyDeterministicFixes) {
    $initialPaths = Get-TrackedPaths
    foreach ($path in $initialPaths) {
        $null = Get-FileState -RelativePath $path -ApplyFixes
    }
    Add-IgnoreRules
}

$trackedPaths = Get-TrackedPaths
$results = foreach ($path in $trackedPaths) {
    Get-FileState -RelativePath $path
}
$flagged = @($results | Where-Object { $_.BooleanOrResult -eq 1 })
$globalGate = [int]($flagged.Count -gt 0)

if ($flagged.Count -gt 0) {
    $flagged | Sort-Object Path | Format-Table Path, Bitmask, AutonomousLegend, BooleanOrResult -AutoSize
}
else {
    'No flagged tracked files.'
}

"GLOBAL_BOOLEAN_OR_GATE=$globalGate"
exit $globalGate
