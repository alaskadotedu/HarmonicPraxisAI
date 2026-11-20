Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutJson = Join-Path $BaseDir 'workspace_index_tree.json'
$Phi = (1.0 + [math]::Sqrt(5.0)) / 2.0
$InvSqrt2 = 1.0 / [math]::Sqrt(2.0)

$Script:NodeSeq = 0
$Script:Nodes = [System.Collections.Generic.List[object]]::new()

function Invoke-HarmonicNodeStep([int]$Seq, [double]$SizeKb, [double]$AgeSec) {
    $psi = (($Seq * 0.6180339887) % (2.0 * [math]::PI)) - [math]::PI
    $gain = [math]::Min(1.0, [math]::Max(0.05, ($SizeKb / 64.0)))
    $purity = [math]::Min(0.99, [math]::Max(0.45, 1.0 / (1.0 + [math]::Log10($AgeSec + 1.0) * 0.15)))
    $s0 = [math]::Log10($SizeKb + 1.0) * 2.5
    $s1 = [math]::Sin($psi) * 2.0
    $cP = [math]::Cos($psi); $sP = [math]::Sin($psi)

    $amb0 = [math]::Round($InvSqrt2 * ($cP * $s0 - $sP * $s1), 4)
    $amb1 = [math]::Round($InvSqrt2 * ($sP * $s0 + $cP * $s1), 4)
    $amb4 = [math]::Round($cP * $psi, 4)
    $amb5 = [math]::Round($sP * $psi, 4)

    $k = (1.0 + 2.5 * $gain) * (1.2 - 0.5 * $purity)
    $bend = ($k * $cP * ($s0 * $s0 + $s1 * $s1)) + (1.5 * $k * $psi * $psi)
    $phiW = [math]::Pow($Phi, -($Seq % 6))
    $breach = ([math]::Abs($bend) -gt 40.0 -or $purity -lt 0.55)
    $regBend = if ($breach) { [math]::Sign($bend) * [math]::Min([math]::Abs($bend), 40.0) } else { $bend }

    return [pscustomobject]@{
        Psi           = [math]::Round($psi, 4)
        PhiWeight     = [math]::Round($phiW, 4)
        RegulatedBend = [math]::Round($regBend, 4)
        Ambient6D     = @($amb0, $amb1, 0.0, 0.0, $amb4, $amb5)
        Posture       = if ($breach) { 'CLAMPED_COMPLIANT' } else { 'NOMINAL_LOCKED' }
    }
}

function Build-RecursiveWorkspaceTree([string]$DirPath, [string]$Prefix, [int]$Depth) {
    $entries = @(Get-ChildItem -LiteralPath $DirPath | Where-Object { $_.Name -ne 'workspace_index_tree.json' } | Sort-Object @{Expression={$_.PSIsContainer};Descending=$true}, Name)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $item = $entries[$i]
        $isLast = ($i -eq ($entries.Count - 1))
        $connector = if ($isLast) { '+-- ' } else { '|-- ' }
        $nextPrefix = $Prefix + $(if ($isLast) { '    ' } else { '|   ' })
        $Script:NodeSeq++

        if ($item.PSIsContainer) {
            Write-Host ("{0}{1}[DIR #{2:D2}] {3}/" -f $Prefix, $connector, $Script:NodeSeq, $item.Name) -ForegroundColor Yellow
            $Script:Nodes.Add([pscustomobject]@{
                Seq = $Script:NodeSeq; Depth = $Depth; Type = 'DIRECTORY'; Name = $item.Name
                RelativePath = $item.FullName.Substring($BaseDir.Length).TrimStart('\')
                SizeKB = 0; Sha256Short = 'DIRECTORY'; PhiWeight = 1.0; RegulatedBend = 0.0; Posture = 'CONTAINER_INDEXED'
            })
            Build-RecursiveWorkspaceTree -DirPath $item.FullName -Prefix $nextPrefix -Depth ($Depth + 1)
        } else {
            $sizeKb = [math]::Round($item.Length / 1KB, 2)
            $ageSec = [math]::Max(1.0, ([DateTime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds)
            $fs = [System.IO.File]::Open($item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { $shaAlgo = [System.Security.Cryptography.SHA256]::Create(); $sha = [BitConverter]::ToString($shaAlgo.ComputeHash($fs)).Replace('-', '').Substring(0, 12); $shaAlgo.Dispose() } finally { $fs.Dispose() }
            $step = Invoke-HarmonicNodeStep -Seq $Script:NodeSeq -SizeKb $sizeKb -AgeSec $ageSec
            $barLen = [int][math]::Max(1, [math]::Round($step.PhiWeight * 12))
            $phiBar = ('#' * $barLen).PadRight(12, '.')

            Write-Host ("{0}{1}[{2:D2}] {3,-34} | {4,6:F2} KB | SHA:{5} | Phi:[{6}] | {7}" -f $Prefix, $connector, $Script:NodeSeq, $item.Name, $sizeKb, $sha, $phiBar, $step.Posture)
            $Script:Nodes.Add([pscustomobject]@{
                Seq = $Script:NodeSeq; Depth = $Depth; Type = 'FILE'; Name = $item.Name
                RelativePath = $item.FullName.Substring($BaseDir.Length).TrimStart('\')
                SizeKB = $sizeKb; Sha256Short = $sha; Psi = $step.Psi; PhiWeight = $step.PhiWeight
                RegulatedBend = $step.RegulatedBend; Ambient6D = $step.Ambient6D; Posture = $step.Posture
            })
        }
    }
}

Write-Host "`n=== HARMONIC PRAXIS AI // RECURSIVE WORKSPACE INDEX ===" -ForegroundColor Cyan
Write-Host "[ROOT] $BaseDir" -ForegroundColor Green
Build-RecursiveWorkspaceTree -DirPath $BaseDir -Prefix '' -Depth 0

$TotalFiles = @($Script:Nodes | Where-Object { $_.Type -eq 'FILE' }).Count
$TotalDirs  = @($Script:Nodes | Where-Object { $_.Type -eq 'DIRECTORY' }).Count
$Summary = [ordered]@{
    GeneratedUtc     = [DateTime]::UtcNow.ToString('o')
    WorkspaceRoot    = $BaseDir
    TotalDirectories = $TotalDirs
    TotalFiles       = $TotalFiles
    TotalNodes       = $Script:Nodes.Count
    TreeNodes        = $Script:Nodes
}
[System.IO.File]::WriteAllText($OutJson, ($Summary | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("`n[INDEX COMPLETE] Indexed {0} directories & {1} files ({2} total nodes) -> {3}" -f $TotalDirs, $TotalFiles, $Script:Nodes.Count, $OutJson) -ForegroundColor Green