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

    It 'includes artist when -IsCompilation set' {
        New-RipperTrackFileName -TrackNumber 1 -Title 'Foo' -TotalTracks 10 `
            -Artist 'Bar' -IsCompilation |
            Should -Be '01 - Bar - Foo.flac'
    }

    It 'sanitizes NTFS-illegal chars in title and artist independently' {
        $r = New-RipperTrackFileName -TrackNumber 2 -Title 'AC/DC: Live' `
                -TotalTracks 9 -Artist 'AC/DC' -IsCompilation
        $r | Should -Be '02 - AC DC - AC DC Live.flac'
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
        # Hashtable-shaped layout mimics CDImageLayout enough for the
        # generator to consume. Two audio tracks, no pregaps, no flags.
        $script:layout = @{
            TrackCount = 2
            Tracks = @(
                @{ Number = 1; IsAudio = $true; PregapFrames = 0; ISRC = ''; DCP = $false; PreEmphasis = $false }
                @{ Number = 2; IsAudio = $true; PregapFrames = 0; ISRC = ''; DCP = $false; PreEmphasis = $false }
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
        $layout1 = @{ TrackCount = 1; Tracks = @(@{ Number = 1; IsAudio = $true; PregapFrames = 0 }) }
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
            Tracks = @(@{ Number = 1; IsAudio = $true; PregapFrames = 0;
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
            Tracks = @(@{ Number = 1; IsAudio = $true; PregapFrames = 0;
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
    It 'returns unknown structure for empty input' {
        $r = Get-RipperLogSummary -LogText ''
        $r.AccurateRip.Status | Should -Be 'unknown'
        $r.Ctdb.Status        | Should -Be 'unknown'
        $r.FailedSectors      | Should -BeNullOrEmpty
    }

    It 'parses fully-verified AccurateRip block' {
        $log = @"
Track  1: AccurateRip: confidence 12
Track  2: AccurateRip: confidence 10
Track  3: AccurateRip: confidence 9
"@
        $r = Get-RipperLogSummary -LogText $log
        $r.AccurateRip.TotalTracks    | Should -Be 3
        $r.AccurateRip.MatchedTracks  | Should -Be 3
        $r.AccurateRip.Confidences    | Should -Be @(12, 10, 9)
        $r.AccurateRip.Status         | Should -Be 'verified'
    }

    It 'reports partial when some tracks not present' {
        $log = @"
Track  1: AccurateRip: confidence 5
Track  2: AccurateRip: not present
Track  3: AccurateRip: confidence 7
"@
        $r = Get-RipperLogSummary -LogText $log
        $r.AccurateRip.Status        | Should -Be 'partial'
        $r.AccurateRip.MatchedTracks | Should -Be 2
        $r.AccurateRip.TotalTracks   | Should -Be 3
    }

    It 'reports notpresent when ALL tracks missing from AR' {
        $log = "Track  1: AccurateRip: not present`nTrack  2: AccurateRip: not present"
        $r = Get-RipperLogSummary -LogText $log
        $r.AccurateRip.Status | Should -Be 'notpresent'
    }

    It 'parses CTDB verified with confidence' {
        $r = Get-RipperLogSummary -LogText 'CTDB: verified (confidence 14)'
        $r.Ctdb.Status     | Should -Be 'verified'
        $r.Ctdb.Confidence | Should -Be 14
    }

    It 'parses CTDB differ' {
        $r = Get-RipperLogSummary -LogText 'CTDB: differ'
        $r.Ctdb.Status | Should -Be 'differ'
    }

    It 'parses CTDB not present' {
        $r = Get-RipperLogSummary -LogText 'CTDB: not present'
        $r.Ctdb.Status | Should -Be 'notpresent'
    }

    It 'parses Failed sectors count' {
        $r = Get-RipperLogSummary -LogText "Failed sectors: 0`nFailed sectors: ignore-me"
        $r.FailedSectors | Should -Be 0
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
