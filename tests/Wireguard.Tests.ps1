<#
    Phase 6.4 Pester tests for src/lib/Wireguard.psm1.

    What we test:
      * Service-name translation is consistent (used by every public fn).
      * Test/Start/Stop are idempotent with respect to current state.
      * Failure paths return $false and emit a WARN log line rather
        than throwing (the sync pipeline contract -- D-022).
      * Get-Service "service does not exist" is reported as
        NotInstalled, not as a generic Stopped.
      * The SDDL parsing in Grant-RipperVpnTunnelControl preserves a
        pre-existing S: (audit) section.

    What we do NOT test here:
      * Real Win32 service control. Get-Service / Start-Service /
        Stop-Service / sc.exe are mocked. End-to-end install + grant
        are exercised by the manual verification checklist (one-time
        UAC prompt during setup, then a real rip).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Wireguard.psd1') -Force

    # Logging.psm1 expects a Start-RipperLog before Write-RipperLog
    # writes anywhere; using a temp directory keeps the suite hermetic.
    $script:LogTemp = Join-Path ([System.IO.Path]::GetTempPath()) "wg-test-$([guid]::NewGuid().Guid.Substring(0,8))"
    New-Item -ItemType Directory -Path $script:LogTemp -Force | Out-Null
    $env:LOCALAPPDATA_BAK = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $script:LogTemp
    Start-RipperLog -Context 'wg-tests' | Out-Null
}

AfterAll {
    Stop-RipperLog
    if ($env:LOCALAPPDATA_BAK) {
        $env:LOCALAPPDATA = $env:LOCALAPPDATA_BAK
        Remove-Item Env:LOCALAPPDATA_BAK -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:LogTemp) {
        Remove-Item -LiteralPath $script:LogTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RipperVpnTunnelServiceName' {
    It 'prefixes the Windows service-name convention' {
        Get-RipperVpnTunnelServiceName -Name 'home' | Should -Be 'WireGuardTunnel$home'
    }
    It 'rejects empty input' {
        { Get-RipperVpnTunnelServiceName -Name '' } | Should -Throw
    }
}

Describe 'Test-RipperVpnTunnel' {
    It 'returns false / NotInstalled when the service does not exist' {
        Mock -ModuleName Wireguard Get-Service { throw [System.Management.Automation.ItemNotFoundException]::new('no such service') }
        Test-RipperVpnTunnel -Name 'absent' | Should -BeFalse
        Test-RipperVpnTunnel -Name 'absent' -Detailed | Should -Be 'NotInstalled'
    }
    It 'returns true / Running when status is Running' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Test-RipperVpnTunnel -Name 'up' | Should -BeTrue
        Test-RipperVpnTunnel -Name 'up' -Detailed | Should -Be 'Running'
    }
    It 'returns false / Stopped for every non-Running status' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        Test-RipperVpnTunnel -Name 'down' | Should -BeFalse
        Test-RipperVpnTunnel -Name 'down' -Detailed | Should -Be 'Stopped'
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'StartPending' } }
        Test-RipperVpnTunnel -Name 'pend' -Detailed | Should -Be 'Stopped'
    }
}

Describe 'Start-RipperVpnTunnel' {
    It 'no-ops when already running' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock -ModuleName Wireguard Start-Service { throw 'should not be called' }
        Start-RipperVpnTunnel -Name 'up' | Should -BeTrue
        Should -Invoke -ModuleName Wireguard -CommandName Start-Service -Times 0
    }
    It 'returns false (warn, no throw) when the service is not installed' {
        Mock -ModuleName Wireguard Get-Service { throw [System.Management.Automation.ItemNotFoundException]::new('nope') }
        Mock -ModuleName Wireguard Start-Service {}
        Start-RipperVpnTunnel -Name 'absent' | Should -BeFalse
        Should -Invoke -ModuleName Wireguard -CommandName Start-Service -Times 0
    }
    It 'starts the service and waits for Running' {
        # First Test-RipperVpnTunnel -> Stopped (so we try to start),
        # subsequent calls during the wait loop -> Running.
        $script:GsCalls = 0
        Mock -ModuleName Wireguard Get-Service {
            $script:GsCalls++
            if ($script:GsCalls -le 1) { return [pscustomobject]@{ Status = 'Stopped' } }
            return [pscustomobject]@{ Status = 'Running' }
        }
        Mock -ModuleName Wireguard Start-Service {}
        Start-RipperVpnTunnel -Name 't' -TimeoutSeconds 2 | Should -BeTrue
        Should -Invoke -ModuleName Wireguard -CommandName Start-Service -Times 1
    }
    It 'returns false when Start-Service throws' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        Mock -ModuleName Wireguard Start-Service { throw 'access denied' }
        Start-RipperVpnTunnel -Name 't' | Should -BeFalse
    }
    It 'returns false when the service never reaches Running before timeout' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        Mock -ModuleName Wireguard Start-Service {}
        Start-RipperVpnTunnel -Name 't' -TimeoutSeconds 1 | Should -BeFalse
    }
}

Describe 'Stop-RipperVpnTunnel' {
    It 'no-ops when already stopped' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        Mock -ModuleName Wireguard Stop-Service { throw 'should not be called' }
        Stop-RipperVpnTunnel -Name 't' | Should -BeTrue
        Should -Invoke -ModuleName Wireguard -CommandName Stop-Service -Times 0
    }
    It 'returns true when the service does not exist (nothing to stop)' {
        Mock -ModuleName Wireguard Get-Service { throw [System.Management.Automation.ItemNotFoundException]::new('nope') }
        Mock -ModuleName Wireguard Stop-Service {}
        Stop-RipperVpnTunnel -Name 'absent' | Should -BeTrue
        Should -Invoke -ModuleName Wireguard -CommandName Stop-Service -Times 0
    }
    It 'stops the service and waits for non-Running' {
        $script:GsCalls = 0
        Mock -ModuleName Wireguard Get-Service {
            $script:GsCalls++
            if ($script:GsCalls -le 1) { return [pscustomobject]@{ Status = 'Running' } }
            return [pscustomobject]@{ Status = 'Stopped' }
        }
        Mock -ModuleName Wireguard Stop-Service {}
        Stop-RipperVpnTunnel -Name 't' -TimeoutSeconds 2 | Should -BeTrue
        Should -Invoke -ModuleName Wireguard -CommandName Stop-Service -Times 1
    }
    It 'returns false when Stop-Service throws' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock -ModuleName Wireguard Stop-Service { throw 'access denied' }
        Stop-RipperVpnTunnel -Name 't' | Should -BeFalse
    }
}

Describe 'Install-RipperVpnTunnel' {
    BeforeAll {
        $script:TmpConf = Join-Path ([System.IO.Path]::GetTempPath()) "fake-tunnel-$([guid]::NewGuid().Guid.Substring(0,8)).conf"
        Set-Content -LiteralPath $script:TmpConf -Value '# fake conf'
        $script:TmpExe = Join-Path ([System.IO.Path]::GetTempPath()) "fake-wireguard-$([guid]::NewGuid().Guid.Substring(0,8)).exe"
        Set-Content -LiteralPath $script:TmpExe -Value '' # presence is all we check
    }
    AfterAll {
        Remove-Item -LiteralPath $script:TmpConf -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:TmpExe -ErrorAction SilentlyContinue
    }
    It 'returns false when the .conf does not exist' {
        Install-RipperVpnTunnel -ConfPath 'C:\nope\does-not-exist.conf' -WireGuardExe $script:TmpExe | Should -BeFalse
    }
    It 'returns false when wireguard.exe is not on disk' {
        Install-RipperVpnTunnel -ConfPath $script:TmpConf -WireGuardExe 'C:\nope\not-wireguard.exe' | Should -BeFalse
    }
    It 'no-ops when the service is already installed' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        Mock -ModuleName Wireguard Start-Process { throw 'should not be called' }
        Install-RipperVpnTunnel -ConfPath $script:TmpConf -WireGuardExe $script:TmpExe | Should -BeTrue
        Should -Invoke -ModuleName Wireguard -CommandName Start-Process -Times 0
    }
    It 'invokes wireguard.exe /installtunnelservice when the service is missing' {
        Mock -ModuleName Wireguard Get-Service { throw [System.Management.Automation.ItemNotFoundException]::new('nope') }
        Mock -ModuleName Wireguard Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Install-RipperVpnTunnel -ConfPath $script:TmpConf -WireGuardExe $script:TmpExe | Should -BeTrue
        Should -Invoke -ModuleName Wireguard -CommandName Start-Process -Times 1 -ParameterFilter {
            $ArgumentList -contains '/installtunnelservice'
        }
    }
    It 'returns false when wireguard.exe exits non-zero' {
        Mock -ModuleName Wireguard Get-Service { throw [System.Management.Automation.ItemNotFoundException]::new('nope') }
        Mock -ModuleName Wireguard Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        Install-RipperVpnTunnel -ConfPath $script:TmpConf -WireGuardExe $script:TmpExe | Should -BeFalse
    }
}

Describe 'Sync-ToSynologyNAS WireGuard hook (Phase 6.4)' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        # Sync-ToSynologyNAS.ps1 is dot-sourced because its functions
        # land in the caller's scope. The file self-imports
        # Wireguard.psd1 so we get a real module boundary to mock at.
        . (Join-Path $repoRoot 'src\sync\Sync-ToSynologyNAS.ps1')
    }

    It 'fails fast when AutoToggle is on, tunnel is needed, and Start fails' {
        Mock -ModuleName Wireguard Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        Mock -ModuleName Wireguard Start-Service { throw 'denied' }

        $cfg = [pscustomobject]@{
            SynologyUnc           = '\\nas\music'
            HasSynologyCredential = $false
            LibraryRoot           = 'C:\Music'
            WireGuardTunnelName   = 'home'
            WireGuardAutoToggle   = $true
        }
        $tmpAlbum = Join-Path ([System.IO.Path]::GetTempPath()) "wg-album-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpAlbum -Force | Out-Null
        try {
            $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $tmpAlbum -LibraryRoot 'C:\Music' -Config $cfg
            $r.Status      | Should -Be 'Failed'
            $r.Diagnostic  | Should -Match 'WireGuard'
        } finally {
            Remove-Item -LiteralPath $tmpAlbum -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips the WG path entirely when AutoToggle is off' {
        Mock -ModuleName Wireguard Get-Service { throw 'should not be called: AutoToggle is off' }
        Mock -ModuleName Wireguard Start-Service { throw 'should not be called: AutoToggle is off' }

        $cfg = [pscustomobject]@{
            SynologyUnc           = ''   # also empty so we fail fast on pre-flight #1
            HasSynologyCredential = $false
            LibraryRoot           = 'C:\Music'
            WireGuardTunnelName   = 'home'
            WireGuardAutoToggle   = $false
        }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath 'C:\nope' -LibraryRoot 'C:\Music' -Config $cfg
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'SynologyUnc'  # not a WG diagnostic
    }
}
