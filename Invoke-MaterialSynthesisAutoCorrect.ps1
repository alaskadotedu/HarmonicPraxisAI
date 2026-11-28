[CmdletBinding()]
param()

function Invoke-MaterialSynthesisAutoCorrect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [double]$TargetBend = 8.0,
        [double]$Tolerance = 0.05,
        [double]$Gain = 0.72,
        [double]$Purity = 0.88,
        [double]$Alpha = 0.50
    )

    # The existing equilibrium routine applies a 4-variable Newton step to a
    # single bend residual. Search only Psi here so the correction is bounded
    # and does not drift the material purity into the breach range.
    $best = $null
    $bestError = [double]::PositiveInfinity

    foreach ($step in @(0.05, 0.005, 0.0005)) {
        if ($null -eq $best) {
            $start = -3.14
            $end = 3.14
        } else {
            $start = [math]::Max(-3.14, $best.JacobianCore.ControlVectorX.Psi - (10.0 * $step))
            $end = [math]::Min(3.14, $best.JacobianCore.ControlVectorX.Psi + (10.0 * $step))
        }

        for ($psi = $start; $psi -le ($end + ($step * 0.25)); $psi += $step) {
            $candidate = Invoke-MaterialSynthesis -Profile $Profile -Psi $psi -Gain $Gain -Purity $Purity -Alpha $Alpha -TargetBend $TargetBend
            if ($candidate.JacobianCore.BreachDetected) { continue }

            $bendError = [math]::Abs($candidate.JacobianCore.ObservableY.RegulatedBend - $TargetBend)
            if ($bendError -lt $bestError) {
                $best = $candidate
                $bestError = $bendError
            }
        }
    }

    if ($null -eq $best -or $bestError -gt $Tolerance) {
        $reportedError = if ($null -eq $best) { 'no breach-free candidate' } else { "best bend residual $bestError exceeds tolerance $Tolerance" }
        throw "Auto-correction failed for profile '$Profile': $reportedError."
    }

    Write-Host ("AUTO-CORRECTED {0}: psi={1}, bend={2}, residual={3}" -f $Profile, $best.JacobianCore.ControlVectorX.Psi, $best.JacobianCore.ObservableY.RegulatedBend, $bestError)
    return $best
}
