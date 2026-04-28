#requires -Version 7.0
#requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

<#
    Pester tests for src/sync/Invoke-LibraryRetention.ps1 (Phase 6.1).
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
    . (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')
    . (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
    . (Join-Path $repoRoot 'src\sync\Invoke-LibraryRetention.ps1')

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("retention-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

    function script:New-FakeAlbum {
        param([string]$Lib, [string]$Artist, [string]$Album)
        $p = Join-Path (Join-Path $Lib $Artist) $Album
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $p 'placeholder.txt') -Value 'x' -NoNewline
        $p
    }

    function script:New-Cfg {
        param([string]$Mode)
        [pscustomobject]@{ LocalRetention = $Mode }
    }

    function script:New-SyncResult {
        param([bool]$AllOk = $true, [bool]$Skipped = $false, [string[]]$FailedTargets = @())
        $targets = @()
        foreach ($t in $FailedTargets) { $targets += @{ Target=$t; Status='Failed' } }
        if ($AllOk -and -not $Skipped) { $targets += @{ Target='Stub'; Status='OK' } }
        @{ AlbumPath='ignored'; Targets=$targets; AllOk=$AllOk; Skipped=$Skipped }
    }

    Start-RipperLog -Context 'retention-tests' | Out-Null
}

AfterAll {
    Stop-RipperLog
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RipperLibraryRetention (no-op paths)' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
        $script:alb = New-FakeAlbum $script:lib 'A' 'B'
    }

    It 'returns Action=None when LocalRetention=Keep' {
        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config (New-Cfg 'Keep') -SyncResult (New-SyncResult)
        $r.Action | Should -Be 'None'
        Test-Path -LiteralPath $script:alb | Should -BeTrue

        # And the no-op outcome is persisted, so an operator can tell
        # \"considered, kept on purpose\" apart from \"never reached
        # retention\".
        $e = Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb
        $e.RetentionApplied.Action | Should -Be 'Keep'
        $e.RetentionApplied.Reason | Should -Be 'LocalRetention=Keep'
    }

    It 'returns None when LocalRetention is missing entirely' {
        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config ([pscustomobject]@{ Foo='bar' }) -SyncResult (New-SyncResult)
        $r.Action | Should -Be 'None'
    }

    It 'returns None when SyncResult.Skipped (no targets configured)' {
        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config (New-Cfg 'MoveToSentAfterAllSynced') -SyncResult (New-SyncResult -Skipped $true -AllOk $true)
        $r.Action | Should -Be 'None'
        Test-Path -LiteralPath $script:alb | Should -BeTrue
        # Skipped means \"this user isn't using sync\" -- we deliberately
        # do NOT materialise a sync-state entry just to record nothing.
        Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb | Should -BeNullOrEmpty
    }

    It 'returns None when any target failed' {
        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config (New-Cfg 'MoveToSentAfterAllSynced') -SyncResult (New-SyncResult -AllOk $false -FailedTargets @('OneDrive'))
        $r.Action | Should -Be 'None'
        $r.Reason | Should -Match 'OneDrive'
        Test-Path -LiteralPath $script:alb | Should -BeTrue

        $e = Get-RipperLibrarySyncStateEntry -LibraryRoot $script:lib -AlbumPath $script:alb
        $e.RetentionApplied.Action | Should -Be 'KeepTargetsNotOk'
        $e.RetentionApplied.Reason | Should -Match 'OneDrive'
    }

    It 'returns None and warns on unknown mode' {
        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config (New-Cfg 'BogusMode') -SyncResult (New-SyncResult)
        $r.Action | Should -Be 'None'
    }
}

Describe 'Invoke-RipperLibraryRetention (MoveToSentAfterAllSynced)' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
        $script:alb = New-FakeAlbum $script:lib 'Foo Fighters' 'Wasting Light (2011)'
    }

    It 'moves the folder to LibraryRoot _Sent on success' {
        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config (New-Cfg 'MoveToSentAfterAllSynced') -SyncResult (New-SyncResult) -DiscId 'discA'
        $r.Action  | Should -Be 'MovedToSent'
        $r.NewPath | Should -Be (Join-Path $script:lib '_Sent\Foo Fighters\Wasting Light (2011)')
        Test-Path -LiteralPath $script:alb     | Should -BeFalse
        Test-Path -LiteralPath $r.NewPath      | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $r.NewPath 'placeholder.txt') | Should -BeTrue
    }

    It 'records RetentionApplied on the sync-state entry' {
        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config (New-Cfg 'MoveToSentAfterAllSynced') -SyncResult (New-SyncResult) -DiscId 'discA'

        # The entry was keyed against the ORIGINAL path; read it directly.
        $idx   = Get-RipperLibrarySyncState -LibraryRoot $script:lib
        $key   = 'Foo Fighters/Wasting Light (2011)'
        $entry = $idx[$key]
        $entry.RetentionApplied.Action  | Should -Be 'MoveToSentAfterAllSynced'
        $entry.RetentionApplied.NewPath | Should -Be $r.NewPath
    }

    It 'side-by-sides into _Sent on collision' {
        # First move
        Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
            -Config (New-Cfg 'MoveToSentAfterAllSynced') -SyncResult (New-SyncResult) -DiscId 'd1' | Out-Null
        # Re-create the album under the original name
        $alb2 = New-FakeAlbum $script:lib 'Foo Fighters' 'Wasting Light (2011)'
        $r2 = Invoke-RipperLibraryRetention -AlbumPath $alb2 -LibraryRoot $script:lib `
                -Config (New-Cfg 'MoveToSentAfterAllSynced') -SyncResult (New-SyncResult) -DiscId 'd2'
        $r2.NewPath | Should -Match '\[moved 2\]$'
        Test-Path -LiteralPath $r2.NewPath | Should -BeTrue
    }

    It 'rewrites the discids.json entry to the new _Sent path' {
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'discA' `
            -Path $script:alb -Label 'Foo Fighters - Wasting Light (2011)' -Source 'library'

        $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                -Config (New-Cfg 'MoveToSentAfterAllSynced') -SyncResult (New-SyncResult) -DiscId 'discA'

        $idx = Get-RipperLibraryDiscIndex -LibraryRoot $script:lib
        $idx['discA'].Path   | Should -Be $r.NewPath
        $idx['discA'].Source | Should -Be 'sent'
    }
}

Describe 'Invoke-RipperLibraryRetention (RecycleAfterAllSynced)' {
    BeforeEach {
        $script:lib = Join-Path $script:tmpRoot ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:lib -Force | Out-Null
        $script:alb = New-FakeAlbum $script:lib 'Pink Floyd' 'The Wall (1979)'
    }

    It 'recycles the folder and marks the discids.json entry Source=recycled' {
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'discR' `
            -Path $script:alb -Label 'Pink Floyd - The Wall (1979)' -Source 'library'

        # Stub Move-RipperFolderToRecycleBin so we don't touch the real
        # Recycle Bin from the test runner. The retention layer only
        # cares that the helper was invoked and the album path no
        # longer exists on disk.
        function global:Move-RipperFolderToRecycleBin {
            param([Parameter(Mandatory)] [string] $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        try {
            $r = Invoke-RipperLibraryRetention -AlbumPath $script:alb -LibraryRoot $script:lib `
                    -Config (New-Cfg 'RecycleAfterAllSynced') -SyncResult (New-SyncResult) -DiscId 'discR'
        } finally {
            Remove-Item -LiteralPath function:Move-RipperFolderToRecycleBin
        }

        $r.Action | Should -Be 'Recycled'
        Test-Path -LiteralPath $script:alb | Should -BeFalse

        $idx = Get-RipperLibraryDiscIndex -LibraryRoot $script:lib
        $idx.ContainsKey('discR')  | Should -BeTrue
        $idx['discR'].Source       | Should -Be 'recycled'
        $idx['discR'].Label        | Should -Be 'Pink Floyd - The Wall (1979)'
    }

    It 'Find-RipperLibraryDiscIndexEntry surfaces recycled entries even though their path is gone' {
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'discR2' `
            -Path (Join-Path $script:lib 'Phantom\Album') -Label 'Phantom - Album' -Source 'recycled'
        $entry = Find-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'discR2'
        $entry           | Should -Not -BeNullOrEmpty
        $entry.Source    | Should -Be 'recycled'
    }

    It 'Find-RipperLibraryDiscIndexEntry still returns null for a stale library entry' {
        Add-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'discS' `
            -Path (Join-Path $script:lib 'Phantom\Album') -Label 'Phantom - Album' -Source 'library'
        Find-RipperLibraryDiscIndexEntry -LibraryRoot $script:lib -DiscId 'discS' | Should -BeNullOrEmpty
    }
}
