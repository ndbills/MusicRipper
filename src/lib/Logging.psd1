@{
    RootModule        = 'Logging.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b9e7c6a3-8d4b-5e2f-ac7f-2a3b4c5d6e7f'
    Author            = 'MusicRipper'
    Description       = 'Structured per-session log file writer for MusicRipper.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Start-RipperLog','Write-RipperLog','Stop-RipperLog','Get-RipperLogPath','Set-RipperLogPath','Copy-RipperLog')
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
