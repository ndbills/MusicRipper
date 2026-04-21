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
    A CUETools.CDImage.CDImageLayout object (from CDDriveReader.TOC) OR
    a hashtable shaped { TrackCount, Tracks=[{Number,LengthFrames,
    PregapFrames,IsAudio,ISRC,DCP,PreEmphasis}] }. We accept the hashtable
    shape so unit tests can run without loading CUETools DLLs.

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

    $sb = [System.Text.StringBuilder]::new()
    $nl = "`r`n"

    # Header.
    $genre = _GetField $Metadata 'Genre'
    if ($genre)  { [void]$sb.Append("REM GENRE `"$genre`"$nl") }
    if ($Metadata.Year) { [void]$sb.Append("REM DATE $($Metadata.Year)$nl") }
    $discId = _GetField $Metadata 'DiscId'
    if ($discId) { [void]$sb.Append("REM DISCID $discId$nl") }
    [void]$sb.Append("REM COMMENT `"$ToolTag`"$nl")
    [void]$sb.Append("PERFORMER `"$(_CueQuote $Metadata.AlbumArtist)`"$nl")
    [void]$sb.Append("TITLE `"$(_CueQuote $Metadata.Album)`"$nl")

    # Tracks.
    for ($i = 0; $i -lt $audioTracks.Count; $i++) {
        $t        = $audioTracks[$i]
        $tm       = $Metadata.Tracks[$i]
        $fname    = $FlacFileNames[$i]
        $num      = [int](_GetField $t 'Number')
        $pregapFr = [int]((_GetField $t 'PregapFrames'))

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

        if ($pregapFr -gt 0) {
            # The pregap was appended to the END of the previous file, so
            # INDEX 00 here is the offset into the previous track's file
            # where this logical track's pregap begins. For per-track CUEs
            # this is conventionally written relative to the previous file
            # as (prevFileLen - pregap) — but since the player only uses
            # INDEX 01 for seek-to-track, most modern tools accept the
            # simplified form below where INDEX 00 sits at offset
            # 00:00:00 of *this* file. We emit the simplified form for
            # readability; a caller that needs strict EAC compatibility
            # can post-process.
            [void]$sb.Append("    INDEX 00 00:00:00$nl")
            [void]$sb.Append("    INDEX 01 $(ConvertTo-RipperCueTime -Samples ($pregapFr * 588))$nl")
        } else {
            [void]$sb.Append("    INDEX 01 00:00:00$nl")
        }
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
    Parse AccurateRip + CTDB summary fields out of a CUETools rip log.

.DESCRIPTION
    Input: the multi-line text emitted by
    AccurateRipVerify.GenerateFullLog() (the same log the Console ripper
    writes to disk). We extract:
        - AccurateRip per-track confidences
        - AccurateRip total verified track count
        - CTDB verification status
        - Any per-sector-error counts

    The log format is informally specified — it's whatever
    GenerateFullLog() prints. We pin a small set of regexes that have
    been stable across CUETools 2.1.x and 2.2.x. If a regex fails to
    match we return the corresponding field as $null rather than
    throwing; the caller (Phase 5 Test-RipQuality) decides what counts
    as "good enough".

    Output:
        @{
            AccurateRip = @{
                MatchedTracks = <int> | $null
                TotalTracks   = <int> | $null
                Confidences   = @(<int>...)   # per-track, or @() if none
                Status        = 'verified' | 'partial' | 'notpresent' | 'unknown'
            }
            Ctdb = @{
                Status     = 'verified' | 'differ' | 'notpresent' | 'unknown'
                Confidence = <int> | $null
            }
            FailedSectors = <int> | $null
        }

.PARAMETER LogText
    Full text of the log (newline separators).

.EXAMPLE
    PS> Get-RipperLogSummary -LogText (Get-Content -Raw rip.log)
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$LogText
    )

    $result = @{
        AccurateRip = @{ MatchedTracks = $null; TotalTracks = $null; Confidences = @(); Status = 'unknown' }
        Ctdb        = @{ Status = 'unknown'; Confidence = $null }
        FailedSectors = $null
    }

    # AccurateRip per-track lines look like:
    #   "Track  1: ... AccurateRip: confidence 5  [...]"
    # or "Track  1: ... AccurateRip: not present"
    $arConfidences = @()
    $arNotPresent  = 0
    $arTotal       = 0
    foreach ($m in [regex]::Matches($LogText, '(?im)^\s*Track\s+\d+\s*:.*?AccurateRip\s*:\s*(?:confidence\s+(\d+)|not\s+present)\b')) {
        $arTotal++
        if ($m.Groups[1].Success) {
            $arConfidences += [int]$m.Groups[1].Value
        } else {
            $arNotPresent++
        }
    }
    if ($arTotal -gt 0) {
        $result.AccurateRip.TotalTracks  = $arTotal
        $result.AccurateRip.MatchedTracks = $arConfidences.Count
        $result.AccurateRip.Confidences   = $arConfidences
        $result.AccurateRip.Status =
            if ($arNotPresent -eq $arTotal) { 'notpresent' }
            elseif ($arConfidences.Count -eq $arTotal) { 'verified' }
            else { 'partial' }
    }

    # CTDB summary line examples:
    #   "CTDB: verified (confidence 12)"
    #   "CTDB: differ"
    #   "CTDB: not present"
    if ($LogText -match '(?im)^\s*CTDB\s*:\s*(verified|differ|not\s+present)(?:.*?confidence\s+(\d+))?') {
        $status = $Matches[1].ToLowerInvariant() -replace '\s+', ''
        $map = @{ 'verified' = 'verified'; 'differ' = 'differ'; 'notpresent' = 'notpresent' }
        if ($map.ContainsKey($status)) { $result.Ctdb.Status = $map[$status] }
        if ($Matches.Count -gt 2 -and $Matches[2]) { $result.Ctdb.Confidence = [int]$Matches[2] }
    }

    # Failed sectors (uncorrected read errors). Format:
    #   "Failed sectors: 0"
    if ($LogText -match '(?im)^\s*Failed\s+sectors\s*:\s*(\d+)') {
        $result.FailedSectors = [int]$Matches[1]
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
