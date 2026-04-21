@{
    RootModule        = 'RipHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8c4d2f10-1a3b-4c5d-9e6f-7a8b9c0d1e2f'
    Author            = 'MusicRipper'
    Description       = 'Pure-logic helpers for the Phase 4 rip pipeline (filenames, CUE generation, log parsing, ETA formatting).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'New-RipperTrackFileName',
        'ConvertTo-RipperCueTime',
        'New-RipperCueSheet',
        'Get-RipperLogSummary',
        'ConvertTo-RipperEtaText',
        'ConvertTo-RipperReadSpeedText'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
