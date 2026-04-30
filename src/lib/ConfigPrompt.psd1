@{
    RootModule        = 'ConfigPrompt.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7c6d3a4-91e2-4b66-8e07-2a01dc6f1f12'
    Author            = 'MusicRipper'
    Description       = 'Shared CLI/WPF prompt helpers for path inputs (Phase 6.6).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Read-RipperPathPrompt',
        'Show-RipperFolderPicker',
        'Show-RipperFilePicker',
        'Write-RipperConfigSection',
        'Get-RipperOneDriveRoot'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
