<#
    Pester tests for src/tools/Move-FromReviewQueue.ps1.

    Three layers:
      1. Resolve-RipperReviewSourceMetadata : pure helper, fed by a
         scriptblock-injected tag reader (no metaflac.exe needed).
      2. Get-RipperReviewPromotionPlan      : pure file-classification
         + target-folder planner (no disk I/O).
      3. End-to-end : dot-source the script, mock Get-MetaflacPath +
         Read-RipperFlacTagValue, mock Add-RipperLibraryDiscIndexEntry,
         and exercise the move on a temp directory.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    # Dot-source the tool so its functions land in scope. The script's
    # parameter block uses Mandatory on $AlbumFolder, but the bottom-
    # of-script main flow is guarded by a "$MyInvocation.InvocationName
    # -eq '.'" check, so the helpers are published without running the
    # promote workflow.
    . (Join-Path $repoRoot 'src\tools\Move-FromReviewQueue.ps1') -ErrorAction SilentlyContinue
}

Describe 'Resolve-RipperReviewSourceMetadata' {
    It 'reads ALBUMARTIST + ALBUM + DATE + COMPILATION + DISCID off track-1' {
        $tags = @{
            'C:\fake.flac' = @{
                ALBUMARTIST         = 'Pink Floyd'
                ALBUM               = 'The Dark Side of the Moon'
                DATE                = '1973-03-01'
                COMPILATION         = '0'
                MUSICBRAINZ_DISCID  = 'abc123'
            }
        }
        $reader = { param($f, $n) $tags[$f][$n] }
        $md = Resolve-RipperReviewSourceMetadata -FirstFlac 'C:\fake.flac' -ReadTag $reader
        $md.AlbumArtist   | Should -Be 'Pink Floyd'
        $md.Album         | Should -Be 'The Dark Side of the Moon'
        $md.Year          | Should -Be 1973
        $md.IsCompilation | Should -Be $false
        $md.DiscId        | Should -Be 'abc123'
        $md.TotalDiscs    | Should -Be 1
    }

    It 'falls back to ARTIST when ALBUMARTIST is missing' {
        $tags = @{ 'F' = @{ ARTIST = 'Solo Artist'; ALBUM = 'Solo Album' } }
        $reader = { param($f, $n) $tags[$f][$n] }
        $md = Resolve-RipperReviewSourceMetadata -FirstFlac 'F' -ReadTag $reader
        $md.AlbumArtist | Should -Be 'Solo Artist'
    }

    It 'parses YEAR fallback when DATE is missing' {
        $tags = @{ 'F' = @{ ALBUMARTIST='X'; ALBUM='Y'; YEAR='1999' } }
        $reader = { param($f, $n) $tags[$f][$n] }
        (Resolve-RipperReviewSourceMetadata -FirstFlac 'F' -ReadTag $reader).Year | Should -Be 1999
    }

    It 'auto-detects compilation when AlbumArtist is Various Artists' {
        $tags = @{ 'F' = @{ ALBUMARTIST='Various Artists'; ALBUM='Hits' } }
        $reader = { param($f, $n) $tags[$f][$n] }
        $md = Resolve-RipperReviewSourceMetadata -FirstFlac 'F' -ReadTag $reader
        $md.IsCompilation | Should -Be $true
    }

    It 'honours -OverrideAlbumArtist / -OverrideAlbum / -OverrideYear / -OverrideIsCompilation' {
        $tags = @{ 'F' = @{ ALBUMARTIST='Wrong'; ALBUM='Wrong'; DATE='1999'; COMPILATION='0' } }
        $reader = { param($f, $n) $tags[$f][$n] }
        $md = Resolve-RipperReviewSourceMetadata -FirstFlac 'F' -ReadTag $reader `
                  -OverrideAlbumArtist 'Right' -OverrideAlbum 'Right Album' `
                  -OverrideYear 2020 -OverrideIsCompilation $true
        $md.AlbumArtist   | Should -Be 'Right'
        $md.Album         | Should -Be 'Right Album'
        $md.Year          | Should -Be 2020
        $md.IsCompilation | Should -Be $true
    }

    It 'reads COMPILATION=1 from Picard-style boolean' {
        $tags = @{ 'F' = @{ ALBUMARTIST='Various Artists'; ALBUM='Hits'; COMPILATION='1' } }
        $reader = { param($f, $n) $tags[$f][$n] }
        (Resolve-RipperReviewSourceMetadata -FirstFlac 'F' -ReadTag $reader).IsCompilation |
            Should -Be $true
    }
}

Describe 'Get-RipperReviewPromotionPlan' {
    BeforeEach {
        $script:libRoot = Join-Path $TestDrive 'lib'
        $script:src     = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Path $script:libRoot, $script:src -Force | Out-Null

        $script:md = [pscustomobject]@{
            AlbumArtist   = 'Pink Floyd'
            Album         = 'The Wall'
            Year          = 1979
            IsCompilation = $false
            TotalDiscs    = 1
        }

        # File entries the planner classifies. Stub PSIsContainer +
        # Name + FullName -- that's the contract Get-RipperReviewPromotionPlan
        # uses (no real Get-Item needed for unit tests).
        function script:NewEntry([string]$Name, [bool]$IsContainer = $false) {
            [pscustomobject]@{
                Name         = $Name
                FullName     = Join-Path $script:src $Name
                PSIsContainer = $IsContainer
            }
        }
    }

    It 'routes library content under LibraryRoot then Artist then Album-with-year' {
        $entries = @(
            (NewEntry '01 - In the Flesh.flac'),
            (NewEntry '02 - The Thin Ice.flac'),
            (NewEntry 'cover.jpg'),
            (NewEntry 'The Wall.cue'),
            (NewEntry 'The Wall.log'),
            (NewEntry 'REVIEW.txt'),
            (NewEntry '_image' $true)
        )
        $plan = Get-RipperReviewPromotionPlan `
                    -SourceFolder $script:src -LibraryRoot $script:libRoot `
                    -Metadata $script:md -DiscId 'abc' -SourceEntries $entries
        $plan.Target  | Should -Be (Join-Path $script:libRoot 'Pink Floyd\The Wall (1979)')
        ($plan.Move    | ForEach-Object Name) | Should -Contain '01 - In the Flesh.flac'
        ($plan.Move    | ForEach-Object Name) | Should -Contain 'cover.jpg'
        ($plan.Move    | ForEach-Object Name) | Should -Contain 'The Wall.cue'
        ($plan.Move    | ForEach-Object Name) | Should -Contain 'The Wall.log'
        ($plan.Discard | ForEach-Object Name) | Should -Contain 'REVIEW.txt'
        ($plan.Discard | ForEach-Object Name) | Should -Contain '_image'
    }

    It 'routes compilations under Various Artists' {
        $script:md.IsCompilation = $true
        $script:md.AlbumArtist   = 'Various Artists'
        $script:md.Album         = 'Now 99'
        $script:md.Year          = 2018
        $plan = Get-RipperReviewPromotionPlan `
                    -SourceFolder $script:src -LibraryRoot $script:libRoot `
                    -Metadata $script:md -DiscId 'd' -SourceEntries @((NewEntry '01.flac'))
        $plan.Target | Should -Be (Join-Path $script:libRoot 'Various Artists\Now 99 (2018)')
    }

    It 'omits the year suffix when Year is 0' {
        $script:md.Year = 0
        $plan = Get-RipperReviewPromotionPlan `
                    -SourceFolder $script:src -LibraryRoot $script:libRoot `
                    -Metadata $script:md -DiscId 'd' -SourceEntries @((NewEntry '01.flac'))
        $plan.Target | Should -Be (Join-Path $script:libRoot 'Pink Floyd\The Wall')
    }

    It 'moves REVIEW.txt + _image when -KeepReviewArtifacts is set' {
        $entries = @((NewEntry 'REVIEW.txt'), (NewEntry '_image' $true), (NewEntry '01.flac'))
        $plan = Get-RipperReviewPromotionPlan `
                    -SourceFolder $script:src -LibraryRoot $script:libRoot `
                    -Metadata $script:md -DiscId 'd' -SourceEntries $entries -KeepReviewArtifacts
        ($plan.Move    | ForEach-Object Name) | Should -Contain 'REVIEW.txt'
        ($plan.Move    | ForEach-Object Name) | Should -Contain '_image'
        $plan.Discard.Count | Should -Be 0
    }

    It 'always discards *-dispatcher.log sidecars' {
        $entries = @((NewEntry '01.flac'), (NewEntry 'metadata-dispatcher.log'))
        $plan = Get-RipperReviewPromotionPlan `
                    -SourceFolder $script:src -LibraryRoot $script:libRoot `
                    -Metadata $script:md -DiscId 'd' -SourceEntries $entries
        ($plan.Discard | ForEach-Object Name) | Should -Contain 'metadata-dispatcher.log'
    }

    It 'preserves unknown subfolders (parent dropped a Picard side-folder)' {
        $entries = @((NewEntry '01.flac'), (NewEntry 'PicardScratch' $true))
        $plan = Get-RipperReviewPromotionPlan `
                    -SourceFolder $script:src -LibraryRoot $script:libRoot `
                    -Metadata $script:md -DiscId 'd' -SourceEntries $entries
        ($plan.Move    | ForEach-Object Name) | Should -Contain 'PicardScratch'
        $plan.Discard.Count | Should -Be 0
    }
}

Describe 'Read-RipperReviewTxtDiscId' {
    It 'returns the DiscId line' {
        $p = Join-Path $TestDrive 'r1.txt'
        Set-Content -LiteralPath $p -Value @"
Reason:           SUSPECT - bad rip
DiscId:           XXY-12345
MusicBrainzMatch: none
"@ -Encoding UTF8
        Read-RipperReviewTxtDiscId -ReviewTxtPath $p | Should -Be 'XXY-12345'
    }
    It 'returns null when DiscId is "none"' {
        $p = Join-Path $TestDrive 'r2.txt'
        Set-Content -LiteralPath $p -Value "DiscId: none`r`n" -Encoding UTF8
        Read-RipperReviewTxtDiscId -ReviewTxtPath $p | Should -BeNullOrEmpty
    }
    It 'returns null when REVIEW.txt is missing' {
        Read-RipperReviewTxtDiscId -ReviewTxtPath (Join-Path $TestDrive 'no-such.txt') |
            Should -BeNullOrEmpty
    }
}

Describe 'Move-FromReviewQueue end-to-end' {
    BeforeEach {
        # Pester 5 does NOT auto-clean TestDrive between It blocks within
        # a Describe -- only between Describe blocks. Per-It uniqueness via
        # New-Guid sidesteps file/folder collisions.
        $script:caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:libRoot = Join-Path $script:caseDir 'library'
        $script:src     = Join-Path $script:libRoot '_ReviewQueue\UNKNOWN - 2026-04-12 - 12tracks 51m23s - abc123'
        New-Item -ItemType Directory -Path $script:src -Force | Out-Null

        foreach ($f in @('01 - In the Flesh.flac', '02 - The Thin Ice.flac',
                         'cover.jpg', 'The Wall.cue', 'The Wall.log')) {
            New-Item -ItemType File -Path (Join-Path $script:src $f) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:src 'REVIEW.txt') `
            -Value "Reason: UNKNOWN - no MusicBrainz match`r`nDiscId: abc123`r`n"
        New-Item -ItemType Directory -Path (Join-Path $script:src '_image') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:src '_image\The Wall.flac') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:src '_image\The Wall.cue') -Force | Out-Null
    }

    It 'promotes a tagged review-queue folder into the library tree' {
        # Mock metaflac path + tag reads. fakeTags is embedded inside the
        # Mock body because $script:* set in an `It` is not visible in a
        # Mock scriptblock (per /memories/powershell.md gotcha).
        Mock -CommandName Get-MetaflacPath -MockWith { 'C:\fake\metaflac.exe' } `
            -ModuleName Common
        Mock -CommandName Read-RipperFlacTagValue -MockWith {
            (@{ ALBUMARTIST='Pink Floyd'; ALBUM='The Wall';
               DATE='1979-11-30'; COMPILATION='0';
               MUSICBRAINZ_DISCID='abc123' })[$Name]
        }
        # Don't actually write to discids.json.
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith {}
        # metaflac.exe path Test-Path check:
        Mock -CommandName Test-Path -MockWith { $true } -ParameterFilter {
            $LiteralPath -eq 'C:\fake\metaflac.exe'
        }

        $result = & (Join-Path $repoRoot 'src\tools\Move-FromReviewQueue.ps1') `
                      -AlbumFolder $script:src -LibraryRoot $script:libRoot

        $expected = Join-Path $script:libRoot 'Pink Floyd\The Wall (1979)'
        $result.Target        | Should -Be $expected
        $result.AlbumArtist   | Should -Be 'Pink Floyd'
        $result.Album         | Should -Be 'The Wall'
        $result.Year          | Should -Be 1979
        $result.IsCompilation | Should -Be $false
        $result.DiscId        | Should -Be 'abc123'
        $result.DiscIdSeeded  | Should -Be $true
        $result.IsSideBySide  | Should -Be $false

        # Library content moved.
        Test-Path -LiteralPath (Join-Path $expected '01 - In the Flesh.flac') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $expected 'cover.jpg')              | Should -Be $true
        Test-Path -LiteralPath (Join-Path $expected 'The Wall.cue')           | Should -Be $true
        Test-Path -LiteralPath (Join-Path $expected 'The Wall.log')           | Should -Be $true

        # Review artifacts discarded (NOT in target, NOT in source).
        Test-Path -LiteralPath (Join-Path $expected 'REVIEW.txt') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $expected '_image')     | Should -Be $false

        # Source folder cleaned up.
        Test-Path -LiteralPath $script:src | Should -Be $false

        # discids.json seeded.
        Should -Invoke Add-RipperLibraryDiscIndexEntry -Times 1 -Exactly `
            -ParameterFilter { $DiscId -eq 'abc123' -and $Path -eq $expected }
    }

    It 'lands side-by-side under bracket-rip-2 when target exists and -AllowSideBySide is set' {
        Mock -CommandName Get-MetaflacPath -MockWith { 'C:\fake\metaflac.exe' } -ModuleName Common
        Mock -CommandName Read-RipperFlacTagValue -MockWith {
            (@{ ALBUMARTIST='Pink Floyd'; ALBUM='The Wall';
               DATE='1979-11-30'; COMPILATION='0';
               MUSICBRAINZ_DISCID='abc123' })[$Name]
        }
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith {}
        Mock -CommandName Test-Path -MockWith { $true } -ParameterFilter {
            $LiteralPath -eq 'C:\fake\metaflac.exe'
        }

        # Pre-create the target so the side-by-side path fires.
        $existing = Join-Path $script:libRoot 'Pink Floyd\The Wall (1979)'
        New-Item -ItemType Directory -Path $existing -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $existing '01 - existing.flac') | Out-Null

        $result = & (Join-Path $repoRoot 'src\tools\Move-FromReviewQueue.ps1') `
                      -AlbumFolder $script:src -LibraryRoot $script:libRoot -AllowSideBySide

        $result.IsSideBySide | Should -Be $true
        $result.Target       | Should -Be (Join-Path $script:libRoot 'Pink Floyd\The Wall (1979) [rip 2]')
        Test-Path -LiteralPath $result.Target | Should -Be $true
    }

    It 'throws when no FLACs are present in the source folder root' {
        Mock -CommandName Get-MetaflacPath -MockWith { 'C:\fake\metaflac.exe' } -ModuleName Common
        Mock -CommandName Test-Path -MockWith { $true } -ParameterFilter {
            $LiteralPath -eq 'C:\fake\metaflac.exe'
        }
        $empty = Join-Path $TestDrive 'empty-rq'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        { & (Join-Path $repoRoot 'src\tools\Move-FromReviewQueue.ps1') `
              -AlbumFolder $empty -LibraryRoot $script:libRoot } |
            Should -Throw '*No *.flac files*'
    }

    It '-WhatIf reports the planned move without touching disk' {
        Mock -CommandName Get-MetaflacPath -MockWith { 'C:\fake\metaflac.exe' } -ModuleName Common
        Mock -CommandName Read-RipperFlacTagValue -MockWith {
            (@{ ALBUMARTIST='Pink Floyd'; ALBUM='The Wall';
               DATE='1979-11-30'; COMPILATION='0';
               MUSICBRAINZ_DISCID='abc123' })[$Name]
        }
        Mock -CommandName Add-RipperLibraryDiscIndexEntry -MockWith {}
        Mock -CommandName Test-Path -MockWith { $true } -ParameterFilter {
            $LiteralPath -eq 'C:\fake\metaflac.exe'
        }

        $result = & (Join-Path $repoRoot 'src\tools\Move-FromReviewQueue.ps1') `
                      -AlbumFolder $script:src -LibraryRoot $script:libRoot -WhatIf

        $result.WhatIf      | Should -Be $true
        # Source folder + every original file still present.
        Test-Path -LiteralPath $script:src                         | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:src 'REVIEW.txt') | Should -Be $true
        Test-Path -LiteralPath $result.Target                       | Should -Be $false
        Should -Invoke Add-RipperLibraryDiscIndexEntry -Times 0 -Exactly
    }
}
