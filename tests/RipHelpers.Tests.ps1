<#
    Pester tests for src/lib/RipHelpers.psm1 — pure-logic helpers for the
    Phase 4 rip pipeline. No CD, no WPF, no CUETools DLLs touched.
    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\RipHelpers.psd1') -Force
}

Describe 'New-RipperTrackFileName' {
    It 'zero-pads to width-of-total-track-count, minimum 2' {
        New-RipperTrackFileName -TrackNumber 3 -Title 'Hey Jude' -TotalTracks 12 |
            Should -Be '03 - Hey Jude.flac'
        # 9-track album still pads to 2 (minimum).
        New-RipperTrackFileName -TrackNumber 1 -Title 'A' -TotalTracks 9 |
            Should -Be '01 - A.flac'
        # 100-track box set pads to 3.
        New-RipperTrackFileName -TrackNumber 7 -Title 'A' -TotalTracks 100 |
            Should -Be '007 - A.flac'
    }

    It 'omits artist for single-artist albums' {
        New-RipperTrackFileName -TrackNumber 1 -Title 'Foo' -TotalTracks 10 -Artist 'Bar' |
            Should -Be '01 - Foo.flac'
    }

    It 'omits artist even when -IsCompilation set (Plex spec: artist lives in ARTIST tag)' {
        New-RipperTrackFileName -TrackNumber 1 -Title 'Foo' -TotalTracks 10 `
            -Artist 'Bar' -IsCompilation |
            Should -Be '01 - Foo.flac'
    }

    It 'sanitizes NTFS-illegal chars in title' {
        $r = New-RipperTrackFileName -TrackNumber 2 -Title 'AC/DC: Live' `
                -TotalTracks 9 -Artist 'AC/DC' -IsCompilation
        $r | Should -Be '02 - AC DC Live.flac'
    }

    It 'substitutes _unknown_ for empty title' {
        New-RipperTrackFileName -TrackNumber 1 -Title '' -TotalTracks 5 |
            Should -Be '01 - _unknown_.flac'
    }

    It 'strips trailing dots that NTFS would silently drop' {
        New-RipperTrackFileName -TrackNumber 1 -Title 'Etc...' -TotalTracks 5 |
            Should -Be '01 - Etc.flac'
    }

    It 'collapses control chars to single space' {
        $title = "Foo`tBar`nBaz"
        New-RipperTrackFileName -TrackNumber 1 -Title $title -TotalTracks 5 |
            Should -Be '01 - Foo Bar Baz.flac'
    }

    It 'prepends disc number to track number when TotalDiscs > 1 (Plex spec)' {
        # 2-disc set, disc 1 track 5 -> 105 - Title.flac
        New-RipperTrackFileName -TrackNumber 5 -Title 'Hey You' -TotalTracks 13 `
            -DiscNumber 1 -TotalDiscs 2 |
            Should -Be '105 - Hey You.flac'
        # disc 2 track 12 -> 212 - Title.flac
        New-RipperTrackFileName -TrackNumber 12 -Title 'Comfortably Numb' -TotalTracks 13 `
            -DiscNumber 2 -TotalDiscs 2 |
            Should -Be '212 - Comfortably Numb.flac'
    }

    It 'pads disc number for >=10-disc box sets' {
        # 12-disc box, disc 3 track 7 of 14 -> 0307
        New-RipperTrackFileName -TrackNumber 7 -Title 'X' -TotalTracks 14 `
            -DiscNumber 3 -TotalDiscs 12 |
            Should -Be '0307 - X.flac'
    }

    It 'omits disc prefix when TotalDiscs is 1 (default)' {
        New-RipperTrackFileName -TrackNumber 5 -Title 'X' -TotalTracks 13 -DiscNumber 1 |
            Should -Be '05 - X.flac'
    }
}

Describe 'ConvertTo-RipperCueTime' {
    It 'returns 00:00:00 for sample 0' {
        ConvertTo-RipperCueTime -Samples 0 | Should -Be '00:00:00'
    }

    It 'one second = 75 frames = 44100 samples' {
        ConvertTo-RipperCueTime -Samples 44100 | Should -Be '00:01:00'
    }

    It 'one frame = 588 samples' {
        ConvertTo-RipperCueTime -Samples 588 | Should -Be '00:00:01'
    }

    It 'one minute' {
        ConvertTo-RipperCueTime -Samples (44100 * 60) | Should -Be '01:00:00'
    }

    It 'composite: 2:34:50' {
        $samples = (2 * 60 * 75 + 34 * 75 + 50) * 588
        ConvertTo-RipperCueTime -Samples $samples | Should -Be '02:34:50'
    }

    It 'rejects non-frame-aligned sample counts' {
        { ConvertTo-RipperCueTime -Samples 1 } | Should -Throw
        { ConvertTo-RipperCueTime -Samples 587 } | Should -Throw
    }
}

Describe 'New-RipperCueSheet' {
    BeforeAll {
        # Hashtable-shaped layout mirrors the pscustomobject Get-RipperDiscId
        # returns: {Number, IsAudio, StartSector, LengthSectors,
        # PreEmphasis} plus the optional ISRC/DCP fields the helper
        # also recognises. Pregap is COMPUTED from sector arithmetic
        # (this track's StartSector minus previous track's StartSector +
        # LengthSectors), not stored directly.
        # Two contiguous audio tracks, no pregaps, no HTOA.
        $script:layout = @{
            TrackCount = 2
            Tracks = @(
                @{ Number = 1; IsAudio = $true; StartSector = 0;     LengthSectors = 15000; ISRC = ''; DCP = $false; PreEmphasis = $false }
                @{ Number = 2; IsAudio = $true; StartSector = 15000; LengthSectors = 15000; ISRC = ''; DCP = $false; PreEmphasis = $false }
            )
        }
        $script:meta = [pscustomobject]@{
            AlbumArtist = 'The Band'
            Album       = 'Greatest Hits'
            Year        = 1999
            DiscId      = 'abcdef1234'
            Tracks      = @(
                [pscustomobject]@{ Number = 1; Title = 'One'; Artist = 'The Band' },
                [pscustomobject]@{ Number = 2; Title = 'Two'; Artist = 'The Band' }
            )
        }
    }

    It 'emits CRLF line endings' {
        $cue = New-RipperCueSheet -Layout $script:layout -Metadata $script:meta `
            -FlacFileNames @('01 - One.flac','02 - Two.flac')
        $cue | Should -Match "`r`n"
    }

    It 'includes album-level header (DATE, DISCID, PERFORMER, TITLE, COMMENT)' {
        $cue = New-RipperCueSheet -Layout $script:layout -Metadata $script:meta `
            -FlacFileNames @('01 - One.flac','02 - Two.flac')
        $cue | Should -Match 'REM DATE 1999'
        $cue | Should -Match 'REM DISCID abcdef1234'
        $cue | Should -Match 'REM COMMENT "MusicRipper"'
        $cue | Should -Match 'PERFORMER "The Band"'
        $cue | Should -Match 'TITLE "Greatest Hits"'
    }

    It 'emits one FILE..TRACK..INDEX 01 block per track' {
        $cue = New-RipperCueSheet -Layout $script:layout -Metadata $script:meta `
            -FlacFileNames @('01 - One.flac','02 - Two.flac')
        ([regex]::Matches($cue, 'TRACK \d{2} AUDIO')).Count | Should -Be 2
        ([regex]::Matches($cue, 'INDEX 01 00:00:00')).Count | Should -Be 2
        $cue | Should -Match 'FILE "01 - One.flac" WAVE'
        $cue | Should -Match 'FILE "02 - Two.flac" WAVE'
    }

    It 'omits INDEX 00 when adjacent tracks are contiguous (no pregap)' {
        $cue = New-RipperCueSheet -Layout $script:layout -Metadata $script:meta `
            -FlacFileNames @('01 - One.flac','02 - Two.flac')
        $cue | Should -Not -Match 'INDEX 00'
    }

    It 'emits INDEX 00 with offset = previous track length when track 2 has a 150-sector pregap' {
        # Track 2 starts at sector 15150 — 150 sectors after track 1 ends.
        # Under append-to-previous, those 150 pregap sectors get encoded
        # into the END of file 1, so file 1's playable length is now
        # 15000 (clean) + 150 (pregap) = 15150 sectors. INDEX 00 in
        # track 2's block points to offset 15000 INSIDE file 1, which
        # is 15000 / 75 = 200 seconds = 03:20:00.
        $layout2 = @{
            TrackCount = 2
            Tracks = @(
                @{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=15000; PreEmphasis=$false }
                @{ Number=2; IsAudio=$true; StartSector=15150; LengthSectors=14850; PreEmphasis=$false }
            )
        }
        $meta2 = [pscustomobject]@{
            AlbumArtist='Y'; Album='X'; Year=2000
            Tracks=@(
                [pscustomobject]@{ Number=1; Title='A'; Artist='Y' }
                [pscustomobject]@{ Number=2; Title='B'; Artist='Y' }
            )
        }
        $cue = New-RipperCueSheet -Layout $layout2 -Metadata $meta2 `
            -FlacFileNames @('01 - A.flac','02 - B.flac')
        $cue | Should -Match '(?s)TRACK 02 AUDIO.*?INDEX 00 03:20:00.*?INDEX 01 00:00:00'
    }

    It 'emits a REM HTOA comment when track 1 starts after sector 0 (hidden track)' {
        $layoutHtoa = @{
            TrackCount = 1
            Tracks = @(
                @{ Number=1; IsAudio=$true; StartSector=4500; LengthSectors=15000; PreEmphasis=$false }
            )
        }
        $meta1 = [pscustomobject]@{
            AlbumArtist='Y'; Album='X'; Year=2000
            Tracks=@( [pscustomobject]@{ Number=1; Title='A'; Artist='Y' } )
        }
        $cue = New-RipperCueSheet -Layout $layoutHtoa -Metadata $meta1 -FlacFileNames @('01 - A.flac')
        $cue | Should -Match 'REM HTOA "Track 1 begins at sector 4500'
    }

    It 'omits per-track PERFORMER when it equals AlbumArtist' {
        $cue = New-RipperCueSheet -Layout $script:layout -Metadata $script:meta `
            -FlacFileNames @('01 - One.flac','02 - Two.flac')
        # PERFORMER "The Band" only appears once (the album-level header).
        ([regex]::Matches($cue, '^\s*PERFORMER "The Band"', 'Multiline')).Count | Should -Be 1
    }

    It 'emits per-track PERFORMER on compilations (artist differs)' {
        $meta2 = [pscustomobject]@{
            AlbumArtist = 'Various Artists'; Album = 'Mix'; Year = 2020
            Tracks = @(
                [pscustomobject]@{ Number = 1; Title = 'A'; Artist = 'Alice' },
                [pscustomobject]@{ Number = 2; Title = 'B'; Artist = 'Bob' }
            )
        }
        $cue = New-RipperCueSheet -Layout $script:layout -Metadata $meta2 `
            -FlacFileNames @('01 - A.flac','02 - B.flac')
        $cue | Should -Match 'PERFORMER "Alice"'
        $cue | Should -Match 'PERFORMER "Bob"'
    }

    It 'escapes embedded double-quotes by replacing with single quotes' {
        $meta2 = [pscustomobject]@{
            AlbumArtist = 'Band'; Album = 'They said "hi"'; Year = 2020
            Tracks = @([pscustomobject]@{ Number = 1; Title = 'a "b" c'; Artist = 'Band' })
        }
        $layout1 = @{ TrackCount = 1; Tracks = @(@{ Number = 1; IsAudio = $true; StartSector = 0; LengthSectors = 15000 }) }
        $cue = New-RipperCueSheet -Layout $layout1 -Metadata $meta2 -FlacFileNames @('01 - a.flac')
        $cue | Should -Match "TITLE `"They said 'hi'`""
        $cue | Should -Match "TITLE `"a 'b' c`""
    }

    It 'throws on track-count mismatch (filenames vs layout)' {
        { New-RipperCueSheet -Layout $script:layout -Metadata $script:meta `
            -FlacFileNames @('01 - only.flac') } | Should -Throw
    }

    It 'throws on track-count mismatch (metadata vs layout)' {
        $metaShort = [pscustomobject]@{
            AlbumArtist = 'A'; Album = 'B'; Year = 2020
            Tracks = @([pscustomobject]@{ Number = 1; Title = 'x'; Artist = 'A' })
        }
        { New-RipperCueSheet -Layout $script:layout -Metadata $metaShort `
            -FlacFileNames @('01.flac','02.flac') } | Should -Throw
    }

    It 'emits FLAGS line when DCP/PRE set on the layout track' {
        $layoutFlags = @{
            TrackCount = 1
            Tracks = @(@{ Number = 1; IsAudio = $true; StartSector = 0; LengthSectors = 15000;
                          ISRC = ''; DCP = $true; PreEmphasis = $true })
        }
        $meta1 = [pscustomobject]@{
            AlbumArtist = 'A'; Album = 'B'; Year = 2020
            Tracks = @([pscustomobject]@{ Number = 1; Title = 'x'; Artist = 'A' })
        }
        $cue = New-RipperCueSheet -Layout $layoutFlags -Metadata $meta1 -FlacFileNames @('01.flac')
        $cue | Should -Match 'FLAGS DCP PRE'
    }

    It 'emits ISRC line when layout reports one' {
        $layoutIsrc = @{
            TrackCount = 1
            Tracks = @(@{ Number = 1; IsAudio = $true; StartSector = 0; LengthSectors = 15000;
                          ISRC = 'USRC17607839'; DCP = $false; PreEmphasis = $false })
        }
        $meta1 = [pscustomobject]@{
            AlbumArtist = 'A'; Album = 'B'; Year = 2020
            Tracks = @([pscustomobject]@{ Number = 1; Title = 'x'; Artist = 'A' })
        }
        $cue = New-RipperCueSheet -Layout $layoutIsrc -Metadata $meta1 -FlacFileNames @('01.flac')
        $cue | Should -Match 'ISRC USRC17607839'
    }
}

Describe 'Get-RipperLogSummary' {
    It 'returns Status=Unknown for empty input' {
        $r = Get-RipperLogSummary -LogText ''
        $r.Status              | Should -Be 'Unknown'
        $r.AccurateRip.Status  | Should -Be 'Unknown'
        $r.Ctdb.Status         | Should -Be 'Unknown'
        $r.Tracks.Count        | Should -Be 0
    }

    It 'detects "all tracks accurately ripped" with confidence' {
        $log = @(
            '[Disc ID: 0123abcd]'
            '[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 9)]'
            'Track 01 [aaaa]: accurately ripped (confidence 9)'
            'Track 02 [bbbb]: accurately ripped (confidence 9)'
        ) -join "`n"
        $r = Get-RipperLogSummary -LogText $log
        $r.AccurateRip.Status        | Should -Be 'Verified'
        $r.AccurateRip.MinConfidence | Should -Be 9
        $r.AccurateRip.MatchedTracks | Should -Be 2
        $r.AccurateRip.TotalTracks   | Should -Be 2
        $r.Tracks.Count              | Should -Be 2
        $r.Status                    | Should -Be 'Verified'
    }

    It 'classifies "differs in N samples" as Suspect' {
        $log = @(
            '[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 5)]'
            'Track 01 [aaaa]: accurately ripped (confidence 5)'
            'Track 02 [bbbb]: differs in 14 samples @00:00.50, no match in any version'
        ) -join "`n"
        $r = Get-RipperLogSummary -LogText $log
        $r.Status | Should -Be 'Suspect'
        ($r.Tracks | Where-Object Number -eq 2).Verdict | Should -Be 'Suspect'
    }

    It 'reports NotInDatabase when AR has no entry' {
        $log = '[AccurateRip: Disc not present in database]'
        $r = Get-RipperLogSummary -LogText $log
        $r.AccurateRip.Status | Should -Be 'NotInDatabase'
        $r.Status             | Should -Be 'NotInDatabase'
    }

    It 'falls back to ProbablyGood when CTDB verifies but AR confidence is 1' {
        $log = @(
            '[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 1)]'
            '[CTDB: id=xyz, all tracks accurately ripped (confidence 6)]'
            'Track 01 [aaaa]: accurately ripped (confidence 1)'
        ) -join "`n"
        $r = Get-RipperLogSummary -LogText $log
        $r.AccurateRip.MinConfidence | Should -Be 1
        $r.Ctdb.Status               | Should -Be 'Verified'
        $r.Status                    | Should -Be 'ProbablyGood'
    }

    It 'tolerates CRLF line endings' {
        $log = "[AccurateRip: Disc present in database, all tracks accurately ripped (confidence 4)]`r`nTrack 01 [aa]: accurately ripped (confidence 4)`r`n"
        $r = Get-RipperLogSummary -LogText $log
        $r.Status | Should -Be 'Verified'
    }

    It 'parses the real CUETools "tabular" log format (real-disc-test-3 fixture)' {
        # Captured from a real Spirit-of-the-Season rip on 2026-04-21.
        # AR confidence column is the FIRST number in (N/M); same for CTDB.
        # CTDB rows use a "|" separator after the track number.
        $logPath = Join-Path $PSScriptRoot 'fixtures\rip-log-spirit-of-the-season.txt'
        $log = Get-Content -Raw $logPath
        $r = Get-RipperLogSummary -LogText $log

        $r.AccurateRip.Status        | Should -Be 'Verified'
        $r.AccurateRip.TotalTracks   | Should -Be 16
        $r.AccurateRip.MatchedTracks | Should -Be 16
        $r.AccurateRip.MinConfidence | Should -Be 13   # tracks 13 + 14 are (13/35)
        $r.Ctdb.Status               | Should -Be 'Verified'
        $r.Ctdb.MinConfidence        | Should -Be 92   # several tracks are (92/95)
        $r.Status                    | Should -Be 'Verified'
    }
}

Describe 'ConvertTo-RipperEtaText' {
    It 'returns estimating... when fraction is zero' {
        $r = ConvertTo-RipperEtaText -Elapsed (New-TimeSpan -Seconds 5) -FractionDone 0
        $r.Eta | Should -Be 'estimating...'
    }

    It 'returns 0:00 ETA when fraction is 1' {
        $r = ConvertTo-RipperEtaText -Elapsed (New-TimeSpan -Minutes 5) -FractionDone 1.0
        $r.Eta | Should -Be '0:00'
    }

    It 'computes linear ETA correctly' {
        # 90s elapsed at 25% done => 270s remaining = 4:30
        $r = ConvertTo-RipperEtaText -Elapsed (New-TimeSpan -Seconds 90) -FractionDone 0.25
        $r.Elapsed | Should -Be '1:30'
        $r.Eta     | Should -Be '4:30'
    }

    It 'switches to H:MM:SS format when >= 1 hour' {
        $r = ConvertTo-RipperEtaText -Elapsed (New-TimeSpan -Hours 1 -Minutes 5) -FractionDone 0.5
        $r.Elapsed | Should -Be '1:05:00'
        $r.Eta     | Should -Be '1:05:00'
    }
}

Describe 'ConvertTo-RipperReadSpeedText' {
    It '1x = 176400 B/s' {
        ConvertTo-RipperReadSpeedText -BytesPerSecond 176400 | Should -Be '1.0x'
    }

    It '8x = 1411200 B/s' {
        ConvertTo-RipperReadSpeedText -BytesPerSecond 1411200 | Should -Be '8.0x'
    }

    It 'rounds to 1 decimal' {
        ConvertTo-RipperReadSpeedText -BytesPerSecond (176400 * 8.234) | Should -Be '8.2x'
    }

    It 'returns 0.0x for zero rate' {
        ConvertTo-RipperReadSpeedText -BytesPerSecond 0 | Should -Be '0.0x'
    }
}
