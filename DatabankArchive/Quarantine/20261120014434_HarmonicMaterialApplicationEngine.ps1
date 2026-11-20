[CmdletBinding()]
param(
    [ValidateSet('PHOTONIC_CRYSTAL_HEX', 'SUPERCONDUCTING_METAMATERIAL', 'TOPO_INSULATOR_OCT', 'QUASICRYSTAL_PHI_12')]
    [string]$MaterialProfile = 'PHOTONIC_CRYSTAL_HEX',
    [double]$Psi = 0.50,
    [double]$Gain = 0.72,
    [double]$Purity = 0.88,
    [double]$Alpha = 0.50,
    [double]$TargetBend = 8.0,
    [switch]$SolveEquilibrium,
    [switch]$BatchSweep,
    [switch]$PersistVault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $RootDir 'HarmonicJacobianEngine.ps1')

$Script:MaterialCatalog = @{
    'PHOTONIC_CRYSTAL_HEX'         = @{ Sides = 6;  BaseEps = 11.68; BaseMu = 1.00; ThermalDamp = 0.86; LatticeNm = 420.0 }
    'SUPERCONDUCTING_METAMATERIAL' = @{ Sides = 4;  BaseEps = -2.40; BaseMu = 0.35; ThermalDamp = 0.96; LatticeNm = 280.0 }
    'TOPO_INSULATOR_OCT'           = @{ Sides = 8;  BaseEps = 16.20; BaseMu = 1.12; ThermalDamp = 0.91; LatticeNm = 510.0 }
    'QUASICRYSTAL_PHI_12'          = @{ Sides = 12; BaseEps = 7.85;  BaseMu = 0.94; ThermalDamp = 0.94; LatticeNm = 618.0 }
}

function Invoke-MaterialSynthesis {
    param(
        [string]$Profile = 'PHOTONIC_CRYSTAL_HEX',
        [double]$Psi = 0.50,
        [double]$Gain = 0.72,
        [double]$Purity = 0.88,
        [double]$Alpha = 0.50,
        [double]$TargetBend = 8.0,
        [switch]$SolveEquilibrium,
        [switch]$Persist
    )

    if (-not $Script:MaterialCatalog.ContainsKey($Profile)) { $Profile = 'PHOTONIC_CRYSTAL_HEX' }
    $spec = $Script:MaterialCatalog[$Profile]

    $surrPath = Join-Path $RootDir 'harmonic_surrogate_v4_3.json'
    $surrHash = 'ANALYTICAL_ONLY'; $modelObj = $null
    if (Test-Path -LiteralPath $surrPath) {
        $raw = Get-Content -LiteralPath $surrPath -Raw
        $surrHash = (Get-Sha256Hex $raw).Substring(0, 16)
        $modelObj = $raw | ConvertFrom-Json
    }

    $jac = Invoke-JacobianEngine -Psi $Psi -Gain $Gain -Purity $Purity -Alpha $Alpha -Sides $spec.Sides -SolveEquilibrium:$SolveEquilibrium -TargetBend $TargetBend -ModelObj $modelObj -SurrHash $surrHash

    $coh = $jac.Polygonal.Coherence
    $eta = $jac.MassAugmentation.AugmentationRatio
    $epsEff = [math]::Round($spec.BaseEps * (0.85 + 0.15 * $coh) * (1.0 - 0.08 * $eta), 5)
    $muEff  = [math]::Round($spec.BaseMu * (0.90 + 0.10 * $jac.ControlVectorX.Purity), 5)
    $nIndex = [math]::Round([math]::Sqrt([math]::Abs($epsEff * $muEff)) * $(if ($epsEff -lt 0 -and $muEff -lt 1.0) { -1.0 } else { 1.0 }), 5)
    $bandgapThz = [math]::Round(($jac.ObservableY.FrequencyThz * $coh * $spec.ThermalDamp) / $Script:PHI, 5)
    $qFactor    = [math]::Round((1000.0 * $jac.ControlVectorX.Purity * $spec.ThermalDamp) / [math]::Max(0.05, (1.0 - $coh + $eta * 0.2)), 2)

    $materialState = [pscustomobject]@{
        ApplicationEngine  = 'HARMONIC_MATERIAL_ENGINE_v8.0'
        MaterialProfile    = $Profile
        LatticeConstantNm  = $spec.LatticeNm
        ConstitutiveTensor = [pscustomobject]@{
            PermittivityEff    = $epsEff
            PermeabilityEff    = $muEff
            RefractiveIndex    = $nIndex
            PhotonicBandgapThz = $bandgapThz
            ResonanceQFactor   = $qFactor
            MetamaterialClass  = if ($nIndex -lt 0) { 'NEGATIVE_INDEX_LEFT_HANDED' } else { 'DIELECTRIC_HIGH_Q_LATTICE' }
        }
        JacobianCore       = $jac
    }

    if ($Persist) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $audit = ([ordered]@{ ts = $jac.TimestampUtc; profile = $Profile; sha16 = $jac.StateHash16; n_index = $nIndex; q_factor = $qFactor; bend = $jac.ObservableY.RegulatedBend; status = $jac.Status } | ConvertTo-Json -Compress)
        [System.IO.File]::AppendAllText((Join-Path $RootDir 'middleware_audit.jsonl'), ($audit + [Environment]::NewLine), $utf8)

        $dbPath = Join-Path $RootDir 'harmonic_praxis_vault.db'
        if ((Test-Path -LiteralPath $dbPath) -and (Get-Command node -ErrorAction SilentlyContinue)) {
            $prevPref = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $js = "const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv);try{db.prepare('INSERT INTO telemetry_frames(step_seq,coupling_gain,frequency_thz,watermark_wt,regulated_bend,breach_detected)VALUES(?,?,?,?,?,?)').run(Number(process.argv),Number(process.argv),Number(process.argv),Number(process.argv),Number(process.argv),process.argv==='True'?1:0);}catch(e){}finally{db.close();}"
            $null = & node --no-warnings -e $js $dbPath $jac.EvalId $jac.ObservableY.CouplingGain $jac.ObservableY.FrequencyThz $jac.ObservableY.WatermarkWt $jac.ObservableY.RegulatedBend $jac.BreachDetected 2>$null
            $ErrorActionPreference = $prevPref
        }
    }

    return $materialState
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($BatchSweep) {
        $results = foreach ($prof in $Script:MaterialCatalog.Keys) {
            Invoke-MaterialSynthesis -Profile $prof -Psi $Psi -Gain $Gain -Purity $Purity -Alpha $Alpha -TargetBend $TargetBend -SolveEquilibrium:$SolveEquilibrium -Persist:$PersistVault
        }
        $outPath = Join-Path $RootDir 'material_synthesis_batch.json'
        [System.IO.File]::WriteAllText($outPath, ($results | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        $results | ConvertTo-Json -Depth 6
    } else {
        $single = Invoke-MaterialSynthesis -Profile $MaterialProfile -Psi $Psi -Gain $Gain -Purity $Purity -Alpha $Alpha -TargetBend $TargetBend -SolveEquilibrium:$SolveEquilibrium -Persist:$PersistVault
        $single | ConvertTo-Json -Depth 6
    }
}
