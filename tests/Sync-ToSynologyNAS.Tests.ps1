#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
    Pester tests for src/sync/Sync-ToSynologyNAS.ps1 (Phase 6.3).

    Strategy: Sync-ToSynologyNAS skips the SMB mount step entirely
    when the configured SynologyUnc is a local (non-UNC) path. Tests
    therefore exercise the full pre-flight + robocopy + parse path
    against a plain local folder pretending to be the share, which
    matches the approach taken by Sync-ToOneDrive.Tests.ps1.

    SMB-mount-specific behaviour (New-SmbMapping success / failure,
    UNC-path parsing, Remove-SmbMapping in the finally block) is
    covered with mocks where the cmdlet would otherwise need a real
    file server.
#>

# Discovery-time check: Pester evaluates -Skip when it walks the file
# (before BeforeAll runs), so the SmbShare presence test has to live
# at the top level. We also can't use $script:-scope for the flag --
# Pester 5 isolates discovery's script scope from Run phase, so the
# value evaluates as $null when the -Skip expression re-runs in Run.
# A plain $hasSmb local in the file's top-level scope is captured by
# the Describe's -Skip expression at discovery, frozen as a literal
# bool, and survives into Run.
$hasSmb = $null -ne (Get-Module -ListAvailable -Name SmbShare)

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
    . (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
    # Sync-ToSynologyNAS re-uses two pure helpers from Sync-ToOneDrive
    # (exit-code -> Status, /BYTES line parser) -- dot-source it first.
    . (Join-Path $repoRoot 'src\sync\Sync-ToOneDrive.ps1')
    . (Join-Path $repoRoot 'src\sync\Sync-ToSynologyNAS.ps1')

    if (Get-Module -ListAvailable -Name SmbShare) { Import-Module SmbShare -ErrorAction SilentlyContinue }

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("synology-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

    function script:New-Lib {
        $lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        $lib
    }

    function script:New-FakeAlbum {
        param([string]$Lib, [string]$Artist, [string]$Album)
        $p = Join-Path (Join-Path $Lib $Artist) $Album
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $p '01.flac') -Value 'fake-flac-bytes' -NoNewline
        Set-Content -LiteralPath (Join-Path $p 'album.cue') -Value 'cue' -NoNewline
        $p
    }

    Start-RipperLog -Context 'synology-tests' | Out-Null
}

AfterAll {
    Stop-RipperLog
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-RipperUncPath' {
    It 'recognises \\server\share' {
        Test-RipperUncPath -Path '\\nas\music' | Should -BeTrue
    }
    It 'recognises //server/share (forward-slash form)' {
        Test-RipperUncPath -Path '//nas/music' | Should -BeTrue
    }
    It 'rejects a local drive-letter path' {
        Test-RipperUncPath -Path 'C:\foo\bar' | Should -BeFalse
    }
}

Describe 'Get-RipperSynologyShareRoot' {
    It 'returns the share root for a deeper UNC' {
        Get-RipperSynologyShareRoot -Path '\\nas\music\backups\rips' | Should -Be '\\nas\music'
    }
    It 'returns the path unchanged when it is already a share root' {
        Get-RipperSynologyShareRoot -Path '\\nas\music' | Should -Be '\\nas\music'
    }
    It 'normalises forward-slash UNC to backslash' {
        Get-RipperSynologyShareRoot -Path '//nas/music/sub' | Should -Be '\\nas\music'
    }
    It 'returns $null for a non-UNC path' {
        Get-RipperSynologyShareRoot -Path 'C:\foo' | Should -BeNullOrEmpty
    }
    It 'returns $null for a UNC missing the share segment' {
        Get-RipperSynologyShareRoot -Path '\\nas' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-RipperSyncToSynologyNAS (pre-flight)' {

    It 'fails fast when SynologyUnc is unset' {
        $lib = New-Lib
        $alb = New-FakeAlbum $lib 'A' 'B'
        $cfg = [pscustomobject]@{ }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg
        $r.Status     | Should -Be 'Failed'
        $r.Target     | Should -Be 'SynologyNAS'
        $r.Diagnostic | Should -Match 'SynologyUnc'
    }

    It 'fails fast when the configured root is unreachable' {
        $lib = New-Lib
        $alb = New-FakeAlbum $lib 'A' 'B'
        $missing = Join-Path $script:tmpRoot ([guid]::NewGuid())
        $cfg = [pscustomobject]@{ SynologyUnc = $missing; HasSynologyCredential = $false }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'not reachable'
    }

    It 'fails fast when HasSynologyCredential=true but Import-RipperCredential returns $null' {
        Mock Import-RipperCredential { $null }
        $lib = New-Lib
        $alb = New-FakeAlbum $lib 'A' 'B'
        # A reachable local path so that pre-flight 1 passes; the test
        # is asserting that pre-flight 2 (cred) fails first.
        $share = New-Lib
        $cfg = [pscustomobject]@{ SynologyUnc = $share; HasSynologyCredential = $true }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'credentials.clixml'
    }
}

Describe 'Invoke-RipperSyncToSynologyNAS (integration via robocopy, no SMB mount)' {

    # Tests use a plain local folder as the "share". Sync-ToSynologyNAS
    # detects this is not a UNC and skips New-SmbMapping entirely.

    It 'copies the album folder, returns OK + BytesCopied' {
        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar (2026)'
        $share = New-Lib
        $cfg   = [pscustomobject]@{ SynologyUnc = $share; HasSynologyCredential = $false }

        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status      | Should -Be 'OK'
        $r.Target      | Should -Be 'SynologyNAS'
        $r.BytesCopied | Should -BeGreaterThan 0
        Test-Path -LiteralPath (Join-Path $share 'Foo\Bar (2026)\01.flac') | Should -BeTrue
    }

    It 'is idempotent on a re-run (returns OK with 0 bytes copied)' {
        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar'
        $share = New-Lib
        $cfg   = [pscustomobject]@{ SynologyUnc = $share; HasSynologyCredential = $false }

        Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg | Out-Null
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status      | Should -Be 'OK'
        $r.BytesCopied | Should -Be 0
    }
}

Describe 'Test-RipperSynologyDirectReachable (Phase 6.4.2)' {

    It 'returns $false for a non-UNC path without throwing or probing' {
        # If the implementation accidentally hit Test-Connection on a
        # local path, this would throw or hang -- the early-return on
        # Test-RipperUncPath avoids both.
        Test-RipperSynologyDirectReachable -Unc 'C:\foo\bar' | Should -BeFalse
    }

    It 'returns $false for an empty / malformed UNC' {
        Test-RipperSynologyDirectReachable -Unc '\\nas' | Should -BeFalse
    }

    It 'returns $false (does not throw) when the host is unreachable' {
        # Use a guaranteed-unroutable hostname so DNS / TCP fails fast.
        # If this test ever blocks for >5s, the timeout knob is broken.
        $r = Test-RipperSynologyDirectReachable `
            -Unc            '\\musicripper-test-host-does-not-exist.invalid\share' `
            -TimeoutSeconds 1
        $r | Should -BeFalse
    }
}

Describe 'Invoke-RipperSyncToSynologyNAS (Phase 6.4.2 direct-first WG gate)' {

    # Tests for the direct-first reachability gate. We mock the WG ref
    # helpers + the reachability probe so we exercise the gate logic
    # without needing a real WireGuard service or NAS. We use a local
    # folder as the "share" so the SMB-mount path is skipped (same
    # idiom as the integration tests above). NB: this Describe runs
    # BEFORE the SMB-mount-path Describe below specifically because the
    # latter creates a `function global:robocopy { ... }` per It -- if
    # those tests crash mid-flight the stub leaks into subsequent
    # Describes and the real robocopy never runs.

    It 'skips Add-RipperVpnTunnelRef when the share is reachable directly' {
        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar'
        $share = New-Lib

        Mock Test-RipperSynologyDirectReachable { $true }
        Mock Add-RipperVpnTunnelRef             { $true }
        Mock Remove-RipperVpnTunnelRef          { $true }
        Mock Enable-RipperVpnTunnelSessionKeepAlive { $true }

        $cfg = [pscustomobject]@{
            SynologyUnc                    = $share
            HasSynologyCredential          = $false
            WireGuardAutoToggle            = $true
            WireGuardTunnelName            = 'home-wg'
            WireGuardKeepAliveBetweenDiscs = $false
            PreferDirectNasConnection      = $true
        }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status | Should -Be 'OK'
        Should -Invoke Test-RipperSynologyDirectReachable -Times 1 -Exactly
        Should -Invoke Add-RipperVpnTunnelRef             -Times 0 -Exactly
        Should -Invoke Remove-RipperVpnTunnelRef          -Times 0 -Exactly
    }

    It 'falls back to Add-RipperVpnTunnelRef when the share is NOT reachable directly' {
        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar'
        $share = New-Lib

        Mock Test-RipperSynologyDirectReachable { $false }
        Mock Add-RipperVpnTunnelRef             { $true }
        Mock Remove-RipperVpnTunnelRef          { $true }
        Mock Enable-RipperVpnTunnelSessionKeepAlive { $true }

        $cfg = [pscustomobject]@{
            SynologyUnc                    = $share
            HasSynologyCredential          = $false
            WireGuardAutoToggle            = $true
            WireGuardTunnelName            = 'home-wg'
            WireGuardKeepAliveBetweenDiscs = $false
            PreferDirectNasConnection      = $true
        }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status | Should -Be 'OK'
        Should -Invoke Test-RipperSynologyDirectReachable -Times 1 -Exactly
        Should -Invoke Add-RipperVpnTunnelRef             -Times 1 -Exactly
        Should -Invoke Remove-RipperVpnTunnelRef          -Times 1 -Exactly
    }

    It 'does NOT probe (and acquires the tunnel) when PreferDirectNasConnection is false' {
        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar'
        $share = New-Lib

        Mock Test-RipperSynologyDirectReachable { $true }   # would say "skip" if asked
        Mock Add-RipperVpnTunnelRef             { $true }
        Mock Remove-RipperVpnTunnelRef          { $true }
        Mock Enable-RipperVpnTunnelSessionKeepAlive { $true }

        $cfg = [pscustomobject]@{
            SynologyUnc                    = $share
            HasSynologyCredential          = $false
            WireGuardAutoToggle            = $true
            WireGuardTunnelName            = 'home-wg'
            WireGuardKeepAliveBetweenDiscs = $false
            PreferDirectNasConnection      = $false
        }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status | Should -Be 'OK'
        Should -Invoke Test-RipperSynologyDirectReachable -Times 0 -Exactly
        Should -Invoke Add-RipperVpnTunnelRef             -Times 1 -Exactly
        Should -Invoke Remove-RipperVpnTunnelRef          -Times 1 -Exactly
    }

    It 'does NOT probe when WireGuardAutoToggle is off (probe is irrelevant)' {
        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar'
        $share = New-Lib

        Mock Test-RipperSynologyDirectReachable { $true }
        Mock Add-RipperVpnTunnelRef             { $true }
        Mock Remove-RipperVpnTunnelRef          { $true }

        $cfg = [pscustomobject]@{
            SynologyUnc               = $share
            HasSynologyCredential     = $false
            WireGuardAutoToggle       = $false
            WireGuardTunnelName       = 'home-wg'
            PreferDirectNasConnection = $true
        }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status | Should -Be 'OK'
        Should -Invoke Test-RipperSynologyDirectReachable -Times 0 -Exactly
        Should -Invoke Add-RipperVpnTunnelRef             -Times 0 -Exactly
    }
}

Describe 'Invoke-RipperSyncToSynologyNAS (SMB mount path, mocked)' -Skip:(-not $hasSmb) {

    BeforeEach {
        # A real PSCredential -- we never network with it; the New-SmbMapping
        # mock just receives it as an opaque object.
        $sec  = ConvertTo-SecureString 'pw' -AsPlainText -Force
        $script:fakeCred = [pscredential]::new('pi', $sec)
        Mock Import-RipperCredential { $script:fakeCred }
    }

    It 'mounts the share root, runs robocopy, then unmounts in finally (success path)' {
        # Robocopy needs a real reachable destination; we route the
        # "UNC" through a local folder via a Test-Path mock + a
        # destination-rewriting trick below.
        # Easier path: just mock New-SmbMapping + Remove-SmbMapping +
        # robocopy by intercepting via a dummy share that resolves to a
        # local folder. We assert the mount/unmount happened without
        # really going to the network.

        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar'
        $share = New-Lib  # local folder we'll pretend is the SMB share

        Mock New-SmbMapping {
            # Record the mount call for the assertion below.
            $script:mountedAs = $UserName
            $script:mountedAt = $RemotePath
            return @{ RemotePath = $RemotePath; LocalPath = $null; Status = 'OK' }
        } -ParameterFilter { $RemotePath -eq '\\nas\music' }

        Mock Remove-SmbMapping {
            $script:unmountedAt = $RemotePath
        } -ParameterFilter { $RemotePath -eq '\\nas\music' }

        # We can't actually let robocopy try \\nas\music. Mock the
        # Test-Path that gates pre-flight + the robocopy invocation
        # itself: have Test-Path return $true for the UNC, and have
        # robocopy's wrapper write into the local $share folder via a
        # path-substitution shim. This is enough to assert the
        # mount/unmount lifecycle without standing up a real share.
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq '\\nas\music' -or $LiteralPath -like '\\nas\music\*' }

        # Replace the robocopy invocation with a no-op that returns a
        # success-shaped /BYTES summary so the parsers come back OK.
        Mock Invoke-Expression { } # unused; left for safety
        # The function calls `& robocopy @rcArgs`. We override `robocopy`
        # in this scope only.
        function global:robocopy {
            $script:LASTEXITCODE = 1   # 1 = files copied successfully
            return @(
                '   Speed :            12345 Bytes/sec.',
                '   Bytes :       100        100             0             0             0             0',
                '   Files :         1          1             0             0             0             0'
            )
        }

        try {
            $cfg = [pscustomobject]@{ SynologyUnc = '\\nas\music'; HasSynologyCredential = $true }
            $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

            $r.Status              | Should -Be 'OK'
            $script:mountedAt      | Should -Be '\\nas\music'
            $script:mountedAs      | Should -Be 'pi'
            $script:unmountedAt    | Should -Be '\\nas\music'
        } finally {
            Remove-Item function:\robocopy -ErrorAction SilentlyContinue
        }
    }

    It 'still unmounts when robocopy reports a fatal error' {
        $lib   = New-Lib
        $alb   = New-FakeAlbum $lib 'Foo' 'Bar'

        $script:unmountedAt = $null
        Mock New-SmbMapping {
            return @{ RemotePath = $RemotePath }
        } -ParameterFilter { $RemotePath -eq '\\nas\music' }
        Mock Remove-SmbMapping {
            $script:unmountedAt = $RemotePath
        } -ParameterFilter { $RemotePath -eq '\\nas\music' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq '\\nas\music' -or $LiteralPath -like '\\nas\music\*' }

        function global:robocopy {
            $script:LASTEXITCODE = 16   # fatal
            return @('ERROR : Destination unreachable.')
        }

        try {
            $cfg = [pscustomobject]@{ SynologyUnc = '\\nas\music'; HasSynologyCredential = $true }
            $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

            $r.Status           | Should -Be 'Failed'
            $r.Diagnostic       | Should -Match 'fatal'
            $script:unmountedAt | Should -Be '\\nas\music'
        } finally {
            Remove-Item function:\robocopy -ErrorAction SilentlyContinue
        }
    }

    It 'returns Failed (and does NOT call Remove-SmbMapping) when New-SmbMapping itself throws' {
        $lib = New-Lib
        $alb = New-FakeAlbum $lib 'Foo' 'Bar'

        Mock New-SmbMapping { throw 'access denied' } -ParameterFilter { $RemotePath -eq '\\nas\music' }
        Mock Remove-SmbMapping { } -ParameterFilter { $RemotePath -eq '\\nas\music' }

        $cfg = [pscustomobject]@{ SynologyUnc = '\\nas\music'; HasSynologyCredential = $true }
        $r = Invoke-RipperSyncToSynologyNAS -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'access denied'
        Should -Invoke Remove-SmbMapping -Times 0 -Exactly
    }
}
