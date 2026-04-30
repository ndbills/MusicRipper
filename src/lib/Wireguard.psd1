@{
    RootModule        = 'Wireguard.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b41a8d7e-2c4f-4a6e-9d31-7f9c8e5b1a02'
    Author            = 'MusicRipper'
    Description       = 'Phase 6.4: idempotent helpers around the WireGuard for Windows tunnel-service control plane.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Test-RipperVpnTunnel',
        'Start-RipperVpnTunnel',
        'Stop-RipperVpnTunnel',
        'Install-RipperVpnTunnel',
        'Uninstall-RipperVpnTunnel',
        'Grant-RipperVpnTunnelControl',
        'Get-RipperVpnTunnelServiceName',
        'Use-RipperVpnTunnel',
        'Add-RipperVpnTunnelRef',
        'Remove-RipperVpnTunnelRef',
        'Get-RipperVpnTunnelRefState',
        'Enable-RipperVpnTunnelSessionKeepAlive',
        'Disable-RipperVpnTunnelSessionKeepAlive'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
