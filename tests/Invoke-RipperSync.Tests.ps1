#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
    Pester tests for src/sync/Invoke-RipperSync.ps1 (Phase 6.1).

    Exercises the orchestrator end-to-end via the built-in Stub target,
    plus failure-path coverage for unknown targets and target throws.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    . (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
    . (Join-Path $repoRoot 'src\sync\Invoke-RipperSync.ps1')

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("syncorch-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

    function script:New-FakeAlbumWithFile {
        param([string]$Lib, [string]$Artist, [string]$Album, [int]$ByteCount = 8)
        $p = Join-Path (Join-Path $Lib $Artist) $Album
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        $bytes = [byte[]]::new($ByteCount)
        [System.IO.File]::WriteAllBytes((Join-Path $p 'track01.flac'), $bytes)
        $p
    }

    function script:New-Cfg {
        param([string[]]$Targets, [bool]$StubFail = $false)
        [pscustomobject]@{ SyncTargets = $Targets; StubSyncFail = $StubFail }
    }

    Start-RipperLog -Context 'syncorch-tests' | Out-Null
}

AfterAll {
    Stop-RipperLog
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RipperSync (no targets)' {
    It 'returns Skipped=true / AllOk=true when SyncTargets empty' {
        $lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        $alb = New-FakeAlbumWithFile $lib 'A' 'B'

        $r = Invoke-RipperSync -AlbumPath $alb -LibraryRoot $lib -DiscId 'd' -Config (New-Cfg @())
        $r.Skipped | Should -BeTrue
        $r.AllOk   | Should -BeTrue
        $r.Targets.Count | Should -Be 0
    }

    It 'returns Skipped=true when SyncTargets property is missing' {
        $lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        $alb = New-FakeAlbumWithFile $lib 'A' 'B'
        $cfg = [pscustomobject]@{ Foo = 'bar' }

        $r = Invoke-RipperSync -AlbumPath $alb -LibraryRoot $lib -DiscId 'd' -Config $cfg
        $r.Skipped | Should -BeTrue
    }
}

Describe 'Invoke-RipperSync (Stub target happy path)' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
        $script:alb = New-FakeAlbumWithFile $script:lib 'Foo Fighters' 'Wasting Light (2011)' 16
    }

    It 'invokes Stub, returns AllOk and writes a marker file' {
        $r = Invoke-RipperSync -AlbumPath $script:alb -LibraryRoot $script:lib -DiscId 'discA' `
                -Config (New-Cfg @('Stub'))

        $r.Skipped              | Should -BeFalse
        $r.AllOk                | Should -BeTrue
        $r.Targets.Count        | Should -Be 1
        $r.Targets[0].Target    | Should -Be 'Stub'
        $r.Targets[0].Status    | Should -Be 'OK'
        $r.Targets[0].BytesCopied | Should -BeGreaterOrEqual 16

        $marker = Join-Path (Join-Path $script:lib '.musicripper\stub-sync\Foo Fighters\Wasting Light (2011)') '.synced'
        Test-Path -LiteralPath $marker | Should -BeTrue
    }

    It 'persists per-target result to sync-state.json' {
        Invoke-RipperSync -AlbumPath $script:alb -LibraryRoot $script:lib -DiscId 'discA' `
            -Config (New-Cfg @('Stub')) | Out-Null

        $entry = Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb
        $entry                    | Should -Not -BeNullOrEmpty
        $entry.DiscId             | Should -Be 'discA'
        $entry.Targets.Stub.Status | Should -Be 'OK'
    }
}

Describe 'Invoke-RipperSync (failure paths)' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
        $script:alb = New-FakeAlbumWithFile $script:lib 'A' 'B'
    }

    It 'reports Failed for Stub when StubSyncFail=true' {
        $r = Invoke-RipperSync -AlbumPath $script:alb -LibraryRoot $script:lib -DiscId 'd' `
                -Config (New-Cfg -Targets @('Stub') -StubFail $true)
        $r.AllOk             | Should -BeFalse
        $r.Targets[0].Status | Should -Be 'Failed'
    }

    It 'reports Failed for an unknown target name without throwing' {
        $r = Invoke-RipperSync -AlbumPath $script:alb -LibraryRoot $script:lib -DiscId 'd' `
                -Config (New-Cfg @('Bogus'))
        $r.AllOk             | Should -BeFalse
        $r.Targets[0].Target | Should -Be 'Bogus'
        $r.Targets[0].Status | Should -Be 'Failed'
        $r.Targets[0].Diagnostic | Should -Match 'Unknown sync target'
    }

    It 'continues to remaining targets after one fails' {
        $r = Invoke-RipperSync -AlbumPath $script:alb -LibraryRoot $script:lib -DiscId 'd' `
                -Config (New-Cfg @('Bogus','Stub'))
        $r.Targets.Count     | Should -Be 2
        $r.Targets[0].Status | Should -Be 'Failed'
        $r.Targets[1].Status | Should -Be 'OK'
        $r.AllOk             | Should -BeFalse
    }

    It 'catches a target that throws and reports it as Failed' {
        function global:Invoke-RipperSyncToBoom {
            param($AlbumPath,$LibraryRoot,$Config)
            throw 'kaboom'
        }
        try {
            $r = Invoke-RipperSync -AlbumPath $script:alb -LibraryRoot $script:lib -DiscId 'd' `
                    -Config (New-Cfg @('Boom'))
            $r.Targets[0].Status     | Should -Be 'Failed'
            $r.Targets[0].Diagnostic | Should -Be 'kaboom'
        } finally {
            Remove-Item function:\Invoke-RipperSyncToBoom -ErrorAction SilentlyContinue
        }
    }
}
