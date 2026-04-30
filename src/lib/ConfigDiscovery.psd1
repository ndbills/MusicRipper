@{
    RootModule        = 'ConfigDiscovery.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd3e8c2a1-7c4f-4b18-8a3a-9c9efe5a2c11'
    Author            = 'MusicRipper'
    Description       = 'Discover available sync targets and providers from the codebase (Phase 6.6).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-RipperAvailableSyncTargets',
        'Get-RipperAvailableMetadataProviders',
        'Get-RipperAvailableCoverArtProviders'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
