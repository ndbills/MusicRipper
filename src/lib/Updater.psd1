@{
    RootModule        = 'Updater.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e7f8a9b0-1c2d-3e4f-5a60-7b8c9d0e1f20'
    Author            = 'MusicRipper'
    Description       = 'Self-update helpers: GitHub Release lookup, download/extract, atomic-rename apply, backup retention.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-RipperLatestRelease',
        'Compare-RipperVersion',
        'Get-RipperInstallRoot',
        'Save-RipperUpdateBackup',
        'Invoke-RipperUpdateApply',
        'Remove-RipperOldUpdateBackups'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
