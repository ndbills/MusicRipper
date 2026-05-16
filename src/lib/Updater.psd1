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
        'Remove-RipperOldUpdateBackups',
        # v0.2.4: pure-function helpers exercised by the WPF dialogs.
        # Pulled out so Pester can unit-test the data decisions that
        # caused the v0.1.1/v0.2.0 visibility + notes-text bugs.
        'Get-RipperReleaseIndexUrl',
        'Get-RipperAccurateRipDatabaseUrl',
        'Test-RipperReleaseHasViewButton',
        'Get-RipperReleaseNotesText',
        'Copy-RipperUpdaterBootstrap'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
