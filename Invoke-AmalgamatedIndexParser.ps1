Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MasterJson = Join-Path $BaseDir 'amalgamated_master_datum.json'
$MasterCsv  = Join-Path $BaseDir 'amalgamated_telemetry_index.csv'

$Files = @(Get-ChildItem -LiteralPath $BaseDir -File | Where-Object { $_.Extension -in '.csv', '.json', '.psd1', '.psm1' -and $_.Name -notlike 'amalgamated_*' })
$Catalog = [System.Collections.Generic.List[object]]::new()
$UnifiedRows = [System.Collections.Generic.List[object]]::new()
$JsonModels = [ordered]@{}
$GlobalIdx = 0

foreach ($f in $Files) {
    $ext = $f.Extension.ToLowerInvariant()
    $recCount = 0; $schema = @()
    if ($ext -eq '.csv') {
        $rows = @(Import-Csv -LiteralPath $f.FullName)
        $recCount = $rows.Count
        if ($recCount -gt 0) { $schema = @($rows[0].PSObject.Properties.Name) }
        foreach ($r in $rows) {
            $GlobalIdx++
            $UnifiedRows.Add([pscustomobject]@{
                GlobalIndex  = $GlobalIdx
                SourceFile   = $f.Name
                StepOrFrame  = if ($r.PSObject.Properties['Frame']) { $r.Frame } elseif ($r.PSObject.Properties['Step']) { $r.Step } else { $GlobalIdx }
                CouplingGain = if ($r.PSObject.Properties['CouplingGain']) { $r.CouplingGain } elseif ($r.PSObject.Properties['PredCouplingGain']) { $r.PredCouplingGain } else { '' }
                FrequencyThz = if ($r.PSObject.Properties['FrequencyThz']) { $r.FrequencyThz } elseif ($r.PSObject.Properties['PredFrequencyThz']) { $r.PredFrequencyThz } else { '' }
                WatermarkWt  = if ($r.PSObject.Properties['WatermarkWt']) { $r.WatermarkWt } elseif ($r.PSObject.Properties['PredWatermarkWt']) { $r.PredWatermarkWt } else { '' }
                BendingValue = if ($r.PSObject.Properties['RegulatedBend']) { $r.RegulatedBend } elseif ($r.PSObject.Properties['ExtrinsicBendingEnergy']) { $r.ExtrinsicBendingEnergy } elseif ($r.PSObject.Properties['ExtrinsicBend']) { $r.ExtrinsicBend } else { '' }
                Status       = if ($r.PSObject.Properties['Status']) { $r.Status } elseif ($r.PSObject.Properties['BreachDetected']) { "BREACH=$($r.BreachDetected)" } else { 'INDEXED_DATUM' }
            })
        }
    }
    elseif ($ext -eq '.json') {
        $parsed = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
        $schema = @($parsed.PSObject.Properties.Name)
        $recCount = 1
        $JsonModels[$f.Name] = [ordered]@{ SchemaKeys = $schema; Version = if ($parsed.PSObject.Properties['Version']) { $parsed.Version } elseif ($parsed.PSObject.Properties['Schema']) { $parsed.Schema } else { 'N/A' } }
    }
    else {
        $lines = @(Get-Content -LiteralPath $f.FullName)
        $recCount = $lines.Count
        $schema = @('PowerShellSourceLines')
    }
    $Catalog.Add([pscustomobject]@{ Index = ($Catalog.Count + 1); FileName = $f.Name; Format = $ext.TrimStart('.').ToUpper(); SizeKB = [math]::Round($f.Length / 1KB, 2); Records = $recCount; Schema = ($schema -join ', ') })
}
$NumericStats = foreach ($col in @('CouplingGain', 'FrequencyThz', 'WatermarkWt', 'BendingValue')) {
    $vals = @($UnifiedRows | Where-Object { $_.$col -ne '' -and $_.$col -ne $null } | ForEach-Object { [double]$_.$col })
    if ($vals.Count -gt 0) {
        $m = $vals | Measure-Object -Minimum -Maximum -Average
        [pscustomobject]@{ Metric = $col; SampleCount = $vals.Count; Min = [math]::Round($m.Minimum, 6); Max = [math]::Round($m.Maximum, 6); Avg = [math]::Round($m.Average, 6) }
    }
}

$AmalgamatedPayload = [ordered]@{
    GeneratedUtc     = [DateTime]::UtcNow.ToString('o')
    TotalFilesParsed = $Catalog.Count
    TotalDatumRows   = $UnifiedRows.Count
    FileCatalog      = $Catalog
    JsonArtifacts    = $JsonModels
    GlobalStatistics = $NumericStats
    UnifiedTelemetry = $UnifiedRows
}

[System.IO.File]::WriteAllText($MasterJson, ($AmalgamatedPayload | ConvertTo-Json -Depth 6 -Compress), [System.Text.UTF8Encoding]::new($false))
$UnifiedRows | Export-Csv -LiteralPath $MasterCsv -NoTypeInformation

Write-Host "`n=== 1. AMALGAMATED FILE & SCHEMA INDEX ($($Catalog.Count) Artifacts) ===" -ForegroundColor Cyan
$Catalog | Format-Table Index, FileName, Format, SizeKB, Records, Schema -AutoSize

Write-Host "=== 2. GLOBAL CROSS-DATASET STATISTICAL SUMMARY ($($UnifiedRows.Count) Total Rows) ===" -ForegroundColor Cyan
$NumericStats | Format-Table -AutoSize

Write-Host "=== 3. SAMPLE AMALGAMATED TELEMETRY INDEX (First 10 Unified Records) ===" -ForegroundColor Cyan
$UnifiedRows | Select-Object -First 10 | Format-Table -AutoSize

Write-Host "[COMPLETE] Amalgamated Index Saved to:`n  -> $MasterJson`n  -> $MasterCsv" -ForegroundColor Green