[CmdletBinding()]
param(
    [string]$MaterialProfile = 'PHOTONIC_CRYSTAL_HEX',
    [double]$Psi = 0.50,
    [double]$Gain = 0.72,
    [double]$Purity = 0.88,
    [double]$Alpha = 0.50,
    [double]$TargetBend = 8.0,
    [int]$GridRows = 4,
    [int]$GridCols = 4,
    [switch]$SolveEquilibrium,
    [switch]$BatchSweep,
    [switch]$ExportCad,
    [switch]$PersistVault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $RootDir 'HarmonicJacobianEngine.ps1')

$Script:CustomProfilesPath = Join-Path $RootDir 'custom_material_profiles.json'

$Script:MaterialCatalog = [ordered]@{
    'PHOTONIC_CRYSTAL_HEX'         = @{ Sides = 6;  BaseEps = 11.68; BaseMu = 1.00; ThermalDamp = 0.86; LatticeNm = 420.0 }
    'SUPERCONDUCTING_METAMATERIAL' = @{ Sides = 4;  BaseEps = -2.40; BaseMu = 0.35; ThermalDamp = 0.96; LatticeNm = 280.0 }
    'TOPO_INSULATOR_OCT'           = @{ Sides = 8;  BaseEps = 16.20; BaseMu = 1.12; ThermalDamp = 0.91; LatticeNm = 510.0 }
    'QUASICRYSTAL_PHI_12'          = @{ Sides = 12; BaseEps = 7.85;  BaseMu = 0.94; ThermalDamp = 0.94; LatticeNm = 618.0 }
}

function Import-CustomMaterialProfiles {
    if (Test-Path -LiteralPath $Script:CustomProfilesPath) {
        try {
            $loaded = Get-Content -LiteralPath $Script:CustomProfilesPath -Raw | ConvertFrom-Json
            if ($null -ne $loaded) {
                foreach ($prop in $loaded.PSObject.Properties) {
                    $v = $prop.Value
                    $Script:MaterialCatalog[$prop.Name] = @{
                        Sides = [math]::Max(3, [int]$v.Sides); BaseEps = [double]$v.BaseEps
                        BaseMu = [double]$v.BaseMu; ThermalDamp = [double]$v.ThermalDamp; LatticeNm = [double]$v.LatticeNm
                    }
                }
            }
        } catch {}
    }
}

function Register-CustomMaterialProfile {
    param([Parameter(Mandatory = $true)][string]$Name, [int]$Sides = 6, [double]$BaseEps = 9.5, [double]$BaseMu = 1.0, [double]$ThermalDamp = 0.90, [double]$LatticeNm = 450.0)
    Import-CustomMaterialProfiles
    $cleanName = ($Name -replace '[^A-Za-z0-9_\-]', '_').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($cleanName)) { $cleanName = "CUSTOM_MAT_$(Get-Random -Minimum 100 -Maximum 999)" }
    $entry = @{ Sides = [math]::Max(3, [math]::Min(32, $Sides)); BaseEps = $BaseEps; BaseMu = $BaseMu; ThermalDamp = [math]::Max(0.1, [math]::Min(1.0, $ThermalDamp)); LatticeNm = [math]::Max(10.0, $LatticeNm) }
    $Script:MaterialCatalog[$cleanName] = $entry
    [System.IO.File]::WriteAllText($Script:CustomProfilesPath, ($Script:MaterialCatalog | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Registered = $true; ProfileName = $cleanName; Spec = $entry; CatalogKeys = @($Script:MaterialCatalog.Keys) }
}

Import-CustomMaterialProfiles

function Invoke-MaterialSynthesis {
    param([string]$Profile = 'PHOTONIC_CRYSTAL_HEX', [double]$Psi = 0.50, [double]$Gain = 0.72, [double]$Purity = 0.88, [double]$Alpha = 0.50, [double]$TargetBend = 8.0, [switch]$SolveEquilibrium, [switch]$Persist)
    Import-CustomMaterialProfiles
    if (-not $Script:MaterialCatalog.Contains($Profile)) { $Profile = 'PHOTONIC_CRYSTAL_HEX' }
    $spec = $Script:MaterialCatalog[$Profile]

    $surrPath = Join-Path $RootDir 'harmonic_surrogate_v4_3.json'
    $surrHash = 'ANALYTICAL_ONLY'; $modelObj = $null
    if (Test-Path -LiteralPath $surrPath) { $raw = Get-Content -LiteralPath $surrPath -Raw; $surrHash = (Get-Sha256Hex $raw).Substring(0, 16); $modelObj = $raw | ConvertFrom-Json }

    $jac = Invoke-JacobianEngine -Psi $Psi -Gain $Gain -Purity $Purity -Alpha $Alpha -Sides $spec.Sides -SolveEquilibrium:$SolveEquilibrium -TargetBend $TargetBend -ModelObj $modelObj -SurrHash $surrHash
    $coh = $jac.Polygonal.Coherence; $eta = $jac.MassAugmentation.AugmentationRatio
    $epsEff = [math]::Round($spec.BaseEps * (0.85 + 0.15 * $coh) * (1.0 - 0.08 * $eta), 5)
    $muEff  = [math]::Round($spec.BaseMu * (0.90 + 0.10 * $jac.ControlVectorX.Purity), 5)
    $nIndex = [math]::Round([math]::Sqrt([math]::Abs($epsEff * $muEff)) * $(if ($epsEff -lt 0 -and $muEff -lt 1.0) { -1.0 } else { 1.0 }), 5)
    $bandgapThz = [math]::Round(($jac.ObservableY.FrequencyThz * $coh * $spec.ThermalDamp) / $Script:PHI, 5)
    $qFactor    = [math]::Round((1000.0 * $jac.ControlVectorX.Purity * $spec.ThermalDamp) / [math]::Max(0.05, (1.0 - $coh + $eta * 0.2)), 2)

    $materialState = [pscustomobject]@{
        ApplicationEngine = 'HARMONIC_MATERIAL_ENGINE_v8.5'; MaterialProfile = $Profile; LatticeConstantNm = $spec.LatticeNm; CatalogProfiles = @($Script:MaterialCatalog.Keys)
        ConstitutiveTensor = [pscustomobject]@{ PermittivityEff = $epsEff; PermeabilityEff = $muEff; RefractiveIndex = $nIndex; PhotonicBandgapThz = $bandgapThz; ResonanceQFactor = $qFactor; MetamaterialClass = if ($nIndex -lt 0) { 'NEGATIVE_INDEX_LEFT_HANDED' } else { 'DIELECTRIC_HIGH_Q_LATTICE' } }
        JacobianCore = $jac
    }

    if ($Persist) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $audit = ([ordered]@{ ts = $jac.TimestampUtc; profile = $Profile; sha16 = $jac.StateHash16; n_index = $nIndex; q_factor = $qFactor; bend = $jac.ObservableY.RegulatedBend; status = $jac.Status } | ConvertTo-Json -Compress)
        [System.IO.File]::AppendAllText((Join-Path $RootDir 'middleware_audit.jsonl'), ($audit + [Environment]::NewLine), $utf8)
    }
    return $materialState
}

function Export-CadGdsiiLattice {
    param($MaterialState, [int]$Rows = 4, [int]$Cols = 4)
    $aNm = [double]$MaterialState.LatticeConstantNm; $sides = [int]$MaterialState.JacobianCore.Polygonal.Sides
    $rotRad = [double]$MaterialState.JacobianCore.Polygonal.SnappedVertexRad; $coh = [double]$MaterialState.JacobianCore.Polygonal.Coherence; $eta = [double]$MaterialState.JacobianCore.MassAugmentation.AugmentationRatio
    $coreRad = [math]::Round($aNm * (0.26 + 0.12 * $eta), 3); $ringRad = [math]::Round($coreRad * (1.22 + 0.15 * $coh), 3); $cladRad = [math]::Round($aNm * 0.44, 3); $dTheta = (2.0 * [math]::PI) / $sides
    $cells = [System.Collections.Generic.List[object]]::new(); $cifLines = [System.Collections.Generic.List[string]]::new()
    $cifLines.Add("(HARMONIC PRAXIS 4-LAYER GDSII/CIF STACK // PROFILE: $($MaterialState.MaterialProfile) // SHA: $($MaterialState.JacobianCore.StateHash16));"); $cifLines.Add("DS 1 1 100;")
    $pitchY = if ($sides -eq 6) { $aNm * ([math]::Sqrt(3.0) / 2.0) } else { $aNm }
    $maxX = (($Cols - 1) * $aNm) + $(if ($sides -eq 6) { $aNm * 0.5 } else { 0.0 }); $maxY = ($Rows - 1) * $pitchY; $pad = $aNm * 0.85

    $sbX = @(-$pad, ($maxX + $pad), ($maxX + $pad), -$pad, -$pad)
    $sbY = @(-$pad, -$pad, ($maxY + $pad), ($maxY + $pad), -$pad)
    $subGds = [System.Collections.Generic.List[int[]]]::new()
    $subVerts = [System.Collections.Generic.List[object]]::new()
    $subCif = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt 5; $i++) {
        $vx = [math]::Round($sbX[$i], 3); $vy = [math]::Round($sbY[$i], 3)
        $subVerts.Add([pscustomobject]@{ x_nm = $vx; y_nm = $vy })
        $ix = [int][math]::Round($vx * 1000.0); $iy = [int][math]::Round($vy * 1000.0)
        $subGds.Add(@($ix, $iy)); if ($i -lt 4) { $subCif.Add("$ix,$iy") }
    }
    $cifLines.Add("L L1;"); $cifLines.Add("P $($subCif -join ' ');")
    $cells.Add([pscustomobject]@{ cell_id = "SUBSTRATE_SLAB"; layer_name = "SUBSTRATE_DIELECTRIC"; center_nm = @([math]::Round($maxX/2.0,3), [math]::Round($maxY/2.0,3)); radius_nm = [math]::Round(($maxX+2*$pad)/2.0,3); gds_layer = 1; gds_datatype = 0; vertices_nm = $subVerts; gds_xy_dbu_pm = $subGds })

    $layers = @(@{ Layer = 10; Name = 'RESONATOR_CORE'; Rad = $coreRad; Rot = 0.0; N = $sides }, @{ Layer = 15; Name = 'PHASE_COUPLING_RING'; Rad = $ringRad; Rot = ($dTheta / 2.0); N = $sides }, @{ Layer = 20; Name = 'CLADDING_PASSIVATION'; Rad = $cladRad; Rot = 0.0; N = [math]::Max(4, [math]::Min(12, $sides * 2)) })
    foreach ($ls in $layers) {
        $cifLines.Add("L L$($ls.Layer);"); $stepAng = (2.0 * [math]::PI) / $ls.N
        for ($r = 0; $r -lt $Rows; $r++) {
            for ($c = 0; $c -lt $Cols; $c++) {
                $ox = if (($sides -eq 6) -and (($r % 2) -eq 1)) { $aNm * 0.5 } else { 0.0 }
                $cx = [math]::Round(($c * $aNm) + $ox, 3); $cy = [math]::Round($r * $pitchY, 3)
                $vertsNm = [System.Collections.Generic.List[object]]::new(); $gdsPts = [System.Collections.Generic.List[int[]]]::new(); $cifPts = [System.Collections.Generic.List[string]]::new()
                for ($k = 0; $k -le $ls.N; $k++) {
                    $ang = $rotRad + $ls.Rot + ($k * $stepAng)
                    $vx = [math]::Round($cx + ($ls.Rad * [math]::Cos($ang)), 3); $vy = [math]::Round($cy + ($ls.Rad * [math]::Sin($ang)), 3)
                    $vertsNm.Add([pscustomobject]@{ x_nm = $vx; y_nm = $vy })
                    $ix = [int][math]::Round($vx * 1000.0); $iy = [int][math]::Round($vy * 1000.0)
                    $gdsPts.Add(@($ix, $iy)); if ($k -lt $ls.N) { $cifPts.Add("$ix,$iy") }
                }
                $cifLines.Add("P $($cifPts -join ' ');")
                $cells.Add([pscustomobject]@{ cell_id = "$($ls.Name)_${r}_${c}"; layer_name = $ls.Name; center_nm = @($cx, $cy); radius_nm = $ls.Rad; gds_layer = $ls.Layer; gds_datatype = 0; vertices_nm = $vertsNm; gds_xy_dbu_pm = $gdsPts })
            }
        }
    }
    $cifLines.Add("DF;"); $cifLines.Add("C 1;"); $cifLines.Add("E")

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $jsonOut = Join-Path $RootDir 'cad_gdsii_lattice.json'; $cifOut = Join-Path $RootDir 'lattice_layout.cif'; $gdsOut = Join-Path $RootDir 'lattice_layout.gds'; $gdsJs = Join-Path $RootDir 'Export-BinaryGds.js'
    $pkg = [ordered]@{ format = 'GDSII_MULTILAYER_STACK_v2.0'; dbu_per_nanometer = 1000; material_profile = $MaterialState.MaterialProfile; state_sha16 = $MaterialState.JacobianCore.StateHash16; lattice_pitch_nm = $aNm; polygon_sides = $sides; grid_dimensions = @($Rows, $Cols); total_polygons = $cells.Count; cif_stream_preview = ($cifLines -join "`n"); structures = $cells }
    [System.IO.File]::WriteAllText($jsonOut, ($pkg | ConvertTo-Json -Depth 6), $utf8)
    [System.IO.File]::WriteAllLines($cifOut, $cifLines, $utf8)

    $binStatus = 'NODE_NOT_FOUND'
    if ((Test-Path -LiteralPath $gdsJs) -and (Get-Command node -ErrorAction SilentlyContinue)) {
        $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $binStatus = (& node --no-warnings $gdsJs $jsonOut $gdsOut 2>$null) -join ''
        $ErrorActionPreference = $prevPref
    }
    return [pscustomobject]@{ Exported = $true; BinaryGdsPath = $gdsOut; BinaryStats = $binStatus; JsonArtifact = $jsonOut; CifArtifact = $cifOut; LayerCount = 4; TotalPolygons = $cells.Count; CifPreview = ($cifLines -join "`n") }
}

if ($MyInvocation.InvocationName -ne '.') {
    $res = Invoke-MaterialSynthesis -Profile $MaterialProfile -Psi $Psi -Gain $Gain -Purity $Purity -Alpha $Alpha -TargetBend $TargetBend -SolveEquilibrium:$SolveEquilibrium -Persist:$PersistVault
    if ($ExportCad) {
        $cad = Export-CadGdsiiLattice -MaterialState $res -Rows $GridRows -Cols $GridCols
        [pscustomobject]@{ Material = $res; CadExport = $cad } | ConvertTo-Json -Depth 6
    } else { $res | ConvertTo-Json -Depth 6 }
}
