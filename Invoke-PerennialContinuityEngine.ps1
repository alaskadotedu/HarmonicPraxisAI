param(
    [string]$ConceptLabel = "HARMONIC_QUANTIZER_GENESIS",
    [int[]]$PolygonLatticeSpectrum = @(4, 6, 8, 12)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $RootDir 'HarmonicMaterialApplicationEngine.ps1')

$ledgerPath = Join-Path $RootDir 'perennial_continuity_ledger.json'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$prevHash = "0" * 64
$existingChain = @()
if (Test-Path -LiteralPath $ledgerPath) {
    $loaded = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    if ($null -ne $loaded -and $null -ne $loaded.generations) {
        $existingChain = @($loaded.generations)
        if ($existingChain.Count -gt 0) {
            $prevHash = $existingChain[$existingChain.Count - 1].genesis_sha256
        }
    }
}

$excludeRx = '(\.db-wal|\.db-shm|\.vhdx|\.iso|\.dpapi)$|\\Snapshots\\|\\HyperV_VM\\|\\DatabankArchive\\|\\\.git\\|\\github-profile-repo\\'
$wsFiles = Get-ChildItem -LiteralPath $RootDir -File -Recurse |
    Where-Object { $_.FullName -notmatch $excludeRx -and $_.Name -ne 'perennial_continuity_ledger.json' } |
    Sort-Object FullName

$sb = [System.Text.StringBuilder]::new()
foreach ($f in $wsFiles) {
    $rel = $f.FullName.Substring($RootDir.Length).TrimStart('\')
    $h   = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $null = $sb.Append("$rel`:$h`n")
}
$merkleRoot = Get-Sha256Hex ($sb.ToString())

$matriculatedCells = [System.Collections.Generic.List[object]]::new()
$surrPath = Join-Path $RootDir 'harmonic_surrogate_v4_3.json'
$surrHash = 'ANALYTICAL_ONLY'; $modelObj = $null
if (Test-Path -LiteralPath $surrPath) {
    $raw = Get-Content -LiteralPath $surrPath -Raw
    $surrHash = (Get-Sha256Hex $raw).Substring(0, 16)
    $modelObj = $raw | ConvertFrom-Json
}

foreach ($nSides in $PolygonLatticeSpectrum) {
    $jac = Invoke-JacobianEngine -Psi 0.523599 -Gain 0.72 -Purity 0.88 -Alpha 0.50 -Sides $nSides -SolveEquilibrium -TargetBend 8.0 -ModelObj $modelObj -SurrHash $surrHash
    $perennialValid = ($jac.MassAugmentation.InvariantSatisfied -and (-not $jac.JacobianTensor.Singular) -and (-not $jac.BreachDetected))
    $matriculatedCells.Add([pscustomobject]@{
        quantizer_n      = $nSides
        sector_rad       = $jac.Polygonal.SectorAngleRad
        coherence        = $jac.Polygonal.Coherence
        spectral_radius  = $jac.JacobianTensor.SpectralRadius
        regulated_bend   = $jac.ObservableY.RegulatedBend
        mass_invariant   = $jac.MassAugmentation.InvariantSatisfied
        perennial_valid  = $perennialValid
        state_hash16     = $jac.StateHash16
    })
}

$allValid = (@($matriculatedCells | Where-Object { -not $_.perennial_valid }).Count -eq 0)
if (-not $allValid) {
    throw "Quantizer matriculation halted: one or more N-gon manifolds violated perennial validity invariants."
}

$genIndex    = $existingChain.Count + 1
$tsUtc       = [DateTime]::UtcNow.ToString('o')
$cellDigest  = ($matriculatedCells | ForEach-Object { "$($_.quantizer_n):$($_.state_hash16)" }) -join '|'
$genesisHash = Get-Sha256Hex ("$prevHash|$merkleRoot|$cellDigest|$ConceptLabel|$genIndex")

$newGeneration = [pscustomobject]@{
    generation_seq      = $genIndex
    timestamp_utc       = $tsUtc
    concept_origin      = $ConceptLabel
    parent_genesis_sha  = $prevHash
    workspace_merkle    = $merkleRoot
    genesis_sha256      = $genesisHash
    perennial_certified = $allValid
    matriculated_quanta = $matriculatedCells
}

$updatedChain = @($existingChain) + @($newGeneration)
$ledgerObj = [ordered]@{
    stratagem_version = "PERENNIAL_CONTINUITY_v1.0"
    repository_origin = "alaskadotedu/HarmonicPraxisAI"
    generation_count  = $updatedChain.Count
    latest_genesis    = $genesisHash
    generations       = $updatedChain
}

[System.IO.File]::WriteAllText($ledgerPath, ($ledgerObj | ConvertTo-Json -Depth 6), $utf8NoBom)
$newGeneration | ConvertTo-Json -Depth 5