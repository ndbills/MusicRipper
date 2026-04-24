<#
    Pester tests for src/core/Move-ToLibrary.ps1.

    Pure-logic helpers (Format-RipperDuration, New-RipperReviewQueueFolderName,
    Get-RipperLibraryTargetDir) lock in the layout rules from plan.md
    Phase 5 §3. The Move-RipToLibrary integration tests use a temp
    directory so we exercise the real Move-Item path including the
    multi-disc fan-out logic.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\Move-ToLibrary.ps1')

    function script:New-FakeQuality([string]$Prefix = '') {
        [pscustomobject]@{ RoutingPrefix = $Prefix; Status = 'Verified' }
    }

    function script:New-FakeMetadata {
        param([switch]$Compilation, [switch]$NoYear, [int]$TotalDiscs = 1, [int]$DiscNumber = 1)
        [pscustomobject]@{
            AlbumArtist   = 'Mormon Tabernacle Choir'
            Album         = 'Spirit of the Season'
            Year          = $(if ($NoYear) { $null } else { 2007 })
            DiscNumber    = $DiscNumber
            TotalDiscs    = $TotalDiscs
            IsCompilation = [bool]$Compilation
            Tracks        = @(
                [pscustomobject]@{ Number=1; Title='Carol of the Bells' },
                [pscustomobject]@{ Number=2; Title='Silent Night' }
            )
        }
    }

    function script:Seed-RipFolder([string]$Path) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        '01 - Carol of the Bells.flac','02 - Silent Night.flac' |
            ForEach-Object { New-Item -ItemType File -Path (Join-Path $Path $_) | Out-Null }
        New-Item -ItemType File -Path (Join-Path $Path 'cover.jpg') | Out-Null
        New-Item -ItemType File -Path (Join-Path $Path 'Spirit of the Season.cue') | Out-Null
        New-Item -ItemType File -Path (Join-Path $Path 'Spirit of the Season.log') | Out-Null
    }
}

Describe 'Format-RipperDuration' {
    It 'formats whole minutes' {
        Format-RipperDuration -TotalSeconds 60   | Should -Be '1m00s'
        Format-RipperDuration -TotalSeconds 600  | Should -Be '10m00s'
        Format-RipperDuration -TotalSeconds 3600 | Should -Be '60m00s'
    }
    It 'formats with seconds' {
        Format-RipperDuration -TotalSeconds 90   | Should -Be '1m30s'
        Format-RipperDuration -TotalSeconds 75   | Should -Be '1m15s'
    }
    It 'returns 0m00s on zero / negative / unset' {
        Format-RipperDuration -TotalSeconds 0    | Should -Be '0m00s'
        Format-RipperDuration -TotalSeconds -10  | Should -Be '0m00s'
        Format-RipperDuration                    | Should -Be '0m00s'
    }
}

Describe 'New-RipperReviewQueueFolderName' {
    It 'builds SUSPECT - Artist - Album - DiscId' {
        $name = New-RipperReviewQueueFolderName -Prefix SUSPECT -DiscId 'abc123' `
                    -Metadata (New-FakeMetadata)
        $name | Should -Be 'SUSPECT - Mormon Tabernacle Choir - Spirit of the Season - abc123'
    }

    It 'builds LOWMATCH and MANUAL with the same Artist/Album/DiscId shape' {
        (New-RipperReviewQueueFolderName -Prefix LOWMATCH -DiscId 'd' -Metadata (New-FakeMetadata)) |
            Should -BeLike 'LOWMATCH - *'
        (New-RipperReviewQueueFolderName -Prefix MANUAL   -DiscId 'd' -Metadata (New-FakeMetadata)) |
            Should -BeLike 'MANUAL - *'
    }

    It 'builds UNKNOWN with date + tracks + duration + DiscId (no artist/album)' {
        $name = New-RipperReviewQueueFolderName -Prefix UNKNOWN -DiscId 'abc' `
                    -RipDate '2026-04-21' -TrackCount 12 -TotalSeconds 2400
        $name | Should -Be 'UNKNOWN - 2026-04-21 - 12tracks 40m00s - abc'
    }

    It 'sanitizes illegal Windows path chars in artist / album / discid' {
        $md = New-FakeMetadata
        $md.AlbumArtist = 'AC/DC'
        $md.Album       = 'High:Voltage?'
        $name = New-RipperReviewQueueFolderName -Prefix SUSPECT -DiscId 'abc|123' -Metadata $md
        $name | Should -Not -Match '[<>:"/\\|?*]'
        $name | Should -BeLike 'SUSPECT - AC DC - High Voltage*'
    }

    It 'throws when SUSPECT/LOWMATCH/MANUAL is requested without metadata' {
        { New-RipperReviewQueueFolderName -Prefix SUSPECT -DiscId 'abc' } |
            Should -Throw '*Metadata is required*'
    }

    It 'rejects unknown prefixes' {
        { New-RipperReviewQueueFolderName -Prefix BOGUS -DiscId 'd' } | Should -Throw
    }
}

Describe 'Get-RipperLibraryTargetDir' {
    It 'main library: LibraryRoot/AlbumArtist/Album (Year)' {
        $dir = Get-RipperLibraryTargetDir -LibraryRoot 'D:\Music' `
                  -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd'
        $dir | Should -Be 'D:\Music\Mormon Tabernacle Choir\Spirit of the Season (2007)'
    }

    It 'compilation: routes under "Various Artists" regardless of AlbumArtist' {
        $dir = Get-RipperLibraryTargetDir -LibraryRoot 'D:\Music' `
                  -Metadata (New-FakeMetadata -Compilation) -Quality (New-FakeQuality) -DiscId 'd'
        $dir | Should -Be 'D:\Music\Various Artists\Spirit of the Season (2007)'
    }

    It 'omits the (Year) suffix when Year is missing' {
        $dir = Get-RipperLibraryTargetDir -LibraryRoot 'D:\Music' `
                  -Metadata (New-FakeMetadata -NoYear) -Quality (New-FakeQuality) -DiscId 'd'
        $dir | Should -Be 'D:\Music\Mormon Tabernacle Choir\Spirit of the Season'
    }

    It 'sanitizes illegal Windows chars in AlbumArtist / Album' {
        $md = New-FakeMetadata
        $md.AlbumArtist = 'AC/DC'
        $md.Album       = 'High:Voltage'
        $dir = Get-RipperLibraryTargetDir -LibraryRoot 'D:\Music' `
                  -Metadata $md -Quality (New-FakeQuality) -DiscId 'd'
        $dir | Should -Be 'D:\Music\AC DC\High Voltage (2007)'
    }

    It 'returns multi-disc albums at album-root (caller fans into Disc N)' {
        # The planner returns the album dir even for multi-disc; per-track
        # fan-out into Disc N\ is the mover's job.
        $dir = Get-RipperLibraryTargetDir -LibraryRoot 'D:\Music' `
                  -Metadata (New-FakeMetadata -TotalDiscs 2 -DiscNumber 1) `
                  -Quality (New-FakeQuality) -DiscId 'd'
        $dir | Should -Be 'D:\Music\Mormon Tabernacle Choir\Spirit of the Season (2007)'
    }

    It 'review queue: SUSPECT routes under _ReviewQueue with descriptor folder' {
        $dir = Get-RipperLibraryTargetDir -LibraryRoot 'D:\Music' `
                  -Metadata (New-FakeMetadata) `
                  -Quality (New-FakeQuality 'SUSPECT') -DiscId 'abc'
        $dir | Should -Be 'D:\Music\_ReviewQueue\SUSPECT - Mormon Tabernacle Choir - Spirit of the Season - abc'
    }

    It 'review queue: UNKNOWN routes under _ReviewQueue (no metadata in folder name)' {
        $dir = Get-RipperLibraryTargetDir -LibraryRoot 'D:\Music' `
                  -Metadata (New-FakeMetadata) `
                  -Quality (New-FakeQuality 'UNKNOWN') -DiscId 'abc'
        $dir | Should -BeLike 'D:\Music\_ReviewQueue\UNKNOWN - *- abc'
    }
}

Describe 'Move-RipToLibrary (integration)' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([IO.Path]::GetTempPath()) "mtl-$([guid]::NewGuid().Guid)"
        $script:rip     = Join-Path $script:tmpRoot 'rip'
        $script:lib     = Join-Path $script:tmpRoot 'Library'
        Seed-RipFolder $script:rip
        New-Item -ItemType Directory -Path $script:lib | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'moves a single-disc verified rip into Artist/Album (Year) flat' {
        $result = Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
                      -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd'

        $result.IsReviewQueue | Should -BeFalse
        $result.IsMultiDisc   | Should -BeFalse
        $result.FilesMoved    | Should -Be 5
        $expected = Join-Path $script:lib 'Mormon Tabernacle Choir\Spirit of the Season (2007)'
        $result.Target | Should -Be $expected
        Test-Path -LiteralPath (Join-Path $expected '01 - Carol of the Bells.flac') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $expected 'cover.jpg')                    | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $expected 'Spirit of the Season.cue')     | Should -BeTrue
        Test-Path -LiteralPath $script:rip | Should -BeFalse  # source removed when empty
    }

    It 'multi-disc albums land flat at album root (Plex spec; disc # already in filename)' {
        # The mover no longer creates Disc N\ subfolders — per the Plex
        # naming convention, multi-disc tracks live flat at the album
        # root with their disc-prefixed filenames (101, 102, 201, ...).
        # The ripper produced the prefixed filenames upstream.
        $md = New-FakeMetadata -TotalDiscs 2 -DiscNumber 1
        $result = Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
                      -Metadata $md -Quality (New-FakeQuality) -DiscId 'd'

        $result.IsMultiDisc | Should -BeTrue
        $album = $result.Target
        # Seed-RipFolder created '01 - Carol of the Bells.flac' as a stub;
        # the real ripper would have written '101 - ...' for a multi-disc
        # rip. We just verify Move doesn't fan into Disc N\.
        Test-Path -LiteralPath (Join-Path $album '01 - Carol of the Bells.flac') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $album 'Disc 1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $album 'cover.jpg')                    | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $album 'Spirit of the Season.cue')     | Should -BeTrue
    }

    It 'routes a Suspect rip under _ReviewQueue (no special multi-disc handling)' {
        $md = New-FakeMetadata -TotalDiscs 2 -DiscNumber 1   # multi-disc, but suspect
        $result = Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
                      -Metadata $md -Quality (New-FakeQuality 'SUSPECT') -DiscId 'abc'

        $result.IsReviewQueue | Should -BeTrue
        $result.IsMultiDisc   | Should -BeFalse  # review queue ignores multi-disc flag
        $result.Target | Should -BeLike "$($script:lib)\_ReviewQueue\SUSPECT - *"
        Test-Path -LiteralPath (Join-Path $result.Target '01 - Carol of the Bells.flac') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.Target 'Disc 1') | Should -BeFalse
    }

    It 'creates the LibraryRoot if it does not exist yet' {
        Remove-Item -LiteralPath $script:lib -Recurse -Force
        $result = Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
                      -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd'
        Test-Path -LiteralPath $script:lib    | Should -BeTrue
        Test-Path -LiteralPath $result.Target | Should -BeTrue
    }

    It 'throws when the target already exists and -Force is not set' {
        Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
            -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' | Out-Null

        Seed-RipFolder $script:rip   # re-seed source for the second attempt
        { Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
              -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' } |
            Should -Throw '*already exists*'
    }

    It 'overlays an existing target when -Force is set' {
        Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
            -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' | Out-Null
        Seed-RipFolder $script:rip
        $result = Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
                      -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' -Force
        $result.FilesMoved | Should -Be 5
    }

    It 'throws when the source rip folder does not exist' {
        Remove-Item -LiteralPath $script:rip -Recurse -Force
        { Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
              -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' } |
            Should -Throw '*not found*'
    }

    It '-AllowSideBySide picks ` [rip 2]` when the target exists' {
        Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
            -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' | Out-Null

        Seed-RipFolder $script:rip
        $r = Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
                 -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' `
                 -AllowSideBySide
        $r.IsSideBySide | Should -BeTrue
        $r.Target       | Should -Match '\[rip 2\]$'
        Test-Path -LiteralPath $r.Target | Should -BeTrue
    }

    It '-AllowSideBySide escalates to ` [rip 3]` when [rip 2] also exists' {
        Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
            -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' | Out-Null
        Seed-RipFolder $script:rip
        Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
            -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' `
            -AllowSideBySide | Out-Null

        Seed-RipFolder $script:rip
        $r = Move-RipToLibrary -RipFolder $script:rip -LibraryRoot $script:lib `
                 -Metadata (New-FakeMetadata) -Quality (New-FakeQuality) -DiscId 'd' `
                 -AllowSideBySide
        $r.Target | Should -Match '\[rip 3\]$'
    }
}
