@{
    RootModule        = 'Rip.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd1b9c4e5-7f6a-4b8c-9e2d-3a4b5c6d7e80'
    Author            = 'MusicRipper'
    Description       = 'Pure-logic helpers for the rip pipeline (filenames, CUE generation, AR/CTDB log parsing).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'ConvertTo-RipperTrackFilename',
        'New-RipperCueSheet',
        'ConvertFrom-RipperRipLog'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
