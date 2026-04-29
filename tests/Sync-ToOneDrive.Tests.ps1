#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
    Pester tests for src/sync/Sync-ToOneDrive.ps1 (Phase 6.2).
    Exercises both pure helpers (exit-code -> Status; bytes parser)
    and the integration path (Invoke-RipperSyncToOneDrive against a
    plain local folder pretending to be the OneDrive root -- robocopy
    doesn't care that it isn't really OneDrive, so we get full
    coverage without touching the cloud).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    . (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
    . (Join-Path $repoRoot 'src\sync\Sync-ToOneDrive.ps1')

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("onedrive-tests-" + [guid]::NewGuid())
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

    Start-RipperLog -Context 'onedrive-tests' | Out-Null
}

AfterAll {
    Stop-RipperLog
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RipperOneDriveStatusFromExitCode' {
    It 'maps 0 (nothing copied) to OK' {
        (Get-RipperOneDriveStatusFromExitCode -ExitCode 0).Status | Should -Be 'OK'
    }
    It 'maps 1 (files copied) to OK' {
        (Get-RipperOneDriveStatusFromExitCode -ExitCode 1).Status | Should -Be 'OK'
    }
    It 'maps 7 (copied + extras + mismatches) to OK' {
        (Get-RipperOneDriveStatusFromExitCode -ExitCode 7).Status | Should -Be 'OK'
    }
    It 'maps 8 (copy failure) to Failed with diagnostic' {
        $r = Get-RipperOneDriveStatusFromExitCode -ExitCode 8
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'failed to copy'
    }
    It 'maps 16 (fatal) to Failed with diagnostic' {
        $r = Get-RipperOneDriveStatusFromExitCode -ExitCode 16
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'fatal'
    }
    It 'maps -1 (could not run) to Failed' {
        (Get-RipperOneDriveStatusFromExitCode -ExitCode -1).Status | Should -Be 'Failed'
    }
}

Describe 'Get-RipperOneDriveBytesCopied' {
    It 'extracts the Copied column from a /BYTES summary line' {
        $output = @(
            '   Speed :            12345 Bytes/sec.',
            '   Bytes :       324521000        324521000             0             0             0             0',
            '   Files :              12               12             0             0             0             0'
        )
        Get-RipperOneDriveBytesCopied -Output $output | Should -Be 324521000
    }
    It 'returns 0 when no Bytes line is present' {
        Get-RipperOneDriveBytesCopied -Output @('nothing useful here') | Should -Be 0
    }
}

Describe 'Invoke-RipperSyncToOneDrive (pre-flight)' {

    BeforeEach {
        # Pretend OneDrive is installed -- pre-flight 1 always passes
        # so we can exercise pre-flight 2 (OneDriveSyncTargetRoot).
        Mock Get-RipperOneDriveUserFolder { Join-Path $script:tmpRoot 'fake-onedrive-root' }
    }

    It 'fails fast when OneDrive client is not installed' {
        Mock Get-RipperOneDriveUserFolder { $null }
        $lib = New-Lib
        $alb = New-FakeAlbum $lib 'A' 'B'
        $cfg = [pscustomobject]@{ OneDriveSyncTargetRoot = (New-Lib) }
        $r = Invoke-RipperSyncToOneDrive -AlbumPath $alb -LibraryRoot $lib -Config $cfg
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'OneDrive client'
    }

    It 'fails fast when OneDriveSyncTargetRoot is unset' {
        $lib = New-Lib
        $alb = New-FakeAlbum $lib 'A' 'B'
        $cfg = [pscustomobject]@{ }
        $r = Invoke-RipperSyncToOneDrive -AlbumPath $alb -LibraryRoot $lib -Config $cfg
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'OneDriveSyncTargetRoot'
    }

    It 'fails fast when OneDriveSyncTargetRoot points at a missing folder' {
        $lib = New-Lib
        $alb = New-FakeAlbum $lib 'A' 'B'
        $missing = Join-Path $script:tmpRoot ([guid]::NewGuid())
        $cfg = [pscustomobject]@{ OneDriveSyncTargetRoot = $missing }
        $r = Invoke-RipperSyncToOneDrive -AlbumPath $alb -LibraryRoot $lib -Config $cfg
        $r.Status     | Should -Be 'Failed'
        $r.Diagnostic | Should -Match 'does not exist'
    }
}

Describe 'Invoke-RipperSyncToOneDrive (integration via robocopy)' {

    BeforeEach {
        # Same pretend-installed mock; the real test is robocopy.
        Mock Get-RipperOneDriveUserFolder { Join-Path $script:tmpRoot 'fake-onedrive-root' }
    }

    # We don't really copy to OneDrive in the test -- we copy to a
    # plain temp folder that pretends to be the OneDrive root.
    # Robocopy doesn't care about the cloud client; this exercises
    # the full pre-flight + invoke + parse path.

    It 'copies the album folder, returns OK + BytesCopied' {
        $lib  = New-Lib
        $alb  = New-FakeAlbum $lib 'Foo' 'Bar (2026)'
        $root = New-Lib
        $cfg  = [pscustomobject]@{ OneDriveSyncTargetRoot = $root }

        $r = Invoke-RipperSyncToOneDrive -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status      | Should -Be 'OK'
        $r.Target      | Should -Be 'OneDrive'
        $r.BytesCopied | Should -BeGreaterThan 0
        Test-Path -LiteralPath (Join-Path $root 'Foo\Bar (2026)\01.flac') | Should -BeTrue
    }

    It 'is idempotent on a re-run (returns OK with 0 bytes copied)' {
        $lib  = New-Lib
        $alb  = New-FakeAlbum $lib 'Foo' 'Bar'
        $root = New-Lib
        $cfg  = [pscustomobject]@{ OneDriveSyncTargetRoot = $root }

        Invoke-RipperSyncToOneDrive -AlbumPath $alb -LibraryRoot $lib -Config $cfg | Out-Null
        $r = Invoke-RipperSyncToOneDrive -AlbumPath $alb -LibraryRoot $lib -Config $cfg

        $r.Status      | Should -Be 'OK'
        $r.BytesCopied | Should -Be 0
    }
}
