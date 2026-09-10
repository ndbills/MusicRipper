@{
    RootModule        = 'FailedRips.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e92e1a31-10db-4f71-9b40-530524fd4349'
    Author            = 'MusicRipper'
    Description       = 'Preserve failed extraction attempts and recycle them after a clean replacement.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-RipperFailedRipAttempts',
        'Move-RipperFolderToRecycleBin',
        'Move-RipperMarkedFailedRip',
        'Save-RipperFailedRip',
        'Remove-RipperFailedRipAttempts'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}