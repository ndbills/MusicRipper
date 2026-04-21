<#
.SYNOPSIS
    Pure-logic helpers for the Phase 4 rip pipeline (no I/O, no hardware).

.DESCRIPTION
    Pipeline position:
        Imported by src/core/Invoke-Rip.ps1 and src/ui/Show-RipProgress.ps1
        in Phase 4. Everything in this module is deterministic and pure so
        it can be unit-tested in tests/RipHelpers.Tests.ps1 without a CD,
        without WPF, and without any CUETools DLLs loaded.

    What lives here (and why):
        - New-RipperTrackFileName       -> per-track sanitized filename
                                           ("01 - Artist - Title.flac").
                                           Track-number prefix makes
                                           same-disc collisions impossible.
        - New-RipperCueSheet             -> EAC-style CUE sheet text from
                                           a CUETools CDImageLayout +
                                           confirmed metadata.
        - Get-RipperLogSummary           -> parse AccurateRip / CTDB
                                           confidence out of the log text
                                           emitted by AccurateRipVerify
                                           .GenerateFullLog().
        - ConvertTo-RipperEtaText        -> format elapsed + ETA strings
                                           for the progress window.
        - ConvertTo-RipperReadSpeedText  -> format CD read speed ("8.2x")
                                           from bytes/sec.

    What does NOT belong here:
        - CDDriveReader / Flake / AccurateRipVerify lifecycle. That's
          src/core/Invoke-Rip.ps1's job.
        - WPF / dispatcher marshaling. That's src/ui/Show-RipProgress.ps1.
        - File I/O. Helpers return strings/objects; the caller writes.

.NOTES
    Per the Phase 4 spike (docs/PHASE-4-SPIKE.md §7), the pieces of the
    rip pipeline that are pure logic get Pester coverage; everything that
    touches a disc or WPF window gets manual verification.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Module-private: full set of NTFS-illegal chars + control chars. Reused by
# the per-track filename builder. (Folder-level sanitization lives in the
# Common module's ConvertTo-SafeWindowsPathSegment; we don't reuse that one
# directly because filenames need a slightly different policy — we want to
# preserve the explicit dash separators we insert between fields.)
$script:IllegalFileChars = '<>:"/\|?*'

function New-RipperTrackFileName {
<#
.SYNOPSIS
    Build a Windows-safe per-track FLAC filename for one track of an album.

.DESCRIPTION
    Output pattern (matches the de-facto standard most music libraries
    expect: Plex, Navidrome, Jellyfin, Foobar):

        "<NN> - <Title>.flac"                       (single-artist album)
        "<NN> - <Artist> - <Title>.flac"            (compilation: per-track
                                                     artist differs from
                                                     the album artist)

    Where:
        NN     = zero-padded track number (width = digits in TotalTracks,
                 minimum 2). So a 9-track album gets "01..09"; a 12-track
                 album gets "01..12"; a 100-track box set gets "001..100".
        Title  = the user-confirmed track title (post-sanitization).
        Artist = the user-confirmed per-track artist (post-sanitization),
                 only included when -IsCompilation is set.

    Sanitization rules (per-segment, applied to Artist and Title separately
    so a slash in a title can't escape into the path):
        1. Replace each NTFS-illegal char ( < > : " / \ | ? * ) with a space.
        2. Replace every control char (U+0000-U+001F) with a space.
        3. Collapse whitespace runs to one space.
        4. Trim.
        5. Strip trailing dots/spaces (Windows silently drops them).
        6. If the result is empty, substitute '_unknown_'.

    Collision policy: idempotent. The function does not deduplicate against
    other tracks — that's the caller's job (Resolve-RipperFileNameCollisions
    below). We keep this function single-track so it's trivial to unit-test.

.PARAMETER TrackNumber
    1-based track number on the disc.

.PARAMETER Title
    User-confirmed track title (post-edit from Phase 3 dialog).

.PARAMETER TotalTracks
    Total audio tracks on the disc (controls zero-padding width).

.PARAMETER Artist
    Per-track artist (post-edit). Only used when -IsCompilation is set.

.PARAMETER IsCompilation
    Switch. When set, prepends "<Artist> - " between the track number and
    the title. Mirrors the disc's IsCompilation flag in the metadata
    object — but we accept it as an explicit parameter (not derived) so
    a caller who wants per-track-artist filenames on a non-compilation
    can opt in.

.EXAMPLE
    PS> New-RipperTrackFileName -TrackNumber 3 -Title 'Hey Jude' -TotalTracks 12
    03 - Hey Jude.flac

.EXAMPLE
    PS> New-RipperTrackFileName -TrackNumber 1 -Title 'AC/DC: Live' `
            -TotalTracks 9 -Artist 'AC/DC' -IsCompilation
    01 - AC DC - AC DC  Live.flac
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateRange(1, 9999)] [int]$TrackNumber,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Title,
        [Parameter(Mandatory)] [ValidateRange(1, 9999)] [int]$TotalTracks,
        [string]$Artist,
        [switch]$IsCompilation
    )

    $width  = [Math]::Max(2, ([string]$TotalTracks).Length)
    $numStr = $TrackNumber.ToString("D$width")

    $titleSafe  = _SanitizeTrackField -Value $Title
    $parts = @($numStr, '-', $titleSafe)

    if ($IsCompilation) {
        $artistSafe = _SanitizeTrackField -Value $Artist
        $parts = @($numStr, '-', $artistSafe, '-', $titleSafe)
    }

    "$($parts -join ' ').flac"
}

function _SanitizeTrackField {
    # Module-private. Applies the per-field rules described in
    # New-RipperTrackFileName. Underscore-prefixed name is the convention
    # we've used elsewhere for "do not export, do not call from outside".
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [AllowNull()] [string]$Value)

    if ($null -eq $Value) { return '_unknown_' }

    $sb = [System.Text.StringBuilder]::new($Value.Length)
    foreach ($ch in $Value.ToCharArray()) {
        if ($script:IllegalFileChars.Contains($ch) -or [int]$ch -lt 32) {
            [void]$sb.Append(' ')
        } else {
            [void]$sb.Append($ch)
        }
    }
    $s = ($sb.ToString() -replace '\s+', ' ').Trim()
    $s = $s.TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($s)) { return '_unknown_' }
    $s
}

function ConvertTo-RipperCueTime {
<#
.SYNOPSIS
    Convert an absolute sample offset (44100 Hz stereo) to MM:SS:FF
    CD-DA frame timing.

.DESCRIPTION
    CD-DA is 75 frames/sec, 588 samples/frame. The CUE-sheet format wants
    "MM:SS:FF" where FF is 0-74. This helper exists separately because
    we use it both in CUE generation and in the progress window's
    "Track 04 — 01:23 / 03:45" readout.

    Input must be a non-negative whole-frame offset. The CUETools layout
    we get from CDDriveReader.TOC always lands on frame boundaries, so
    rejecting non-multiples-of-588 here is a useful invariant check
    (catches off-by-one errors in callers).

.PARAMETER Samples
    Absolute sample offset from start-of-disc.

.EXAMPLE
    PS> ConvertTo-RipperCueTime -Samples 44100
    00:01:00

.EXAMPLE
    PS> ConvertTo-RipperCueTime -Samples 0
    00:00:00
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateRange(0, [long]::MaxValue)] [long]$Samples
    )

    if ($Samples % 588 -ne 0) {
        throw "Samples ($Samples) is not a whole number of CD frames (588 samples each)."
    }
    $totalFrames = [long]($Samples / 588)
    $ff = [int]($totalFrames % 75)
    $totalSeconds = [long](($totalFrames - $ff) / 75)
    $ss = [int]($totalSeconds % 60)
    $mm = [int](($totalSeconds - $ss) / 60)
    "{0:D2}:{1:D2}:{2:D2}" -f $mm, $ss, $ff
}

function New-RipperCueSheet {
<#
.SYNOPSIS
    Generate an EAC-style CUE sheet referencing per-track FLAC files.

.DESCRIPTION
    Output: a CUE sheet string in the EAC dialect (which is what CUETools,
    foobar, and the hydrogenaud.io community treat as canonical). One
    FILE entry per track (because we rip per-track FLAC, not single-file
    image). INDEX 00 (pregap) only emitted when the layout reports a
    non-zero pregap for that track — the standard "EAC append-to-previous"
    convention is that the pregap audio lives at the END of the previous
    file, so INDEX 00 here points to that end-of-previous offset (00:00:00
    relative to *this* track's file means "this file starts at INDEX 01
    immediately"). For the simple case where pregap is zero we omit
    INDEX 00 entirely.

    Header fields included (in EAC's canonical order):
        REM GENRE                     - if Metadata.Genre present
        REM DATE                      - Metadata.Year
        REM DISCID                    - DiscIdInfo.DiscId (MusicBrainz)
        REM COMMENT "MusicRipper vN"  - tool tag
        PERFORMER "<AlbumArtist>"
        TITLE     "<Album>"

    Per-track block:
        FILE "<basename>.flac" WAVE
          TRACK NN AUDIO
            TITLE     "<Title>"
            PERFORMER "<Artist>"        (omitted when == AlbumArtist)
            ISRC      <code>            (when Layout reports one)
            FLAGS     DCP / PRE         (when Layout reports them)
            INDEX 00  <mm:ss:ff>        (only if pregap > 0)
            INDEX 01  00:00:00

    Line endings: CRLF (the EAC convention; many CUE-aware tools are
    fussy about this on Windows).

.PARAMETER Layout
    Disc TOC. Two shapes accepted (so we don't have to load CUETools
    DLLs in tests):
        - The pscustomobject Get-RipperDiscId returns:
              { DiscId, Tracks = [{Number, IsAudio, StartSector,
                                   LengthSectors, PreEmphasis, ...}] }
        - A hashtable mirror of the same shape (used by tests).
    Pregap is COMPUTED on the fly from each track's StartSector minus
    the previous track's StartSector + LengthSectors — that's how
    the disc's TOC actually encodes it. Optional fields ISRC and DCP
    are read if present and emitted into the per-track block.

.PARAMETER Metadata
    Confirmed metadata from Show-RipperMetadataDialog. Required fields:
    AlbumArtist, Album, Year, Tracks=[{Number,Title,Artist}].

.PARAMETER FlacFileNames
    Per-track .flac filenames (NOT full paths). Length must equal
    Layout.TrackCount of audio tracks.

.PARAMETER ToolTag
    Free-form string written into the REM COMMENT line. Defaults to
    "MusicRipper".

.EXAMPLE
    PS> $cue = New-RipperCueSheet -Layout $layout -Metadata $meta `
            -FlacFileNames @('01 - A.flac','02 - B.flac')
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Layout,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string[]]$FlacFileNames,
        [string]$ToolTag = 'MusicRipper'
    )

    # Normalize tracks from either object or hashtable input.
    $audioTracks = @($Layout.Tracks | Where-Object { $_.IsAudio })
    if ($audioTracks.Count -ne $FlacFileNames.Count) {
        throw "FlacFileNames count ($($FlacFileNames.Count)) does not match audio track count ($($audioTracks.Count))."
    }
    if ($audioTracks.Count -ne @($Metadata.Tracks).Count) {
        throw "Metadata track count ($(@($Metadata.Tracks).Count)) does not match audio track count on disc ($($audioTracks.Count))."
    }

    # HTOA detection: track 1 starts after sector 0 ⇒ there's audio in the
    # disc's pregap (a "hidden" track). We don't encode it (Phase 4 spike §8
    # punts this), but we record its presence in a REM HTOA comment so the
    # CUE at least documents that audio was discarded — a careful re-rip
    # later can recover it.
    $htoaWarning = $null
    $firstStart = [int64](_GetField $audioTracks[0] 'StartSector')
    if ($firstStart -gt 0) {
        $htoaWarning = "Track 1 begins at sector $firstStart; pregap audio (Hidden Track) was not encoded."
    }

    $sb = [System.Text.StringBuilder]::new()
    $nl = "`r`n"

    # Header.
    $genre = _GetField $Metadata 'Genre'
    if ($genre)  { [void]$sb.Append("REM GENRE `"$genre`"$nl") }
    if ($Metadata.Year) { [void]$sb.Append("REM DATE $($Metadata.Year)$nl") }
    $discId = _GetField $Metadata 'DiscId'
    if ($discId) { [void]$sb.Append("REM DISCID $discId$nl") }
    [void]$sb.Append("REM COMMENT `"$ToolTag`"$nl")
    if ($htoaWarning) { [void]$sb.Append("REM HTOA `"$htoaWarning`"$nl") }
    [void]$sb.Append("PERFORMER `"$(_CueQuote $Metadata.AlbumArtist)`"$nl")
    [void]$sb.Append("TITLE `"$(_CueQuote $Metadata.Album)`"$nl")

    # Tracks.
    for ($i = 0; $i -lt $audioTracks.Count; $i++) {
        $t        = $audioTracks[$i]
        $tm       = $Metadata.Tracks[$i]
        $fname    = $FlacFileNames[$i]
        $num      = [int](_GetField $t 'Number')

        [void]$sb.Append("FILE `"$fname`" WAVE$nl")
        [void]$sb.Append("  TRACK $($num.ToString('D2')) AUDIO$nl")
        [void]$sb.Append("    TITLE `"$(_CueQuote (_GetField $tm 'Title'))`"$nl")

        $perTrackArtist = [string](_GetField $tm 'Artist')
        if ($perTrackArtist -and $perTrackArtist -ne $Metadata.AlbumArtist) {
            [void]$sb.Append("    PERFORMER `"$(_CueQuote $perTrackArtist)`"$nl")
        }

        $isrc = [string](_GetField $t 'ISRC')
        if ($isrc) { [void]$sb.Append("    ISRC $isrc$nl") }

        $dcp = [bool](_GetField $t 'DCP')
        $pre = [bool](_GetField $t 'PreEmphasis')
        $flags = @()
        if ($dcp) { $flags += 'DCP' }
        if ($pre) { $flags += 'PRE' }
        if ($flags.Count -gt 0) { [void]$sb.Append("    FLAGS $($flags -join ' ')$nl") }

        # INDEX 00 (pregap reference). Under "append-to-previous" the
        # pregap audio is encoded into the END of the previous file, so
        # for track N (N>=2) we compute:
        #     pregapSectors = thisTrack.StartSector
        #                   - prevTrack.StartSector - prevTrack.LengthSectors
        # When non-zero, INDEX 00 inside this TRACK block points to the
        # offset INSIDE THE PREVIOUS FILE where the pregap begins. That
        # offset equals prevTrack.LengthSectors (the previous file is
        # prevLen + pregap sectors long, and the pregap starts after the
        # clean-track portion).
        if ($i -gt 0) {
            $prev = $audioTracks[$i - 1]
            $prevStart = [int64](_GetField $prev 'StartSector')
            $prevLen   = [int64](_GetField $prev 'LengthSectors')
            $thisStart = [int64](_GetField $t 'StartSector')
            $pregapSectors = $thisStart - $prevStart - $prevLen
            if ($pregapSectors -gt 0) {
                $offsetSamples = $prevLen * 588
                [void]$sb.Append("    INDEX 00 $(ConvertTo-RipperCueTime -Samples $offsetSamples)$nl")
            }
        }
        [void]$sb.Append("    INDEX 01 00:00:00$nl")
    }

    $sb.ToString()
}

function _CueQuote {
    # Module-private. Escape a metadata string for inclusion inside CUE
    # double-quotes. CUE format has no real escape mechanism — the de-facto
    # convention is to replace embedded double-quotes with a single quote
    # (lossy, but every CUE parser in the wild expects this).
    param([AllowNull()] [AllowEmptyString()] [string]$Text)
    if ($null -eq $Text) { return '' }
    $Text -replace '"', "'"
}

function _GetField {
    # Module-private. Read a named field from either a [pscustomobject] or a
    # [hashtable]. We accept both shapes (a real CDImageLayout from CUETools
    # OR a test-fixture hashtable) and PSObject-style property checks don't
    # work uniformly across them — Hashtable.PSObject.Properties enumerates
    # the dictionary wrapper (Keys/Values/Count), not the entries.
    param($Source, [string]$Name)
    if ($null -eq $Source) { return $null }
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Name)) { return $Source[$Name] }
        return $null
    }
    $prop = $Source.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-RipperLogSummary {
<#
.SYNOPSIS
    Parse a CUETools rip log into a structured summary with a roll-up
    Status field that the UI and Phase 5's Test-RipQuality can consume.

.DESCRIPTION
    Input: the multi-line text emitted by AccurateRipVerify.GenerateFullLog
    (the same log the Console ripper writes to disk). Lines look like:

        [Disc ID: 0123abcd]
        [AccurateRip: Disc not present in database]
        [AccurateRip: Disc present in database, all tracks accurately ripped (confidence 7)]
        [CTDB: id=..., all tracks accurately ripped (confidence 8)]
        Track 01 [aaaa]: accurately ripped (confidence 9)
        Track 02 [bbbb]: differs in 14 samples @00:00.50, no match in any version

    The CUETools log format is informally specified — it drifts a little
    between versions. We pin a small set of permissive regexes; on no-match
    we return the field as 'Unknown' rather than throwing. Phase 5's
    Test-RipQuality will be the one that decides "good enough vs send to
    review" — this helper only surfaces the raw evidence + a coarse rollup
    so the progress UI can render a final-status line.

    Output (per the Phase 4 spike §7 contract):

        [pscustomobject]@{
            Status      = 'Verified' | 'ProbablyGood' | 'Suspect'
                        | 'NotInDatabase' | 'Unknown'
            AccurateRip = @{
                Status        = 'Verified' | 'NotInDatabase' | 'Unknown'
                MatchedTracks = <int>
                TotalTracks   = <int>
                MinConfidence = <int> | $null
            }
            Ctdb = @{
                Status        = 'Verified' | 'Partial' | 'Unknown'
                MinConfidence = <int> | $null
            }
            Tracks = @(
                @{ Number=<int>; Verdict='Verified'|'Suspect'|'Unverified'|'NotInDatabase'|'Unknown'; Confidence=<int>|$null }
                ...
            )
        }

    Status rollup:
        - any track Suspect            ⇒ Suspect
        - all tracks Verified, AR conf ≥ 2 ⇒ Verified
        - all tracks Verified, AR conf 1   ⇒ ProbablyGood
        - any track Verified + Ctdb Verified ⇒ ProbablyGood
        - all NotInDatabase             ⇒ NotInDatabase
        - otherwise                     ⇒ Unknown

.PARAMETER LogText
    Full text of the log (newline separators; CRLF and LF both fine).

.EXAMPLE
    PS> $summary = Get-RipperLogSummary -LogText (Get-Content -Raw $logPath)
    PS> $summary.Status
    Verified
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$LogText
    )

    $text = ($LogText -replace "`r`n", "`n").Trim()

    $result = [pscustomobject]@{
        Status      = 'Unknown'
        AccurateRip = [pscustomobject]@{ Status='Unknown'; MatchedTracks=0; TotalTracks=0; MinConfidence=$null }
        Ctdb        = [pscustomobject]@{ Status='Unknown'; MinConfidence=$null }
        Tracks      = @()
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $result }

    # --- AR album-level line ---------------------------------------------
    $arNotPresent  = $text -match '(?im)^\[?AccurateRip[:\]].*not present.*database'
    $arAllAccurate = $text -match '(?im)^\[?AccurateRip[:\]].*accurately ripped(?:.*confidence\s+(\d+))?'
    if ($arAllAccurate) {
        $result.AccurateRip.Status = 'Verified'
        if ($Matches.Count -gt 1 -and $Matches[1]) {
            $result.AccurateRip.MinConfidence = [int]$Matches[1]
        }
    } elseif ($arNotPresent) {
        $result.AccurateRip.Status = 'NotInDatabase'
    }

    # --- CTDB album-level line -------------------------------------------
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

    # --- Per-track lines (permissive) ------------------------------------
    # Both of these shapes appear across CUETools versions:
    #   "Track 01 [aaaa]: accurately ripped (confidence 8)"
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
        $result.AccurateRip.TotalTracks   = $result.Tracks.Count
        $result.AccurateRip.MatchedTracks = @($result.Tracks | Where-Object Verdict -eq 'Verified').Count
        $confidences = @($result.Tracks | Where-Object { $null -ne $_.Confidence } | ForEach-Object Confidence)
        if ($confidences.Count -gt 0 -and -not $result.AccurateRip.MinConfidence) {
            $result.AccurateRip.MinConfidence = ($confidences | Measure-Object -Minimum).Minimum
        }
    }

    # --- Roll up Status --------------------------------------------------
    $allVerified = $result.Tracks.Count -gt 0 -and (@($result.Tracks | Where-Object Verdict -ne 'Verified').Count -eq 0)
    $anySuspect  = @($result.Tracks | Where-Object Verdict -eq 'Suspect').Count -gt 0
    $allNotInDb  = $result.Tracks.Count -gt 0 -and (@($result.Tracks | Where-Object Verdict -ne 'NotInDatabase').Count -eq 0)

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

function ConvertTo-RipperEtaText {
<#
.SYNOPSIS
    Format a "elapsed / ETA" pair of strings for the progress window.

.DESCRIPTION
    Given:
        - how long the rip has been running (Elapsed),
        - how much of the total work is done (FractionDone, 0..1),
    estimate remaining time linearly (Elapsed * (1-f) / f).

    Format rules:
        - Both strings use H:MM:SS when >= 1 hour, MM:SS otherwise.
        - ETA returns 'estimating...' when FractionDone is 0 or below
          a small threshold (no signal yet).
        - ETA returns '0:00' when FractionDone >= 1.

.PARAMETER Elapsed
    TimeSpan since the rip started.

.PARAMETER FractionDone
    Total work fraction in [0, 1]. Caller decides whether that's
    bytes-read-so-far / total-bytes-on-disc, or tracks-done / total,
    or a blend — the helper just does arithmetic.

.OUTPUTS
    Hashtable @{ Elapsed = '<str>'; Eta = '<str>' }.

.EXAMPLE
    PS> ConvertTo-RipperEtaText -Elapsed (New-TimeSpan -Seconds 90) -FractionDone 0.25
    Name                           Value
    ----                           -----
    Eta                            4:30
    Elapsed                        1:30
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [TimeSpan]$Elapsed,
        [Parameter(Mandatory)] [double]$FractionDone
    )

    $elapsedStr = _FormatTimeSpan $Elapsed

    if ($FractionDone -le 0.001) {
        return @{ Elapsed = $elapsedStr; Eta = 'estimating...' }
    }
    if ($FractionDone -ge 1.0) {
        return @{ Elapsed = $elapsedStr; Eta = '0:00' }
    }

    $totalSeconds = $Elapsed.TotalSeconds / $FractionDone
    $remaining    = [TimeSpan]::FromSeconds([Math]::Max(0, $totalSeconds - $Elapsed.TotalSeconds))
    @{ Elapsed = $elapsedStr; Eta = (_FormatTimeSpan $remaining) }
}

function _FormatTimeSpan {
    param([TimeSpan]$Ts)
    if ($Ts.TotalHours -ge 1) {
        '{0}:{1:D2}:{2:D2}' -f [int]$Ts.TotalHours, $Ts.Minutes, $Ts.Seconds
    } else {
        '{0}:{1:D2}' -f $Ts.Minutes, $Ts.Seconds
    }
}

function ConvertTo-RipperReadSpeedText {
<#
.SYNOPSIS
    Format a CD-DA read speed multiplier from a bytes/sec rate.

.DESCRIPTION
    1x CD-DA is 176_400 bytes/sec (44100 Hz * 16 bit * 2 ch / 8). We
    show one decimal place — drives report wobbly speeds, two decimals
    is noise.

.PARAMETER BytesPerSecond
    Sustained read rate in bytes/sec (caller computes from a sliding
    window of ReadProgress events).

.EXAMPLE
    PS> ConvertTo-RipperReadSpeedText -BytesPerSecond 1411200
    8.0x
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateRange(0, [double]::MaxValue)] [double]$BytesPerSecond
    )
    $multiplier = $BytesPerSecond / 176400.0
    '{0:F1}x' -f $multiplier
}

Export-ModuleMember -Function @(
    'New-RipperTrackFileName',
    'ConvertTo-RipperCueTime',
    'New-RipperCueSheet',
    'Get-RipperLogSummary',
    'ConvertTo-RipperEtaText',
    'ConvertTo-RipperReadSpeedText'
)
