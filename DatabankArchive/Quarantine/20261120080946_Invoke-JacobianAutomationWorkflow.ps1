Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $BaseDir 'HarmonicJacobianEngine.ps1')

function Invoke-FullJacobianAutomation {
    param(
        [double]$TargetBend = 8.0,
        [int[]]$PolygonSchedule = @(4, 6, 8, 12),
        [int]$PhaseSteps = 12
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $surrPath = Join-Path $BaseDir 'harmonic_surrogate_v4_3.json'
    $surrHash = 'ANALYTICAL_ONLY'
    $modelObj = $null
    if (Test-Path -LiteralPath $surrPath) {
        $raw = Get-Content -LiteralPath $surrPath -Raw
        $surrHash = (Get-Sha256Hex $raw).Substring(0, 16)
        $modelObj = $raw | ConvertFrom-Json
    }

    $csvPath   = Join-Path $BaseDir 'jacobian_automation_matrix.csv'
    $auditPath = Join-Path $BaseDir 'middleware_audit.jsonl'
    $lockPath  = Join-Path $BaseDir 'reproducibility_lock.json'
    $dbPath    = Join-Path $BaseDir 'harmonic_praxis_vault.db'
    $utf8      = New-Object System.Text.UTF8Encoding($false)

    $csvRows = [System.Collections.Generic.List[string]]::new()
    $csvRows.Add("eval_id,timestamp_utc,sides,psi,gain,purity,alpha,regulated_bend,freq_thz,det_j,trace_j,frobenius_j,spectral_radius,condition_num,contractive,cold_mass,low_mass,mass_invariant_ok,newton_iters,status,state_sha16")

    $certifiedCount   = 0
    $contractiveCount = 0
    $breachCount      = 0
    $lastState        = $null

    foreach ($sides in $PolygonSchedule) {
        for ($i = 0; $i -lt $PhaseSteps; $i++) {
            $psi    = -3.0 + ($i * (6.0 / [math]::Max(1, ($PhaseSteps - 1))))
            $gain   = [math]::Round(0.45 + (0.45 * (($i % 4) / 3.0)), 4)
            $purity = [math]::Round(0.72 + (0.24 * (($i % 3) / 2.0)), 4)
            $alpha  = 0.50

            $st = Invoke-JacobianEngine -Psi $psi -Gain $gain -Purity $purity -Alpha $alpha -Sides $sides -SolveEquilibrium -TargetBend $TargetBend -ModelObj $modelObj -SurrHash $surrHash
            $lastState = $st

            if (-not $st.BreachDetected) { $certifiedCount++ } else { $breachCount++ }
            if ($st.JacobianTensor.Contractive) { $contractiveCount++ }

            $csvRows.Add(("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16},{17},{18},{19},{20}" -f
                $st.EvalId, $st.TimestampUtc, $st.Polygonal.Sides,
                $st.ControlVectorX.Psi, $st.ControlVectorX.Gain, $st.ControlVectorX.Purity, $st.ControlVectorX.Alpha,
                $st.ObservableY.RegulatedBend, $st.ObservableY.FrequencyThz,
                $st.JacobianTensor.Determinant, $st.JacobianTensor.Trace, $st.JacobianTensor.FrobeniusNorm,
                $st.JacobianTensor.SpectralRadius, $st.JacobianTensor.ConditionNumber, $st.JacobianTensor.Contractive,
                $st.MassAugmentation.ColdMass, $st.MassAugmentation.LowMass, $st.MassAugmentation.InvariantSatisfied,
                $st.NewtonIterations, $st.Status, $st.StateHash16
            ))

            $auditLine = ([ordered]@{
                ts     = $st.TimestampUtc
                mode   = 'BATCH_JACOBIAN_AUTOMATION'
                sides  = $st.Polygonal.Sides
                sha16  = $st.StateHash16
                det    = $st.JacobianTensor.Determinant
                rho    = $st.JacobianTensor.SpectralRadius
                bend   = $st.ObservableY.RegulatedBend
                status = $st.Status
            } | ConvertTo-Json -Compress)
            [System.IO.File]::AppendAllText($auditPath, ($auditLine + [Environment]::NewLine), $utf8)
        }
    }

    [System.IO.File]::WriteAllLines($csvPath, $csvRows, $utf8)

    if ($null -ne $lastState) {
        $lockObj = [ordered]@{
            workflow_completed_utc = [DateTime]::UtcNow.ToString('o')
            total_evaluations      = ($csvRows.Count - 1)
            certified_count        = $certifiedCount
            contractive_count      = $contractiveCount
            breach_count           = $breachCount
            surrogate_sha16        = $surrHash
            terminal_state_sha256  = $lastState.FullStateSha256
            csv_artifact           = $csvPath
        } | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($lockPath, $lockObj, $utf8)
    }

    $sqliteStatus = 'DB_SKIPPED'
    if ((Test-Path -LiteralPath $dbPath) -and (Get-Command node -ErrorAction SilentlyContinue)) {
        $nodeBatch = "const fs=require('fs');const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv);const lines=fs.readFileSync(process.argv,'utf8').trim().split(/\r?\n/).slice(1);const ins=db.prepare('INSERT INTO telemetry_frames(step_seq,coupling_gain,frequency_thz,watermark_wt,regulated_bend,breach_detected)VALUES(?,?,?,?,?,?)');db.exec('BEGIN');for(const l of lines){const c=l.split(',');ins.run(Number(c),Number(c),Number(c),0.78,Number(c),c==='AUGMENTED_CLAMPED'?1:0);}db.exec('COMMIT');db.close();console.log('SQLITE_BATCH_OK:'+lines.length);"
        $sqliteStatus = (& node -e $nodeBatch $dbPath $csvPath 2>&1) -join ' '
    }

    $sw.Stop()
    return [pscustomobject]@{
        WorkflowStatus     = 'AUTOMATION_WORKFLOW_COMPLETE'
        ElapsedMs          = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        TotalMatrixStates  = ($csvRows.Count - 1)
        CertifiedStates    = $certifiedCount
        ContractiveStates  = $contractiveCount
        ClampedExcursions  = $breachCount
        CsvArtifactPath    = $csvPath
        VaultSyncStatus    = $sqliteStatus
        TerminalStateHash  = if ($null -ne $lastState) { $lastState.StateHash16 } else { 'NONE' }
    }
}
