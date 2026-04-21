<#
.SYNOPSIS
    Pure-logic helpers for the MusicRipper rip pipeline.

.DESCRIPTION
    Pipeline position:
        Imported by src/core/Invoke-Rip.ps1 (Phase 4 — actively writes
        FLAC + CUE + log) and by src/core/Test-RipQuality.ps1 (Phase 5 —
        re-derives a quality verdict from a stored log file).

        Everything here is deterministic and disc-free: no SCSI, no WPF,
        no network. That's why it's testable under Pester without a CD
        in the drive.

    Functions:
        - ConvertTo-RipperTrackFilename : "01 - Title.flac" with NTFS-safe
                                          chars and zero-padded track #.
        - New-RipperCueSheet            : EAC-style CUE string built from
                                          the disc TOC + confirmed metadata
                                          + the per-track FLAC filenames.
        - ConvertFrom-RipperRipLog      : pulls AccurateRip + CTDB
                                          confidence and per-track verdicts
                                          out of the rip-log text.

.NOTES
    Per the spike doc (docs/PHASE-4-SPIKE.md §7), these helpers are the
    Pester-tested seam between the disc-touching code (which can't be
    unit-tested) and the rest of the pipeline.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Common helpers (path sanitization) live next door.
Import-Module (Join-Path $PSScriptRoot 'Common.psd1') -Force -ErrorAction Stop

function ConvertTo-RipperTrackFilename {
<#
.SYNOPSIS
    Build a per-track FLAC filename from a track number, title, and
    (optional) artist.

.DESCRIPTION
    Output shape:
        - Single-artist albums:   "01 - Title.flac"
        - Various-artists albums: "01 - Artist - Title.flac"

    The track number is zero-padded to the width needed by the largest
    track on the disc (2 digits for a normal 1..99 album, 3 if the disc
    has 100+ tracks — rare but legal). Padding makes the filenames sort
    naturally in Explorer / Plex.

    Title and artist are passed through ConvertTo-SafeWindowsPathSegment
    (Common.psm1) to strip NTFS-illegal chars deterministically. The
    rule "single-artist vs various-artists" is decided by the caller
    via -IncludeArtist.

.PARAMETER TrackNumber
    1-based track number (matches CDImageLayout / EAC / cuesheet
    conventions).

.PARAMETER TotalTracks
    Total number of tracks on the disc. Used only to pick zero-padding
    width.

.PARAMETER Title
    Track title. Passed through the path sanitizer.

.PARAMETER Artist
    Track artist. Required when -IncludeArtist is set; ignored otherwise.

.PARAMETER IncludeArtist
    Switch. When set, prefixes the artist into the filename
    ("01 - Artist - Title.flac"). Use this for compilation / Various
    Artists releases where each track may have a different performer.

.PARAMETER Extension
    File extension to append. Defaults to '.flac'. Useful for tests
    that need to assert ".flac"-vs-other behavior; production callers
    leave it at the default.

.EXAMPLE
    PS> ConvertTo-RipperTrackFilename -TrackNumber 3 -TotalTracks 12 -Title 'Hey Jude'
    03 - Hey Jude.flac

.EXAMPLE
    PS> ConvertTo-RipperTrackFilename -TrackNumber 1 -TotalTracks 12 -Title 'Sin City' -Artist 'AC/DC' -IncludeArtist
    01 - AC DC - Sin City.flac

.NOTES
    Returns the bare filename only — no directory. The caller (Invoke-Rip)
    is responsible for joining it under the per-disc output folder via
    Join-Path so we don't double up the path-sanitization logic.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateRange(1, 999)] [int]$TrackNumber,
        [Parameter(Mandatory)] [ValidateRange(1, 999)] [int]$TotalTracks,
        [Parameter(Mandatory)] [AllowEmptyString()]    [string]$Title,
        [string]$Artist,
        [switch]$IncludeArtist,
        [string]$Extension = '.flac'
    )

    if ($TrackNumber -gt $TotalTracks) {
        throw "TrackNumber ($TrackNumber) cannot exceed TotalTracks ($TotalTracks)."
    }

    # Zero-pad width: 2 for 1..99, 3 for 100+. (No real audio CD has
    # >99 tracks but the Red Book TOC field is 8-bit, so be defensive.)
    $width = if ($TotalTracks -ge 100) { 3 } else { 2 }
    $num   = $TrackNumber.ToString("D$width")

    $safeTitle = ConvertTo-SafeWindowsPathSegment -Name $Title

    $stem = if ($IncludeArtist) {
        if ([string]::IsNullOrWhiteSpace($Artist)) {
            throw "-IncludeArtist was specified but -Artist is empty."
        }
        $safeArtist = ConvertTo-SafeWindowsPathSegment -Name $Artist
        "$num - $safeArtist - $safeTitle"
    } else {
        "$num - $safeTitle"
    }

    "$stem$Extension"
}

# ---------------------------------------------------------------------------
# CUE-sheet generation
# ---------------------------------------------------------------------------

function ConvertTo-CueMsf {
<#
.SYNOPSIS
    Convert an absolute sector offset (75 sectors/sec on CD audio) to
    the MM:SS:FF string format CUE sheets use. Internal helper.

.DESCRIPTION
    CD-DA timecode: MM = minutes, SS = seconds, FF = frames (0..74,
    where 75 frames = 1 second). A 5-minute song starts at "05:00:00"
    and runs to roughly "10:00:00".

    All three components are zero-padded to 2 digits — that is what
    every CUE-aware tool (EAC, foobar2000, CUETools itself) expects.

.PARAMETER Sectors
    Non-negative sector count.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateRange(0, [int64]::MaxValue)] [int64]$Sectors
    )
    $totalFrames = [int64]$Sectors
    $minutes = [int]([math]::Floor($totalFrames / (75 * 60)))
    $seconds = [int]([math]::Floor(($totalFrames % (75 * 60)) / 75))
    $frames  = [int]($totalFrames % 75)
    '{0:D2}:{1:D2}:{2:D2}' -f $minutes, $seconds, $frames
}

function Format-CueQuoted {
<#
.SYNOPSIS
    Return a CUE-safe quoted string.

.DESCRIPTION
    The CUE format uses double-quoted strings for PERFORMER / TITLE /
    FILE etc. and offers no escape mechanism for embedded double quotes.
    Everyone who's ever written a CUE writer just replaces " with ' so
    the file parses; we do the same. We also collapse newlines/tabs
    (illegal inside a CUE token) to a single space.

    Internal helper.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Value
    )
    $clean = ($Value -replace '"', "'") -replace '[\r\n\t]+', ' '
    '"' + $clean.Trim() + '"'
}

function New-RipperCueSheet {
<#
.SYNOPSIS
    Generate an EAC-style CUE sheet for a per-track FLAC rip.

.DESCRIPTION
    Why a CUE sheet at all: combined with the per-track FLACs and the
    "append-to-previous" gap-handling rule (D-002), the CUE sheet makes
    the rip bit-exactly reconstructable back into the original disc
    image — that's the archival promise of the project.

    Why "EAC-style" specifically (cuesheet_style = eac in
    config/cuetools.profile.txt):
        - Multi-FILE form (one FILE block per FLAC), not single-FILE.
        - Track 02..N's pregap (INDEX 00) is referenced as an offset
          inside the previous track's FILE — that is the
          "noncompliant" append-to-previous layout EAC and CUETools
          both default to.
        - DCP / 4CH / PRE FLAGS are emitted per track when present.
        - CD-Text-style metadata: REM GENRE/DATE plus TITLE/PERFORMER
          at disc level, and TITLE/PERFORMER/ISRC/FLAGS at track level.

    Layout produced (empty fields are simply omitted):

        REM GENRE "Rock"
        REM DATE 1999
        REM DISCID ABCDEFGH
        REM COMMENT "MusicRipper vX.Y"
        PERFORMER "Album Artist"
        TITLE "Album"
        FILE "01 - Track 1.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track 1"
            PERFORMER "Artist"
            FLAGS PRE
            INDEX 01 00:00:00
        FILE "02 - Track 2.flac" WAVE
          TRACK 02 AUDIO
            TITLE "Track 2"
            PERFORMER "Artist"
            INDEX 00 00:00:00     # only if track 2 had a pregap, expressed
                                  # as an offset inside file 01 -- see below
            INDEX 01 00:00:00

    Pregap handling under append-to-previous: a track-N pregap of P
    sectors becomes the LAST P sectors of file (N-1). The CUE shows
    this by emitting an INDEX 00 line *inside the TRACK N block but
    referencing the END of file (N-1)* — which is the EAC noncompliant
    convention. We surface that by writing the INDEX 00 line in track
    N's block with the timecode (file-N-1-length-minus-pregap).

    Track 1 cannot have an "append to previous" pregap (there is no
    previous), so a non-zero track-1 pregap is treated as Hidden Track
    Audio (HTOA). We currently warn but otherwise skip it — the spike
    doc (§8) marks HTOA encoding as a punt.

.PARAMETER DiscId
    Disc info object as returned by Get-RipperDiscId. Required because
    we read .Tracks (with .Number, .StartSector, .LengthSectors,
    .IsAudio, .PreEmphasis), .DiscId (for REM DISCID), and
    .AudioTracks.

.PARAMETER Metadata
    Confirmed metadata object (the .Metadata property of
    Show-RipperMetadataDialog's return value). Required fields:
        Album, AlbumArtist, Year (string or int), Genre (optional),
        Tracks  : @( @{ Number; Title; Artist; Isrc (optional) }, ... )

.PARAMETER FlacFilenames
    Array of bare filenames (no path) in track-number order, matching
    1:1 with the audio tracks on the disc. Generated upstream by
    ConvertTo-RipperTrackFilename.

.PARAMETER GeneratorTag
    Optional string written into a "REM COMMENT" line so the CUE
    declares which MusicRipper version produced it. Convention:
    "MusicRipper 0.1".

.EXAMPLE
    PS> $cue = New-RipperCueSheet -DiscId $disc -Metadata $meta -FlacFilenames $names
    PS> $cue | Set-Content -LiteralPath (Join-Path $outDir 'album.cue') -Encoding UTF8

.NOTES
    Returns a single string with CRLF line endings (the de-facto
    standard for CUE files; foobar2000 / EAC both write CRLF).
    Caller decides where to write it.

    Pure-logic. No I/O, no disc access — fully Pester-testable.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [psobject]$DiscId,
        [Parameter(Mandatory)] [psobject]$Metadata,
        [Parameter(Mandatory)] [string[]]$FlacFilenames,
        [string]$GeneratorTag
    )

    # --- Validate inputs -------------------------------------------------
    $audioTracks = @($DiscId.Tracks | Where-Object IsAudio)
    if ($audioTracks.Count -eq 0) {
        throw "DiscId has no audio tracks."
    }
    if ($FlacFilenames.Count -ne $audioTracks.Count) {
        throw "FlacFilenames count ($($FlacFilenames.Count)) does not match audio-track count ($($audioTracks.Count))."
    }
    $metaTracks = @($Metadata.Tracks)
    if ($metaTracks.Count -ne $audioTracks.Count) {
        throw "Metadata.Tracks count ($($metaTracks.Count)) does not match audio-track count ($($audioTracks.Count))."
    }

    # Track 1 pregap = HTOA. We don't write it into the CUE in this
    # version — the spike doc punts on it. Emit a comment so the CUE
    # at least documents that audio was discarded.
    $htoaWarning = $null
    $firstAudio = $audioTracks[0]
    if ($firstAudio.StartSector -gt 0) {
        $htoaWarning = "Track 1 begins at sector $($firstAudio.StartSector); pregap audio (Hidden Track) was not encoded."
    }

    $sb = [System.Text.StringBuilder]::new(2048)
    $line = { param($s) [void]$sb.AppendLine($s) }

    # --- Disc-level header ----------------------------------------------
    if ($Metadata.PSObject.Properties.Name -contains 'Genre' -and -not [string]::IsNullOrWhiteSpace($Metadata.Genre)) {
        & $line ('REM GENRE ' + (Format-CueQuoted -Value $Metadata.Genre))
    }
    if ($Metadata.PSObject.Properties.Name -contains 'Year' -and $Metadata.Year) {
        & $line ('REM DATE ' + $Metadata.Year)
    }
    if ($DiscId.PSObject.Properties.Name -contains 'DiscId' -and $DiscId.DiscId) {
        & $line ('REM DISCID ' + $DiscId.DiscId)
    }
    if (-not [string]::IsNullOrWhiteSpace($GeneratorTag)) {
        & $line ('REM COMMENT ' + (Format-CueQuoted -Value $GeneratorTag))
    }
    if ($htoaWarning) {
        & $line ('REM HTOA ' + (Format-CueQuoted -Value $htoaWarning))
    }
    & $line ('PERFORMER ' + (Format-CueQuoted -Value $Metadata.AlbumArtist))
    & $line ('TITLE '     + (Format-CueQuoted -Value $Metadata.Album))

    # --- Per-track blocks ------------------------------------------------
    # Index by track number for fast lookup of "previous file".
    for ($i = 0; $i -lt $audioTracks.Count; $i++) {
        $t        = $audioTracks[$i]
        $mt       = $metaTracks[$i]
        $filename = $FlacFilenames[$i]
        $trackNum = [int]$t.Number

        & $line ('FILE ' + (Format-CueQuoted -Value $filename) + ' WAVE')
        & $line ('  TRACK {0:D2} AUDIO' -f $trackNum)

        if ($mt.PSObject.Properties.Name -contains 'Title' -and -not [string]::IsNullOrWhiteSpace($mt.Title)) {
            & $line ('    TITLE '     + (Format-CueQuoted -Value $mt.Title))
        }
        $trackArtist = if ($mt.PSObject.Properties.Name -contains 'Artist') { $mt.Artist } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($trackArtist)) {
            & $line ('    PERFORMER ' + (Format-CueQuoted -Value $trackArtist))
        }
        if ($mt.PSObject.Properties.Name -contains 'Isrc' -and -not [string]::IsNullOrWhiteSpace($mt.Isrc)) {
            & $line ('    ISRC ' + $mt.Isrc)
        }

        # FLAGS line. PRE = pre-emphasis (uncommon but happens on early
        # 80s CDs). DCP / 4CH skipped — we don't surface them through the
        # disc-id object today; can add later if a real disc shows them.
        if ($t.PSObject.Properties.Name -contains 'PreEmphasis' -and $t.PreEmphasis) {
            & $line '    FLAGS PRE'
        }

        # INDEX 00: pregap reference into the PREVIOUS file.
        # Sectors of pregap for track N = (track-N start) - (track-N-1 start) - (track-N-1 length).
        # Equivalently, the trailing pregap inside file (N-1) starts at
        # offset (file-N-1-length-pregap).
        if ($i -gt 0) {
            $prev   = $audioTracks[$i - 1]
            $prevLenSectors = [int64]$prev.LengthSectors
            $pregapSectors  = [int64]$t.StartSector - [int64]$prev.StartSector - $prevLenSectors
            if ($pregapSectors -gt 0) {
                # Append-to-previous: pregap audio is at the END of the
                # previous file. Offset within prev file:
                $offsetInPrev = $prevLenSectors  # because rip wrote prevLen + pregap into the file
                # But our LengthSectors records the *clean* (non-pregap)
                # length per-track from the TOC. The encoder will write
                # prevLen + pregap into the previous FLAC. So the pregap
                # starts at offset = prevLen.
                & $line ('    INDEX 00 ' + (ConvertTo-CueMsf -Sectors $offsetInPrev))
            }
        }

        # INDEX 01: start of the track's actual audio inside its own
        # FILE. Always 00:00:00 for per-track FLACs.
        & $line '    INDEX 01 00:00:00'
    }

    $sb.ToString() -replace "`r?`n", "`r`n"
}

# ---------------------------------------------------------------------------
# AccurateRip / CTDB log parsing
# ---------------------------------------------------------------------------

function ConvertFrom-RipperRipLog {
<#
.SYNOPSIS
    Parse a CUETools-format rip log (the output of
    AccurateRipVerify.GenerateFullLog) into a structured summary.

.DESCRIPTION
    The log is human-readable text with sections that look like:

        [Disc ID: ...]
        [AccurateRip: Disc not present in database]
        [AccurateRip: Disc present in database, all tracks accurately ripped (confidence 7)]
        [CTDB: id=..., submitted, has 12 tracks, 5 entries match]
            01 [12345678]: differs in 0 samples @00:00.00, accurately ripped (confidence 8)

    We extract only what callers actually use:
        - Per-track AccurateRip / CTDB verdict and confidence.
        - Album-level summary (worst-track verdict + min confidence).
        - A coarse Status label: 'Verified' | 'ProbablyGood' | 'Suspect'
          | 'NotInDatabase' | 'Unknown'.

    Status rules:
        - Verified      = every track AR-verified at confidence >= 2
        - ProbablyGood  = every track AR-verified at confidence 1, OR
                          CTDB-verified
        - NotInDatabase = "Disc not present in database" everywhere
        - Suspect       = any track flagged as differing / unverified
        - Unknown       = log shape didn't match any known pattern

.PARAMETER LogText
    Full log text (multi-line string). May have CRLF or LF line endings.

.EXAMPLE
    PS> $summary = ConvertFrom-RipperRipLog -LogText (Get-Content -Raw $logPath)
    PS> $summary.Status
    Verified

.NOTES
    Fully pure (string -> object). Used by Phase 4 to populate the
    Invoke-Rip return value AND by Phase 5 (Test-RipQuality) to
    re-verify a stored log.

    Be lenient about exact wording: CUETools tweaks log formatting
    between versions. Prefer permissive regexes; on no-match return
    Status='Unknown' rather than throwing.
#>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$LogText
    )

    $text = ($LogText -replace "`r`n", "`n").Trim()

    $result = [pscustomobject]@{
        Status         = 'Unknown'
        AccurateRip    = [pscustomobject]@{ Status = 'Unknown'; MatchedTracks = 0; TotalTracks = 0; MinConfidence = $null }
        Ctdb           = [pscustomobject]@{ Status = 'Unknown'; MatchedTracks = 0; TotalTracks = 0; MinConfidence = $null }
        Tracks         = @()
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $result
    }

    # --- AR status line --------------------------------------------------
    $arNotPresent = $text -match '(?im)^\[?AccurateRip[:\]].*not present.*database'
    $arAllAccurate = $text -match '(?im)^\[?AccurateRip[:\]].*accurately ripped(?:.*confidence\s+(\d+))?'
    if ($arAllAccurate) {
        $result.AccurateRip.Status = 'Verified'
        if ($Matches.Count -gt 1 -and $Matches[1]) {
            $result.AccurateRip.MinConfidence = [int]$Matches[1]
        }
    } elseif ($arNotPresent) {
        $result.AccurateRip.Status = 'NotInDatabase'
    }

    # --- CTDB status line ------------------------------------------------
    $ctdbAllMatch = $text -match '(?im)^\[?CTDB[:\]].*all tracks accurately ripped(?:.*confidence\s+(\d+))?'
    $ctdbPartial  = $text -match '(?im)^\[?CTDB[:\]].*?(\d+)\s+entries?\s+match'
    if ($ctdbAllMatch) {
        $result.Ctdb.Status = 'Verified'
        if ($Matches.Count -gt 1 -and $Matches[1]) {
            $result.Ctdb.MinConfidence = [int]$Matches[1]
        }
    } elseif ($ctdbPartial) {
        $result.Ctdb.Status = 'Partial'
    }

    # --- Per-track lines -------------------------------------------------
    # Patterns vary by version; both of these appear in the wild:
    #   "Track 01 [crc]: differs in 0 samples @ 00:00.00, accurately ripped (confidence 8)"
    #   "01: AccurateRip-verified, confidence 7"
    $trackLines = New-Object System.Collections.Generic.List[psobject]
    $rxFull = '(?im)^\s*(?:Track\s+)?(\d{1,3})\b.*?(accurately\s+ripped|differs?|unverified|not\s+present)(?:.*?confidence\s+(\d+))?'
    foreach ($m in [regex]::Matches($text, $rxFull)) {
        $verdict = ($m.Groups[2].Value -replace '\s+', ' ').ToLowerInvariant()
        $verdictClass = switch -Regex ($verdict) {
            'accurately'   { 'Verified';      break }
            'differ'       { 'Suspect';       break }
            'unverified'   { 'Unverified';    break }
            'not present'  { 'NotInDatabase'; break }
            default        { 'Unknown' }
        }
        $confidence = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $null }
        $trackLines.Add([pscustomobject]@{
            Number     = [int]$m.Groups[1].Value
            Verdict    = $verdictClass
            Confidence = $confidence
        })
    }
    $result.Tracks = @($trackLines | Sort-Object Number -Unique)

    if ($result.Tracks.Count -gt 0) {
        $result.AccurateRip.TotalTracks  = $result.Tracks.Count
        $verifiedCount = @($result.Tracks | Where-Object Verdict -eq 'Verified').Count
        $result.AccurateRip.MatchedTracks = $verifiedCount
        $confidences = @($result.Tracks | Where-Object { $_.Confidence -ne $null } | ForEach-Object Confidence)
        if ($confidences.Count -gt 0) {
            $minConf = ($confidences | Measure-Object -Minimum).Minimum
            if (-not $result.AccurateRip.MinConfidence) {
                $result.AccurateRip.MinConfidence = [int]$minConf
            }
        }
    }

    # --- Roll up Status --------------------------------------------------
    $allVerified  = $result.Tracks.Count -gt 0 -and (@($result.Tracks | Where-Object Verdict -ne 'Verified').Count -eq 0)
    $anySuspect   = @($result.Tracks | Where-Object Verdict -eq 'Suspect').Count -gt 0
    $allNotInDb   = $result.Tracks.Count -gt 0 -and (@($result.Tracks | Where-Object Verdict -ne 'NotInDatabase').Count -eq 0)

    $result.Status = if ($anySuspect) {
        'Suspect'
    } elseif ($allVerified) {
        if ($result.AccurateRip.MinConfidence -and $result.AccurateRip.MinConfidence -ge 2) {
            'Verified'
        } else {
            'ProbablyGood'
        }
    } elseif ($result.Ctdb.Status -eq 'Verified') {
        'ProbablyGood'
    } elseif ($allNotInDb -or $result.AccurateRip.Status -eq 'NotInDatabase') {
        'NotInDatabase'
    } else {
        'Unknown'
    }

    $result
}

Export-ModuleMember -Function ConvertTo-RipperTrackFilename, New-RipperCueSheet, ConvertFrom-RipperRipLog
