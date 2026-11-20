@{
    RootModule        = 'HarmonicPraxisAI.psm1'
    ModuleVersion     = '4.3.0'
    GUID              = 'f4b8e210-9c3d-4a7e-8b1f-244d60000430'
    Author            = 'Harmonic Autonomous Praxis'
    Description       = 'Unified Pure-PowerShell Distillate AI Surrogate Assembly, Hyperfine Frequency Sifter, Physics/FDIR Simulator & REST Microservice'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Invoke-HyperfineFrequencySift',
        'New-HarmonicDataset',
        'Invoke-HarmonicHyperparameterTuning',
        'Train-HarmonicSurrogateModel',
        'Invoke-HarmonicSurrogateInference',
        'Export-HarmonicModelArtifact',
        'Import-HarmonicModelArtifact'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
