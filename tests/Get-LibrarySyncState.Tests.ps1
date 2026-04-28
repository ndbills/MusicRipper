#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
    Pester tests for src/sync/Get-LibrarySyncState.ps1 (Phase 6.1).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    . (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("syncstate-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

    function script:New-FakeAlbum {
        param([string]$Lib, [string]$Artist, [string]$Album)
        $p = Join-Path (Join-Path $Lib $Artist) $Album
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        $p
    }

    Start-RipperLog -Context 'syncstate-tests' | Out-Null
}

AfterAll {
    Stop-RipperLog
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RipperLibrarySyncStatePath' {
    It 'composes the .musicripper sync-state.json path' {
        Get-RipperLibrarySyncStatePath -LibraryRoot 'C:\lib' | Should -Be 'C:\lib\.musicripper\sync-state.json'
    }
}

Describe 'ConvertTo-RipperLibraryRelativeKey' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
    }

    It 'normalizes album path to forward-slash key' {
        $alb = New-FakeAlbum $script:lib 'Foo Fighters' 'Wasting Light (2011)'
        ConvertTo-RipperLibraryRelativeKey -LibraryRoot $script:lib -AlbumPath $alb |
            Should -Be 'Foo Fighters/Wasting Light (2011)'
    }

    It 'throws when album is not under library root' {
        $other = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        { ConvertTo-RipperLibraryRelativeKey -LibraryRoot $script:lib -AlbumPath $other } |
            Should -Throw '*not under LibraryRoot*'
    }
}

Describe 'Get-RipperLibrarySyncState (read paths)' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
    }

    It 'returns empty hashtable when missing' {
        (Get-RipperLibrarySyncState -LibraryRoot $script:lib).Count | Should -Be 0
    }

    It 'returns empty hashtable on corrupt JSON (logged WARN, not thrown)' {
        $idxDir = Join-Path $script:lib '.musicripper'
        New-Item -ItemType Directory -Path $idxDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $idxDir 'sync-state.json') -Value '{ this is not json' -NoNewline
        (Get-RipperLibrarySyncState -LibraryRoot $script:lib).Count | Should -Be 0
    }
}

Describe 'Set-RipperLibrarySyncTargetResult round-trip' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
        $script:alb = New-FakeAlbum $script:lib 'Foo Fighters' 'Wasting Light (2011)'
    }

    It 'creates a new entry on first call' {
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'discA' -Result @{ Target='Stub'; Status='OK'; BytesCopied=42; Diagnostic=$null }

        $entry = Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb
        $entry              | Should -Not -BeNullOrEmpty
        $entry.DiscId       | Should -Be 'discA'
        $entry.Targets.Stub.Status      | Should -Be 'OK'
        $entry.Targets.Stub.BytesCopied | Should -Be 42
        $entry.Targets.Stub.SyncedAt    | Should -Not -BeNullOrEmpty
    }

    It 'overwrites the same target on subsequent runs and preserves DiscId/FirstSeenAt' {
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'discA' -Result @{ Target='Stub'; Status='Failed'; BytesCopied=0; Diagnostic='nope' }
        $first = Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb
        Start-Sleep -Milliseconds 5
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'discA' -Result @{ Target='Stub'; Status='OK'; BytesCopied=99; Diagnostic=$null }
        $second = Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb

        $second.FirstSeenAt        | Should -Be $first.FirstSeenAt
        $second.Targets.Stub.Status      | Should -Be 'OK'
        $second.Targets.Stub.BytesCopied | Should -Be 99
        $second.Targets.Stub.Diagnostic  | Should -BeNullOrEmpty
    }

    It 'merges multiple targets into the same entry' {
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'discA' -Result @{ Target='Stub'; Status='OK'; BytesCopied=1; Diagnostic=$null }
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'discA' -Result @{ Target='OneDrive'; Status='Failed'; BytesCopied=0; Diagnostic='offline' }

        $entry = Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb
        $entry.Targets.PSObject.Properties.Name | Sort-Object | Should -Be @('OneDrive','Stub')
    }
}

Describe 'Test-RipperLibraryAllTargetsOk' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
        $script:alb = New-FakeAlbum $script:lib 'A' 'B'
    }

    It 'returns false when no entry exists' {
        Test-RipperLibraryAllTargetsOk -LibraryRoot $script:lib -AlbumPath $script:alb -RequiredTargets @('Stub') |
            Should -BeFalse
    }

    It 'returns true only when every required target is OK' {
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'd' -Result @{ Target='Stub'; Status='OK'; BytesCopied=1; Diagnostic=$null }
        Test-RipperLibraryAllTargetsOk -LibraryRoot $script:lib -AlbumPath $script:alb -RequiredTargets @('Stub') |
            Should -BeTrue
        Test-RipperLibraryAllTargetsOk -LibraryRoot $script:lib -AlbumPath $script:alb -RequiredTargets @('Stub','OneDrive') |
            Should -BeFalse
    }

    It 'returns false when any target is non-OK' {
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'd' -Result @{ Target='Stub'; Status='OK'; BytesCopied=1; Diagnostic=$null }
        Set-RipperLibrarySyncTargetResult -LibraryRoot $script:lib -AlbumPath $script:alb `
            -DiscId 'd' -Result @{ Target='OneDrive'; Status='Failed'; BytesCopied=0; Diagnostic='x' }
        Test-RipperLibraryAllTargetsOk -LibraryRoot $script:lib -AlbumPath $script:alb -RequiredTargets @('Stub','OneDrive') |
            Should -BeFalse
    }
}

Describe 'Set-RipperLibraryRetentionApplied' {
    It 'records the retention action on the entry' {
        $lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        $alb = New-FakeAlbum $lib 'A' 'B'
        Set-RipperLibrarySyncTargetResult -LibraryRoot $lib -AlbumPath $alb `
            -DiscId 'd' -Result @{ Target='Stub'; Status='OK'; BytesCopied=1; Diagnostic=$null }

        Set-RipperLibraryRetentionApplied -LibraryRoot $lib -AlbumPath $alb `
            -Action 'MoveToSentAfterAllSynced' -NewPath 'D:\sent\B'

        $e = Get-RipperLibrarySyncStateEntry -LibraryRoot $lib -AlbumPath $alb
        $e.RetentionApplied            | Should -Not -BeNullOrEmpty
        $e.RetentionApplied.Action     | Should -Be 'MoveToSentAfterAllSynced'
        $e.RetentionApplied.NewPath    | Should -Be 'D:\sent\B'
        $e.RetentionApplied.AppliedAt  | Should -Not -BeNullOrEmpty
    }
}
