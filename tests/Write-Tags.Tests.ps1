<#
    Pester tests for src/core/Write-Tags.ps1.

    Pure-logic helper New-RipperFlacTagSet is exhaustively tested below.
    Invoke-RipperWriteTags is exercised against a stub metaflac.cmd that
    records its argv to a sidecar file — this lets us assert exact
    argument shape without needing real FLAC files or the Xiph tools.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\Write-Tags.ps1')

    function script:New-FakeMetadata {
        param([switch]$Compilation, [switch]$WithGenre, [switch]$NoMbids)

        $tracks = @(
            [pscustomobject]@{
                Number = 1; Title = 'Carol of the Bells'
                Artist = $(if ($Compilation) { 'Trans-Siberian Orchestra' } else { '' })
                ArtistMbid    = $(if ($NoMbids) { $null } else { 'aaaa-1111' })
                RecordingMbid = $(if ($NoMbids) { $null } else { 'rec-1111' })
                LengthMs      = 180000
            },
            [pscustomobject]@{
                Number = 2; Title = 'Silent Night'
                Artist = $(if ($Compilation) { 'Mannheim Steamroller' } else { '' })
                ArtistMbid    = $(if ($NoMbids) { $null } else { 'aaaa-2222' })
                RecordingMbid = $(if ($NoMbids) { $null } else { 'rec-2222' })
                LengthMs      = 200000
            }
        )
        $obj = [pscustomobject]@{
            AlbumArtist      = 'Mormon Tabernacle Choir'
            AlbumArtistMbid  = $(if ($NoMbids) { $null } else { 'mtc-mbid' })
            Album            = 'Spirit of the Season'
            ReleaseMbid      = $(if ($NoMbids) { $null } else { 'rel-mbid' })
            ReleaseGroupMbid = $(if ($NoMbids) { $null } else { 'rg-mbid' })
            Year             = 2007
            DiscNumber       = 1
            TotalDiscs       = 1
            IsCompilation    = [bool]$Compilation
            Tracks           = $tracks
        }
        if ($WithGenre) { $obj | Add-Member -NotePropertyName Genre -NotePropertyValue 'Holiday' }
        $obj
    }
}

Describe 'New-RipperFlacTagSet' {
    It 'emits the always-present tags in stable order' {
        $md = New-FakeMetadata
        $tags = New-RipperFlacTagSet -Metadata $md -TrackIndex 0 -DiscId 'discABC' -IsCompilation $false
        # First eight slots must be deterministic for round-trip diffing.
        $tags[0] | Should -Be 'ALBUMARTIST=Mormon Tabernacle Choir'
        $tags[1] | Should -Be 'ARTIST=Mormon Tabernacle Choir'  # falls back to AlbumArtist when track Artist blank
        $tags[2] | Should -Be 'ALBUM=Spirit of the Season'
        $tags[3] | Should -Be 'TITLE=Carol of the Bells'
        $tags[4] | Should -Be 'TRACKNUMBER=1'
        $tags[5] | Should -Be 'TRACKTOTAL=2'
        $tags[6] | Should -Be 'DISCNUMBER=1'
        $tags[7] | Should -Be 'DISCTOTAL=1'
    }

    It 'includes DATE only when Year is set' {
        $md = New-FakeMetadata
        (New-RipperFlacTagSet -Metadata $md -TrackIndex 0 -DiscId 'd' -IsCompilation $false) | Should -Contain 'DATE=2007'
        $md.Year = $null
        (New-RipperFlacTagSet -Metadata $md -TrackIndex 0 -DiscId 'd' -IsCompilation $false) |
            Where-Object { $_ -like 'DATE=*' } | Should -BeNullOrEmpty
    }

    It 'includes GENRE only when Metadata.Genre is set' {
        (New-RipperFlacTagSet -Metadata (New-FakeMetadata)             -TrackIndex 0 -DiscId 'd' -IsCompilation $false) |
            Where-Object { $_ -like 'GENRE=*' } | Should -BeNullOrEmpty
        (New-RipperFlacTagSet -Metadata (New-FakeMetadata -WithGenre)  -TrackIndex 0 -DiscId 'd' -IsCompilation $false) |
            Should -Contain 'GENRE=Holiday'
    }

    It 'emits COMPILATION=1 only when -IsCompilation is set, and uses the per-track artist' {
        $md = New-FakeMetadata -Compilation
        $tags = New-RipperFlacTagSet -Metadata $md -TrackIndex 1 -DiscId 'd' -IsCompilation $true
        $tags | Should -Contain 'COMPILATION=1'
        $tags | Should -Contain 'ARTIST=Mannheim Steamroller'
        $tags | Should -Contain 'ALBUMARTIST=Mormon Tabernacle Choir'
    }

    It 'omits COMPILATION when -IsCompilation is false' {
        $tags = New-RipperFlacTagSet -Metadata (New-FakeMetadata) -TrackIndex 0 -DiscId 'd' -IsCompilation $false
        $tags | Where-Object { $_ -like 'COMPILATION=*' } | Should -BeNullOrEmpty
    }

    It 'always emits MUSICBRAINZ_DISCID' {
        $tags = New-RipperFlacTagSet -Metadata (New-FakeMetadata -NoMbids) -TrackIndex 0 -DiscId 'discXYZ' -IsCompilation $false
        $tags | Should -Contain 'MUSICBRAINZ_DISCID=discXYZ'
    }

    It 'emits all five MusicBrainz id tags when present' {
        $tags = New-RipperFlacTagSet -Metadata (New-FakeMetadata) -TrackIndex 0 -DiscId 'd' -IsCompilation $false
        $tags | Should -Contain 'MUSICBRAINZ_ALBUMID=rel-mbid'
        $tags | Should -Contain 'MUSICBRAINZ_ALBUMARTISTID=mtc-mbid'
        $tags | Should -Contain 'MUSICBRAINZ_ARTISTID=aaaa-1111'
        $tags | Should -Contain 'MUSICBRAINZ_TRACKID=rec-1111'
        $tags | Should -Contain 'MUSICBRAINZ_RELEASEGROUPID=rg-mbid'
    }

    It 'omits MusicBrainz id tags when the underlying fields are missing' {
        $tags = New-RipperFlacTagSet -Metadata (New-FakeMetadata -NoMbids) -TrackIndex 0 -DiscId 'd' -IsCompilation $false
        $tags | Where-Object { $_ -like 'MUSICBRAINZ_ALBUMID=*' }       | Should -BeNullOrEmpty
        $tags | Where-Object { $_ -like 'MUSICBRAINZ_ARTISTID=*' }      | Should -BeNullOrEmpty
        $tags | Where-Object { $_ -like 'MUSICBRAINZ_ALBUMARTISTID=*' } | Should -BeNullOrEmpty
        $tags | Where-Object { $_ -like 'MUSICBRAINZ_TRACKID=*' }       | Should -BeNullOrEmpty
        $tags | Where-Object { $_ -like 'MUSICBRAINZ_RELEASEGROUPID=*' }| Should -BeNullOrEmpty
    }

    It 'preserves Unicode in tag values (no UTF-8 corruption)' {
        $md = New-FakeMetadata
        $md.Album = 'Sigur Rós — Ágætis byrjun'
        $tags = New-RipperFlacTagSet -Metadata $md -TrackIndex 0 -DiscId 'd' -IsCompilation $false
        $tags | Should -Contain 'ALBUM=Sigur Rós — Ágætis byrjun'
    }

    It 'throws on out-of-range TrackIndex' {
        { New-RipperFlacTagSet -Metadata (New-FakeMetadata) -TrackIndex 5 -DiscId 'd' -IsCompilation $false } |
            Should -Throw '*out of range*'
    }
}

Describe 'Get-RipperRipFolderTracks' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'sorts FLAC files by leading track number, not lexically' {
        '01 - First.flac','02 - Second.flac','10 - Tenth.flac','11 - Eleventh.flac' |
            ForEach-Object { New-Item -ItemType File -Path (Join-Path $script:tmp $_) | Out-Null }
        $hits = Get-RipperRipFolderTracks -RipFolder $script:tmp
        @($hits).Count | Should -Be 4
        $hits[0].Name | Should -Be '01 - First.flac'
        $hits[2].Name | Should -Be '10 - Tenth.flac'
        $hits[3].Name | Should -Be '11 - Eleventh.flac'
    }

    It 'skips files that do not match the "NN - " prefix (e.g. image FLAC)' {
        '01 - Track.flac','image.flac','cover.jpg' |
            ForEach-Object { New-Item -ItemType File -Path (Join-Path $script:tmp $_) | Out-Null }
        $hits = @(Get-RipperRipFolderTracks -RipFolder $script:tmp)
        $hits.Count    | Should -Be 1
        $hits[0].Name  | Should -Be '01 - Track.flac'
    }

    It 'throws when the folder does not exist' {
        { Get-RipperRipFolderTracks -RipFolder (Join-Path $script:tmp 'no-such') } |
            Should -Throw '*not found*'
    }
}

Describe 'Invoke-RipperWriteTags (stub-metaflac integration)' {
    BeforeAll {
        # Stub metaflac.cmd that appends every argv to a sidecar log per call.
        # We emit one line per invocation, args separated by | so the test can
        # parse both the per-track and the per-album invocations.
        $script:stubDir  = Join-Path ([IO.Path]::GetTempPath()) "wt-stub-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path $script:stubDir | Out-Null
        $script:stubLog  = Join-Path $script:stubDir 'metaflac-calls.log'
        $script:stubExe  = Join-Path $script:stubDir 'metaflac.cmd'
@"
@echo off
echo %*>>"$script:stubLog"
exit /b 0
"@ | Set-Content -LiteralPath $script:stubExe -Encoding ASCII
    }
    AfterAll {
        Remove-Item -LiteralPath $script:stubDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        if (Test-Path -LiteralPath $script:stubLog) { Remove-Item -LiteralPath $script:stubLog }
        $script:rip = Join-Path ([IO.Path]::GetTempPath()) "wt-rip-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path $script:rip | Out-Null
        '01 - Carol of the Bells.flac','02 - Silent Night.flac' |
            ForEach-Object { New-Item -ItemType File -Path (Join-Path $script:rip $_) | Out-Null }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:rip -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'invokes metaflac per track + once for ReplayGain, and writes a cover sidecar' {
        $cover = [byte[]](0xFF, 0xD8, 0xFF, 0xE0, 0,0,0,0)  # JPEG SOI bytes
        $result = Invoke-RipperWriteTags -RipFolder $script:rip -Metadata (New-FakeMetadata) `
                      -DiscId 'discABC' -CoverArtBytes $cover -MetaflacPath $script:stubExe

        $result.CoverSidecarWritten | Should -BeTrue
        $result.CoverEmbedded       | Should -Be 2
        $result.ReplayGainComputed  | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:rip 'cover.jpg') | Should -BeTrue

        $lines = Get-Content -LiteralPath $script:stubLog
        # Per-track: 1x --remove-all-tags+--set-tag, 1x --remove PICTURE, 1x --import-picture-from
        # Per album: 1x --add-replay-gain
        # = 3 calls per track * 2 tracks + 1 = 7 invocations total.
        @($lines).Count | Should -Be 7

        $rgLine = $lines | Where-Object { $_ -like '*--add-replay-gain*' }
        @($rgLine).Count | Should -Be 1
        $rgLine | Should -Match '01 - Carol of the Bells\.flac'
        $rgLine | Should -Match '02 - Silent Night\.flac'

        ($lines | Where-Object { $_ -like '*--import-picture-from=*' }).Count    | Should -Be 2
        ($lines | Where-Object { $_ -like '*--remove --block-type=PICTURE*' }).Count | Should -Be 2
        ($lines | Where-Object { $_ -like '*--remove-all-tags*' }).Count            | Should -Be 2
    }

    It 'skips ReplayGain when -SkipReplayGain is set' {
        $result = Invoke-RipperWriteTags -RipFolder $script:rip -Metadata (New-FakeMetadata) `
                      -DiscId 'd' -SkipReplayGain -MetaflacPath $script:stubExe
        $result.ReplayGainComputed | Should -BeFalse
        (Get-Content -LiteralPath $script:stubLog) |
            Where-Object { $_ -like '*--add-replay-gain*' } | Should -BeNullOrEmpty
    }

    It 'skips cover-art steps when no cover is provided and none on disk' {
        $result = Invoke-RipperWriteTags -RipFolder $script:rip -Metadata (New-FakeMetadata) `
                      -DiscId 'd' -SkipReplayGain -MetaflacPath $script:stubExe
        $result.CoverEmbedded       | Should -Be 0
        $result.CoverSidecarWritten | Should -BeFalse
        (Get-Content -LiteralPath $script:stubLog) |
            Where-Object { $_ -like '*--import-picture-from=*' } | Should -BeNullOrEmpty
    }

    It 'reuses an existing cover.jpg sidecar (does not overwrite)' {
        $existing = [byte[]](1,2,3,4)
        [IO.File]::WriteAllBytes((Join-Path $script:rip 'cover.jpg'), $existing)
        $result = Invoke-RipperWriteTags -RipFolder $script:rip -Metadata (New-FakeMetadata) `
                      -DiscId 'd' -CoverArtBytes ([byte[]](9,9,9,9)) `
                      -SkipReplayGain -MetaflacPath $script:stubExe
        $result.CoverSidecarWritten | Should -BeFalse
        $result.CoverEmbedded       | Should -Be 2
        # Deep array compare via -join (Pester's Should -Be uses scalar equality on arrays).
        $actual = [IO.File]::ReadAllBytes((Join-Path $script:rip 'cover.jpg'))
        ($actual -join ',') | Should -Be ($existing -join ',')
    }

    It 'throws on track-count mismatch' {
        # Add a third FLAC the metadata does not know about.
        New-Item -ItemType File -Path (Join-Path $script:rip '03 - Extra.flac') | Out-Null
        { Invoke-RipperWriteTags -RipFolder $script:rip -Metadata (New-FakeMetadata) `
              -DiscId 'd' -SkipReplayGain -MetaflacPath $script:stubExe } |
            Should -Throw '*Track-count mismatch*'
    }
}
