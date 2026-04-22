<#
    Pester tests for src/core/New-ReviewQueueArtifacts.ps1.

    Pure helpers (New-RipperReviewTxt, New-RipperReviewImageCueText) are
    fully tested. Write-RipperReviewTxt is exercised end-to-end against
    a temp folder. New-RipperReviewImage is exercised against a stub
    flac.cmd that emits a fixed PCM blob — enough to lock in argv shape
    and per-track sample-count math without a real FLAC decode path.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\New-ReviewQueueArtifacts.ps1')
    # Get-RipperRipFolderTracks lives in Write-Tags.ps1 — the production
    # path dot-sources it lazily; tests need it eagerly.
    . (Join-Path $repoRoot 'src\core\Write-Tags.ps1')

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

Describe 'New-RipperReviewImage (stub-flac integration)' {
    BeforeAll {
        # Stub flac.cmd: produces a 4-byte payload per "decode" (= 1 stereo
        # sample) so we can verify the per-track sample math. Encode mode
        # just creates a dummy output file. Argv is logged for assertion.
        $script:stubDir = Join-Path ([IO.Path]::GetTempPath()) "rqa-flac-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path $script:stubDir | Out-Null
        $script:stubLog = Join-Path $script:stubDir 'flac-calls.log'
        $script:stubExe = Join-Path $script:stubDir 'flac.cmd'
        # 1 CD frame = 588 samples * 4 bytes (16-bit stereo) = 2352 bytes.
        # The decode-mode stub `type`s this payload to stdout once per call,
        # so per-track sample counts come out as exact multiples of 588.
        $script:stubPayload = Join-Path $script:stubDir 'payload.bin'
        [IO.File]::WriteAllBytes($script:stubPayload, (New-Object byte[] 2352))
@"
@echo off
echo %*>>"$script:stubLog"
:: Decode mode (-d) writes one CD frame (2352 raw bytes) to stdout.
echo %* | findstr /C:"-d" >nul
if not errorlevel 1 (
  type "$script:stubPayload"
  exit /b 0
)
:: Encode mode: locate the -o argument and create a 1-byte placeholder file.
set "out="
set "next="
for %%a in (%*) do (
  if defined next ( set "out=%%~a" & set "next=" )
  if "%%~a"=="-o" set "next=1"
)
if defined out (
  echo flac > "%out%"
)
exit /b 0
"@ | Set-Content -LiteralPath $script:stubExe -Encoding ASCII
    }
    AfterAll {
        Remove-Item -LiteralPath $script:stubDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        if (Test-Path -LiteralPath $script:stubLog) { Remove-Item -LiteralPath $script:stubLog }
        $script:rev = Join-Path ([IO.Path]::GetTempPath()) "rqa-rev-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path $script:rev | Out-Null
        '01 - Carol of the Bells.flac','02 - Silent Night.flac' |
            ForEach-Object { New-Item -ItemType File -Path (Join-Path $script:rev $_) | Out-Null }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:rev -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates the _image folder with album.flac + .cue and removes the temp .raw' {
        $result = New-RipperReviewImage -ReviewFolder $script:rev -Metadata (New-FakeMetadata) `
                      -DiscId 'abc' -FlacPath $script:stubExe
        $result.Tracks | Should -Be 2
        Test-Path -LiteralPath (Join-Path $script:rev '_image\Spirit of the Season.flac') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:rev '_image\Spirit of the Season.cue')  | Should -BeTrue
        # Temp .raw must be cleaned up.
        Test-Path -LiteralPath (Join-Path $script:rev '_image\Spirit of the Season.raw')  | Should -BeFalse
    }

    It 'invokes flac.exe once per track in decode mode + once for encode' {
        New-RipperReviewImage -ReviewFolder $script:rev -Metadata (New-FakeMetadata) `
            -DiscId 'd' -FlacPath $script:stubExe | Out-Null
        $lines = Get-Content -LiteralPath $script:stubLog
        # 2 decode calls + 1 encode call = 3 total.
        @($lines).Count | Should -Be 3
        @($lines | Where-Object { $_ -like '*-d*--stdout*' }).Count | Should -Be 2
        @($lines | Where-Object { $_ -like '*--force-raw-format*-o*' }).Count | Should -Be 1
    }

    It 'returns $null and logs a warning when flac.exe is missing' {
        $result = New-RipperReviewImage -ReviewFolder $script:rev -Metadata (New-FakeMetadata) `
                      -DiscId 'd' -FlacPath (Join-Path $script:stubDir 'no-such-flac.exe')
        $result | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:rev '_image') | Should -BeFalse
    }

    It 'handles missing Metadata (UNKNOWN case) with _unknown_ album name' {
        $result = New-RipperReviewImage -ReviewFolder $script:rev -Metadata $null `
                      -DiscId 'abc' -FlacPath $script:stubExe
        $result.ImagePath | Should -BeLike '*\_image\_unknown_.flac'
        $result.CuePath   | Should -BeLike '*\_image\_unknown_.cue'
    }
}
