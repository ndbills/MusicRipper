@{
    RootModule        = 'Config.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a8f6d5b2-7c3a-4d1e-9b6e-1f2a3b4c5d6e'
    Author            = 'MusicRipper'
    Description       = 'Per-machine config + DPAPI credential storage for MusicRipper.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-RipperConfigPath', 'Get-RipperConfigRoot',
        'New-RipperConfigObject', 'Save-RipperConfig', 'Import-RipperConfig', 'Assert-RipperConfig',
        'Save-RipperCredential', 'Import-RipperCredential'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
