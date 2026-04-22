<#
    Pester tests for src/core/New-ReviewQueueArtifacts.ps1.

    Pure helpers (New-RipperReviewTxt, New-RipperReviewImageCueText) are
    fully tested. Write-RipperReviewTxt is exercised end-to-end against
    a temp folder. New-RipperReviewImage is exercised against the real
    flac.exe + a real .flac fixture under tests/samples/ (gitignored;
    drop one in manually). Tests skip cleanly if either is missing.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'src\core\New-ReviewQueueArtifacts.ps1')
    # Get-RipperRipFolderTracks lives in Write-Tags.ps1 — the production
    # path dot-sources it lazily; tests need it eagerly.
    . (Join-Path $script:repoRoot 'src\core\Write-Tags.ps1')

    function script:New-FakeQuality {
        param([string]$Prefix = 'SUSPECT', [string]$Reason = 'AR confidence below threshold.')
        [pscustomobject]@{ Status='Suspect'; RoutingPrefix=$Prefix; Reason=$Reason }
    }

    function script:New-FakeMetadata {
        [pscustomobject]@{
            AlbumArtist = 'Mormon Tabernacle Choir'
            Album       = 'Spirit of the Season'
            Year        = 2007
            ReleaseMbid = 'rel-mbid-abc'
            Tracks      = @(
                [pscustomobject]@{ Number=1; Title='Carol of the Bells'; LengthMs=180000 },
                [pscustomobject]@{ Number=2; Title='Silent Night';        LengthMs=200000 }
            )
        }
    }
}

Describe 'New-RipperReviewTxt' {
    It 'emits all required keys for SUSPECT' {
        $body = New-RipperReviewTxt -Quality (New-FakeQuality) -Metadata (New-FakeMetadata) `
                    -DiscId 'abc' -LogFileName 'Spirit.log' `
                    -RipDate ([datetime]'2026-04-21 09:30:00')
        $body | Should -Match 'Reason:\s+SUSPECT - AR confidence below threshold\.'
        $body | Should -Match 'Album:\s+Mormon Tabernacle Choir - Spirit of the Season'
        $body | Should -Match 'RipDate:\s+2026-04-21 09:30:00'
        $body | Should -Match 'DiscId:\s+abc'
        $body | Should -Match 'MusicBrainzMatch:\s+rel-mbid-abc'
        $body | Should -Match 'Tracks:\s+2'
        $body | Should -Match 'Duration:\s+6m20s'   # 180s + 200s = 380s = 6m20s
        $body | Should -Match 'SuggestedAction:\s+Re-rip'
        $body | Should -Match 'LogFile:\s+Spirit\.log'
    }

    It 'reports MusicBrainzMatch=none when Metadata is null (UNKNOWN case)' {
        $body = New-RipperReviewTxt -Quality (New-FakeQuality 'UNKNOWN' 'No MB match.') `
                    -Metadata $null -DiscId 'abc' -LogFileName 'rip.log'
        $body | Should -Match 'MusicBrainzMatch:\s+none'
        $body | Should -Match 'Album:\s+\(unknown\) - \(unknown\)'
        $body | Should -Match 'Tracks:\s+0'
        $body | Should -Match 'Duration:\s+0m00s'
        $body | Should -Match 'SuggestedAction:\s+Drop folder into MusicBrainz Picard'
    }

    It 'switches SuggestedAction text per prefix' {
        (New-RipperReviewTxt -Quality (New-FakeQuality 'LOWMATCH') -Metadata (New-FakeMetadata) `
            -DiscId 'd' -LogFileName 'r.log') | Should -Match 'Verify match in MusicBrainz Picard'
        (New-RipperReviewTxt -Quality (New-FakeQuality 'MANUAL')   -Metadata (New-FakeMetadata) `
            -DiscId 'd' -LogFileName 'r.log') | Should -Match 'Move-FromReviewQueue'
    }

    It 'honours an explicit -MusicBrainzMatch override' {
        $body = New-RipperReviewTxt -Quality (New-FakeQuality 'LOWMATCH') -Metadata (New-FakeMetadata) `
                    -DiscId 'd' -LogFileName 'r.log' -MusicBrainzMatch 'low-confidence:42%'
        $body | Should -Match 'MusicBrainzMatch:\s+low-confidence:42%'
    }

    It 'uses CRLF line endings (Windows-friendly)' {
        $body = New-RipperReviewTxt -Quality (New-FakeQuality) -Metadata (New-FakeMetadata) `
                    -DiscId 'd' -LogFileName 'r.log'
        $body | Should -Match "`r`n"
    }
}

Describe 'New-RipperReviewImageCueText' {
    It 'emits a single FILE entry with cumulative INDEX 01 timestamps' {
        $cue = New-RipperReviewImageCueText -ImageFileName 'Spirit.flac' `
                    -AlbumArtist 'Choir' -Album 'Spirit' -Year 2007 `
                    -DiscId 'abc' `
                    -TrackTitles @('Bells','Silent') `
                    -TrackTotalSamples @(44100L, 88200L)   # 1s, 2s

        $files = ($cue -split "`r`n") | Where-Object { $_ -like 'FILE *' }
        @($files).Count | Should -Be 1
        $cue | Should -Match 'FILE "Spirit\.flac" WAVE'

        # Two tracks; INDEX 01 of track 1 is 00:00:00, of track 2 is 00:01:00 (1s).
        $cue | Should -Match '  TRACK 01 AUDIO'
        $cue | Should -Match '  TRACK 02 AUDIO'
        $cue | Should -Match '    INDEX 01 00:00:00'
        $cue | Should -Match '    INDEX 01 00:01:00'
        $cue | Should -Match 'REM DATE 2007'
        $cue | Should -Match 'REM DISCID abc'
        $cue | Should -Match 'PERFORMER "Choir"'
        $cue | Should -Match 'TITLE "Spirit"'
    }

    It 'escapes embedded double quotes by replacing with single quotes' {
        $cue = New-RipperReviewImageCueText -ImageFileName 'a.flac' `
                    -AlbumArtist 'Foo' -Album 'B"ar' `
                    -TrackTitles @('Hi"There') -TrackTotalSamples @(44100L)
        $cue | Should -Match 'TITLE "B''ar"'
        $cue | Should -Match 'TITLE "Hi''There"'
    }

    It 'throws when titles and sample counts disagree in length' {
        { New-RipperReviewImageCueText -ImageFileName 'a.flac' -AlbumArtist 'A' -Album 'B' `
              -TrackTitles @('X','Y') -TrackTotalSamples @(44100L) } |
            Should -Throw '*must have the same length*'
    }

    It 'uses CRLF line endings' {
        $cue = New-RipperReviewImageCueText -ImageFileName 'a.flac' -AlbumArtist 'A' -Album 'B' `
                    -TrackTitles @('X') -TrackTotalSamples @(44100L)
        $cue | Should -Match "`r`n"
    }
}

Describe 'Write-RipperReviewTxt (integration)' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "rqa-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes REVIEW.txt as UTF-8 without BOM' {
        $path = Write-RipperReviewTxt -ReviewFolder $script:tmp -Quality (New-FakeQuality) `
                    -Metadata (New-FakeMetadata) -DiscId 'abc' -LogFileName 'r.log'
        $path | Should -Be (Join-Path $script:tmp 'REVIEW.txt')
        Test-Path -LiteralPath $path | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($path)
        # First three bytes should NOT be the UTF-8 BOM (EF BB BF).
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        # Should round-trip the SUSPECT reason line.
        ([IO.File]::ReadAllText($path)) | Should -Match 'Reason:\s+SUSPECT'
    }

    It 'throws when the review folder does not exist' {
        { Write-RipperReviewTxt -ReviewFolder (Join-Path $script:tmp 'nope') -Quality (New-FakeQuality) `
              -Metadata (New-FakeMetadata) -DiscId 'd' -LogFileName 'r.log' } |
            Should -Throw '*not found*'
    }
}

Describe 'New-RipperReviewImage (real-flac integration)' {
    # The previous version of this Describe shelled out to a hand-rolled
    # cmd.exe stub. That worked but was intermittently flaky (~10-20% of
    # full suite runs) — cmd.exe argv parsing of paths-with-spaces is
    # unreliable in ways we couldn't fully pin down. Switching to a real
    # flac.exe + a real .flac fixture made the failure mode disappear and
    # is a much stronger end-to-end check anyway.
    #
    # Setup:
    #   - Locate flac.exe (PATH first, then EAC's bundled copy, then
    #     standard install dirs).
    #   - Pick the SMALLEST .flac in tests/fixtures/. *.flac is
    #     gitignored — developers drop a sample in manually. CI /
    #     fresh clones skip these tests cleanly.
    BeforeAll {
        $script:realFlac = $null
        $candidates = @()
        $cmd = Get-Command flac.exe -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
        $candidates += @(
            'C:\Program Files\FLAC\flac.exe',
            'C:\Program Files (x86)\FLAC\flac.exe',
            'C:\Program Files (x86)\Exact Audio Copy\Flac\flac.exe'
        )
        foreach ($cand in $candidates) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $script:realFlac = $cand; break }
        }

        $script:fixtureFlac = $null
        $fixturesDir = Join-Path $script:repoRoot 'tests\fixtures'
        if (Test-Path -LiteralPath $fixturesDir) {
            $candidate = Get-ChildItem -LiteralPath $fixturesDir -Filter *.flac -Recurse `
                            -ErrorAction SilentlyContinue |
                         Sort-Object Length | Select-Object -First 1
            if ($candidate) { $script:fixtureFlac = $candidate.FullName }
        }

        $script:skipReason =
            if (-not $script:realFlac)    { 'flac.exe not found on PATH or in standard install locations' }
            elseif (-not $script:fixtureFlac) { 'No .flac fixture under tests/fixtures/ (drop one in to enable these tests)' }
            else { $null }
    }

    BeforeEach {
        $script:rev = Join-Path ([IO.Path]::GetTempPath()) "rqa-rev-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path $script:rev | Out-Null
        if ($script:fixtureFlac) {
            # Copy the same fixture in twice as tracks 01 and 02 so we
            # exercise the multi-track concatenation path.
            Copy-Item -LiteralPath $script:fixtureFlac `
                -Destination (Join-Path $script:rev '01 - Carol of the Bells.flac')
            Copy-Item -LiteralPath $script:fixtureFlac `
                -Destination (Join-Path $script:rev '02 - Silent Night.flac')
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:rev -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates the _image folder with album.flac + .cue and removes the temp .raw' {
        if ($script:skipReason) { Set-ItResult -Skipped -Because $script:skipReason; return }
        $result = New-RipperReviewImage -ReviewFolder $script:rev -Metadata (New-FakeMetadata) `
                      -DiscId 'abc' -FlacPath $script:realFlac
        $result.Tracks | Should -Be 2
        $imagePath = Join-Path $script:rev '_image\Spirit of the Season.flac'
        $cuePath   = Join-Path $script:rev '_image\Spirit of the Season.cue'
        Test-Path -LiteralPath $imagePath | Should -BeTrue
        Test-Path -LiteralPath $cuePath   | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:rev '_image\Spirit of the Season.raw') | Should -BeFalse

        # Verify the produced image is actually a valid FLAC stream:
        # FLAC magic = 'fLaC' (0x66 0x4C 0x61 0x43) at offset 0.
        $bytes = [IO.File]::ReadAllBytes($imagePath)
        $bytes.Length | Should -BeGreaterThan 4
        ($bytes[0..3] -join ',') | Should -Be ([byte[]](0x66,0x4C,0x61,0x43) -join ',')
    }

    It 'embeds cumulative INDEX 01 timestamps in the cue (track 2 starts after track 1 length)' {
        if ($script:skipReason) { Set-ItResult -Skipped -Because $script:skipReason; return }
        New-RipperReviewImage -ReviewFolder $script:rev -Metadata (New-FakeMetadata) `
            -DiscId 'd' -FlacPath $script:realFlac | Out-Null
        $cueLines = Get-Content -LiteralPath (Join-Path $script:rev '_image\Spirit of the Season.cue')
        @($cueLines | Where-Object { $_ -like '*FILE *' }).Count | Should -Be 1
        @($cueLines | Where-Object { $_ -like '*TRACK 01 AUDIO*' }).Count | Should -Be 1
        @($cueLines | Where-Object { $_ -like '*TRACK 02 AUDIO*' }).Count | Should -Be 1
        # Track 1 always starts at 00:00:00.
        ($cueLines -join "`n") | Should -Match 'TRACK 01 AUDIO[\s\S]*INDEX 01 00:00:00'
        # Track 2 must start strictly after the start of track 1 (some
        # nonzero MM:SS:FF). Exact offset depends on the fixture length,
        # but it can't be 00:00:00 if both tracks have audio.
        ($cueLines -join "`n") | Should -Not -Match 'TRACK 02 AUDIO[\s\S]*?INDEX 01 00:00:00\b'
    }

    It 'returns $null and logs a warning when flac.exe is missing' {
        # This case doesn't need the real flac, but it does need a temp
        # folder with at least one track-shaped FLAC file.
        if (-not $script:fixtureFlac) {
            # Fall back to a zero-byte .flac so Get-RipperRipFolderTracks
            # finds something — the function returns before we try to
            # decode anything.
            New-Item -ItemType File -Path (Join-Path $script:rev '01 - dummy.flac') | Out-Null
        }
        $result = New-RipperReviewImage -ReviewFolder $script:rev -Metadata (New-FakeMetadata) `
                      -DiscId 'd' -FlacPath (Join-Path $env:TEMP 'no-such-flac.exe')
        $result | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:rev '_image') | Should -BeFalse
    }

    It 'handles missing Metadata (UNKNOWN case) with _unknown_ album name' {
        if ($script:skipReason) { Set-ItResult -Skipped -Because $script:skipReason; return }
        $result = New-RipperReviewImage -ReviewFolder $script:rev -Metadata $null `
                      -DiscId 'abc' -FlacPath $script:realFlac
        $result.ImagePath | Should -BeLike '*\_image\_unknown_.flac'
        $result.CuePath   | Should -BeLike '*\_image\_unknown_.cue'
    }
}

