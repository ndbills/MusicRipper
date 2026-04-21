@{
    RootModule        = 'Common.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c0a8b9d4-9e5c-6f3a-bd80-3b4c5d6e7f80'
    Author            = 'MusicRipper'
    Description       = 'Shared utilities (path sanitization, repo root) for MusicRipper.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('ConvertTo-SafeWindowsPathSegment', 'Get-RipperRepoRoot', 'Get-CueToolsPath')
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
