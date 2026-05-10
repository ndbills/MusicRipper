@{
    RootModule        = 'DriveRegistration.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd6e7f8a9-1b2c-3d4e-5f60-7a8b9c0d1e2f'
    Author            = 'MusicRipper'
    Description       = 'Optical-drive enumeration + AccurateRip offset lookup helpers.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Get-RipperOpticalDrives', 'Find-RipperAccurateRipOffset', 'Find-RipperAccurateRipEntry', 'ConvertTo-RipperDriveNameKey')
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
