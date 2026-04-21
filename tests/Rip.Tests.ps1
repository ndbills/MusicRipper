<#
    Pester tests for src/lib/Rip.psm1 — pure-logic helpers used by
    src/core/Invoke-Rip.ps1 (Phase 4) and src/core/Test-RipQuality.ps1
    (Phase 5). No disc / no network — fully deterministic.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Rip.psd1')    -Force
}

# ---------------------------------------------------------------------------
Describe 'ConvertTo-RipperTrackFilename' {

    It 'pads track number to 2 digits for normal albums' {
        ConvertTo-RipperTrackFilename -TrackNumber 3 -TotalTracks 12 -Title 'Hey Jude' |
            Should -Be '03 - Hey Jude.flac'
    }

    It 'pads to 3 digits when total tracks >= 100' {
        ConvertTo-RipperTrackFilename -TrackNumber 7 -TotalTracks 120 -Title 'Track' |
            Should -Be '007 - Track.flac'
    }

    It 'does NOT prefix artist by default (single-artist album)' {
        $name = ConvertTo-RipperTrackFilename -TrackNumber 1 -TotalTracks 12 -Title 'Sin City' -Artist 'AC/DC'
        $name | Should -Be '01 - Sin City.flac'
    }

    It 'prefixes artist when -IncludeArtist is set (compilation album)' {
        $name = ConvertTo-RipperTrackFilename -TrackNumber 1 -TotalTracks 12 -Title 'Sin City' -Artist 'AC/DC' -IncludeArtist
        $name | Should -Be '01 - AC DC - Sin City.flac'
    }

    It 'sanitizes NTFS-illegal chars in title and artist' {
        $name = ConvertTo-RipperTrackFilename -TrackNumber 4 -TotalTracks 10 `
                  -Title 'Title: Subtitle / Live' -Artist 'A*B?' -IncludeArtist
        # '/' '*' '?' ':' all become spaces; runs collapse; trailing trim happens.
        $name | Should -Be '04 - A B - Title Subtitle Live.flac'
    }

    It 'falls back to _unknown_ for empty title' {
        $name = ConvertTo-RipperTrackFilename -TrackNumber 1 -TotalTracks 1 -Title ''
        $name | Should -Be '01 - _unknown_.flac'
    }

    It 'throws when -IncludeArtist is set but artist is empty' {
        { ConvertTo-RipperTrackFilename -TrackNumber 1 -TotalTracks 1 -Title 'x' -IncludeArtist } |
            Should -Throw -ExpectedMessage '*-Artist is empty*'
    }

    It 'throws when track number exceeds total' {
        { ConvertTo-RipperTrackFilename -TrackNumber 13 -TotalTracks 12 -Title 'x' } |
            Should -Throw -ExpectedMessage '*cannot exceed*'
    }

    It 'honors -Extension override' {
        ConvertTo-RipperTrackFilename -TrackNumber 1 -TotalTracks 1 -Title 'x' -Extension '.wav' |
            Should -Be '01 - x.wav'
    }
}

# ---------------------------------------------------------------------------
Describe 'New-RipperCueSheet' {

    BeforeAll {
        # 3-track audio CD, no pregaps, no HTOA, no pre-emphasis.
        # Sectors: track 1 [0..14999], track 2 [15000..29999], track 3 [30000..44999].
        $script:simpleDisc = [pscustomobject]@{
            DiscId = 'TESTDISCID01'
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=15000; PreEmphasis=$false }
                [pscustomobject]@{ Number=2; IsAudio=$true; StartSector=15000; LengthSectors=15000; PreEmphasis=$false }
                [pscustomobject]@{ Number=3; IsAudio=$true; StartSector=30000; LengthSectors=15000; PreEmphasis=$false }
            )
        }
        $script:simpleMeta = [pscustomobject]@{
            Album       = 'Test Album'
            AlbumArtist = 'Test Artist'
            Year        = 1999
            Genre       = 'Rock'
            Tracks      = @(
                [pscustomobject]@{ Number=1; Title='Track One';   Artist='Test Artist' }
                [pscustomobject]@{ Number=2; Title='Track Two';   Artist='Test Artist' }
                [pscustomobject]@{ Number=3; Title='Track Three'; Artist='Test Artist' }
            )
        }
        $script:simpleNames = @('01 - Track One.flac', '02 - Track Two.flac', '03 - Track Three.flac')
    }

    It 'emits disc-level header lines (PERFORMER, TITLE, REM GENRE/DATE/DISCID)' {
        $cue = New-RipperCueSheet -DiscId $simpleDisc -Metadata $simpleMeta -FlacFilenames $simpleNames
        $cue | Should -Match 'REM GENRE "Rock"'
        $cue | Should -Match 'REM DATE 1999'
        $cue | Should -Match 'REM DISCID TESTDISCID01'
        $cue | Should -Match 'PERFORMER "Test Artist"'
        $cue | Should -Match 'TITLE "Test Album"'
    }

    It 'emits one FILE block per audio track in order' {
        $cue = New-RipperCueSheet -DiscId $simpleDisc -Metadata $simpleMeta -FlacFilenames $simpleNames
        $cue | Should -Match 'FILE "01 - Track One\.flac" WAVE\s+TRACK 01 AUDIO'
        $cue | Should -Match 'FILE "02 - Track Two\.flac" WAVE\s+TRACK 02 AUDIO'
        $cue | Should -Match 'FILE "03 - Track Three\.flac" WAVE\s+TRACK 03 AUDIO'
    }

    It 'always emits INDEX 01 00:00:00 for each track' {
        $cue = New-RipperCueSheet -DiscId $simpleDisc -Metadata $simpleMeta -FlacFilenames $simpleNames
        ([regex]::Matches($cue, 'INDEX 01 00:00:00')).Count | Should -Be 3
    }

    It 'omits INDEX 00 when there is no pregap between tracks' {
        $cue = New-RipperCueSheet -DiscId $simpleDisc -Metadata $simpleMeta -FlacFilenames $simpleNames
        $cue | Should -Not -Match 'INDEX 00'
    }

    It 'emits CRLF line endings' {
        $cue = New-RipperCueSheet -DiscId $simpleDisc -Metadata $simpleMeta -FlacFilenames $simpleNames
        $cue.Contains("`r`n") | Should -BeTrue
    }

    It 'emits INDEX 00 with offset = previous track length when track 2 has a 150-sector pregap' {
        # Track 2 starts at 15150 (150 sectors after track 1 end). Track 1's
        # encoded file will contain its own 15000 sectors PLUS the 150-sector
        # pregap = 15150 sectors. INDEX 00 in track 2's block points to
        # offset 15000 inside file 1 -> that's 15000 / 75 = 200 seconds = 03:20:00.
        $disc = [pscustomobject]@{
            DiscId = 'PREGAPDISC'
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=15000; PreEmphasis=$false }
                [pscustomobject]@{ Number=2; IsAudio=$true; StartSector=15150; LengthSectors=14850; PreEmphasis=$false }
            )
        }
        $meta = [pscustomobject]@{
            Album='X'; AlbumArtist='Y'; Year=2000; Genre=$null
            Tracks=@(
                [pscustomobject]@{ Number=1; Title='A'; Artist='Y' }
                [pscustomobject]@{ Number=2; Title='B'; Artist='Y' }
            )
        }
        $cue = New-RipperCueSheet -DiscId $disc -Metadata $meta -FlacFilenames @('01 - A.flac','02 - B.flac')
        $cue | Should -Match '(?s)TRACK 02 AUDIO.*?INDEX 00 03:20:00.*?INDEX 01 00:00:00'
    }

    It 'emits FLAGS PRE for tracks with pre-emphasis' {
        $disc = [pscustomobject]@{
            DiscId = 'PREDISC'
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=15000; PreEmphasis=$true }
                [pscustomobject]@{ Number=2; IsAudio=$true; StartSector=15000; LengthSectors=15000; PreEmphasis=$false }
            )
        }
        $meta = [pscustomobject]@{
            Album='X'; AlbumArtist='Y'; Year=2000
            Tracks=@(
                [pscustomobject]@{ Number=1; Title='A'; Artist='Y' }
                [pscustomobject]@{ Number=2; Title='B'; Artist='Y' }
            )
        }
        $cue = New-RipperCueSheet -DiscId $disc -Metadata $meta -FlacFilenames @('01 - A.flac','02 - B.flac')
        $cue | Should -Match '(?s)TRACK 01 AUDIO.*?FLAGS PRE.*?INDEX 01'
        # Track 2 must NOT have a FLAGS PRE
        $afterTrack2 = ($cue -split 'TRACK 02 AUDIO')[1]
        $afterTrack2 | Should -Not -Match 'FLAGS PRE'
    }

    It 'replaces embedded double quotes with single quotes (CUE has no escape)' {
        $disc = [pscustomobject]@{
            DiscId = 'QDISC'
            Tracks = @( [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0; LengthSectors=15000; PreEmphasis=$false } )
        }
        $meta = [pscustomobject]@{
            Album='He said "hi"'; AlbumArtist='Y'; Year=2000
            Tracks=@( [pscustomobject]@{ Number=1; Title='A'; Artist='Y' } )
        }
        $cue = New-RipperCueSheet -DiscId $disc -Metadata $meta -FlacFilenames @('01 - A.flac')
        $cue | Should -Match "TITLE ""He said 'hi'"""
    }

    It 'emits ISRC and per-track PERFORMER on Various-Artists releases' {
        $disc = [pscustomobject]@{
            DiscId = 'VADISC'
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=15000; PreEmphasis=$false }
                [pscustomobject]@{ Number=2; IsAudio=$true; StartSector=15000; LengthSectors=15000; PreEmphasis=$false }
            )
        }
        $meta = [pscustomobject]@{
            Album='Compilation'; AlbumArtist='Various Artists'; Year=2010
            Tracks=@(
                [pscustomobject]@{ Number=1; Title='Song A'; Artist='Artist 1'; Isrc='USRC17607839' }
                [pscustomobject]@{ Number=2; Title='Song B'; Artist='Artist 2'; Isrc='USRC17607840' }
            )
        }
        $cue = New-RipperCueSheet -DiscId $disc -Metadata $meta -FlacFilenames @('01 - x.flac','02 - y.flac')
        $cue | Should -Match '(?s)TRACK 01 AUDIO.*?PERFORMER "Artist 1".*?ISRC USRC17607839'
        $cue | Should -Match '(?s)TRACK 02 AUDIO.*?PERFORMER "Artist 2".*?ISRC USRC17607840'
    }

    It 'emits a REM HTOA comment when track 1 has a non-zero StartSector' {
        $disc = [pscustomobject]@{
            DiscId = 'HTOADISC'
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=4500; LengthSectors=15000; PreEmphasis=$false }
            )
        }
        $meta = [pscustomobject]@{
            Album='X'; AlbumArtist='Y'; Year=2000
            Tracks=@( [pscustomobject]@{ Number=1; Title='A'; Artist='Y' } )
        }
        $cue = New-RipperCueSheet -DiscId $disc -Metadata $meta -FlacFilenames @('01 - A.flac')
        $cue | Should -Match 'REM HTOA "Track 1 begins at sector 4500'
    }

    It 'embeds the GeneratorTag as REM COMMENT when supplied' {
        $cue = New-RipperCueSheet -DiscId $simpleDisc -Metadata $simpleMeta `
                                  -FlacFilenames $simpleNames `
                                  -GeneratorTag 'MusicRipper 0.1'
        $cue | Should -Match 'REM COMMENT "MusicRipper 0\.1"'
    }

    It 'throws on filename count mismatch' {
        { New-RipperCueSheet -DiscId $simpleDisc -Metadata $simpleMeta -FlacFilenames @('only-one.flac') } |
            Should -Throw -ExpectedMessage '*does not match audio-track count*'
    }
}

# ---------------------------------------------------------------------------
Describe 'ConvertFrom-RipperRipLog' {

    It 'returns Status=Unknown for empty input' {
        $r = ConvertFrom-RipperRipLog -LogText ''
        $r.Status | Should -Be 'Unknown'
        $r.Tracks.Count | Should -Be 0
    }

    It 'detects "all tracks accurately ripped" with confidence' {
        $log = @(
            '[Disc ID: 0123abcd]'
            '[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 9)]'
            'Track 01 [aaaa]: accurately ripped (confidence 9)'
            'Track 02 [bbbb]: accurately ripped (confidence 9)'
        ) -join "`n"
        $r = ConvertFrom-RipperRipLog -LogText $log
        $r.AccurateRip.Status        | Should -Be 'Verified'
        $r.AccurateRip.MinConfidence | Should -Be 9
        $r.AccurateRip.MatchedTracks | Should -Be 2
        $r.Tracks.Count              | Should -Be 2
        $r.Status                    | Should -Be 'Verified'
    }

    It 'classifies "differs in N samples" as Suspect' {
        $log = @(
            '[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 5)]'
            'Track 01 [aaaa]: accurately ripped (confidence 5)'
            'Track 02 [bbbb]: differs in 14 samples @00:00.50, no match in any version'
        ) -join "`n"
        $r = ConvertFrom-RipperRipLog -LogText $log
        $r.Status | Should -Be 'Suspect'
        ($r.Tracks | Where-Object Number -eq 2).Verdict | Should -Be 'Suspect'
    }

    It 'reports NotInDatabase when AR has no entry' {
        $log = '[AccurateRip: Disc not present in database]'
        $r = ConvertFrom-RipperRipLog -LogText $log
        $r.AccurateRip.Status | Should -Be 'NotInDatabase'
        $r.Status             | Should -Be 'NotInDatabase'
    }

    It 'falls back to ProbablyGood when CTDB verifies but AR confidence is 1' {
        $log = @(
            '[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 1)]'
            '[CTDB: id=xyz, all tracks accurately ripped (confidence 6)]'
            'Track 01 [aaaa]: accurately ripped (confidence 1)'
        ) -join "`n"
        $r = ConvertFrom-RipperRipLog -LogText $log
        $r.AccurateRip.MinConfidence | Should -Be 1
        $r.Ctdb.Status               | Should -Be 'Verified'
        $r.Status                    | Should -Be 'ProbablyGood'
    }

    It 'tolerates CRLF line endings' {
        $log = "[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 4)]`r`nTrack 01 [aa]: accurately ripped (confidence 4)`r`n"
        $r = ConvertFrom-RipperRipLog -LogText $log
        $r.Status | Should -Be 'Verified'
    }
}
