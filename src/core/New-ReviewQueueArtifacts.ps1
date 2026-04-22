<#
.SYNOPSIS
    Phase 5 _ReviewQueue artifacts: write REVIEW.txt and generate the
    single-file album image (_image/<Album>.flac + .cue).

.DESCRIPTION
    Pipeline position:
        Step 8 of the daily flow, but only for rips routed to
        _ReviewQueue. Called from Start-Ripper.ps1 after Move-ToLibrary,
        operating on the *destination* folder under
        <LibraryRoot>\_ReviewQueue\<PREFIX> - ... - <discId>\.

    What lands in a review-queue folder (after this script):

        _ReviewQueue\<PREFIX> - ... - <discId>\
            01 - Track.flac    ...    cover.jpg    <Album>.cue    <Album>.log
            _image\
                <Album>.flac     # single-file decode of all per-track FLACs
                <Album>.cue      # cue referencing the single-file image
            REVIEW.txt           # Reason / RipDate / DiscId / etc.

    Why a single-file image (when the per-track .flac + .cue at the
    album root already contains the same audio):
        Per plan.md, the user inspects suspect rips in foobar2000 or
        WinCDEmu/Virtual CloneDrive, both of which scrub more smoothly
        across a single .flac than across cue-stitched per-track files.
        Generated only here so the main library stays small.

.NOTES
    Pure helpers (New-RipperReviewTxt, New-RipperReviewImageCueText) are
    exported so the Pester suite can lock in the format. Image generation
    is exercised against a stub flac.cmd in unit tests; the real
    flac.exe path is covered by manual end-of-phase verification.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')     -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1')    -Force
Import-Module (Join-Path $repoRoot 'src\lib\RipHelpers.psd1') -Force


function New-RipperReviewTxt {
<#
.SYNOPSIS
    Build the contents of REVIEW.txt for a _ReviewQueue album folder.

.DESCRIPTION
    Pure function — no I/O. Returns the file body as a single CRLF-
    terminated string (so Notepad on Windows opens it cleanly). Format
    is simple `Key: Value` lines, per plan.md Phase 5 §3.

    Required fields: Reason, RipDate, DiscId, MusicBrainzMatch, Tracks,
    Duration, SuggestedAction, LogFile.

    SuggestedAction is derived from the routing prefix:
        SUSPECT   -> "Re-rip; if persistent, send to Picard for re-tag and accept."
        UNKNOWN   -> "Drop folder into MusicBrainz Picard to identify; then re-tag and re-route."
        LOWMATCH  -> "Verify match in MusicBrainz Picard; accept or re-search."
        MANUAL    -> "Edit tags in Picard if needed, then run Move-FromReviewQueue."

.PARAMETER Quality
    Result object from Test-RipQuality.

.PARAMETER Metadata
    Normalized metadata object. May be $null for UNKNOWN rips.

.PARAMETER DiscId
    MusicBrainz disc id.

.PARAMETER LogFileName
    File name (not full path) of the rip log inside the review folder.

.PARAMETER RipDate
    [datetime] of the rip. Defaults to now.

.PARAMETER MusicBrainzMatch
    Override the auto-derived match summary. Useful for LOWMATCH rips
    that need an explicit confidence number.

.EXAMPLE
    PS> New-RipperReviewTxt -Quality $q -Metadata $md -DiscId 'abc' `
            -LogFileName 'Spirit of the Season.log'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Quality,
        $Metadata,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [string]$LogFileName,
        [datetime]$RipDate = (Get-Date),
        [string]$MusicBrainzMatch
    )

    $prefix = ''
    if ($Quality.PSObject.Properties['RoutingPrefix']) { $prefix = [string]$Quality.RoutingPrefix }

    $reason = if ($Quality.PSObject.Properties['Reason']) { [string]$Quality.Reason } else { 'Unknown reason.' }

    $action = switch ($prefix) {
        'SUSPECT'  { 'Re-rip; if persistent, send to Picard for re-tag and accept.' }
        'UNKNOWN'  { 'Drop folder into MusicBrainz Picard to identify; then re-tag and re-route.' }
        'LOWMATCH' { 'Verify match in MusicBrainz Picard; accept or re-search.' }
        'MANUAL'   { 'Edit tags in Picard if needed, then run Move-FromReviewQueue.' }
        default    { 'Inspect manually.' }
    }

    if (-not $MusicBrainzMatch) {
        if (-not $Metadata) {
            $MusicBrainzMatch = 'none'
        } elseif ($Metadata.PSObject.Properties['ReleaseMbid'] -and $Metadata.ReleaseMbid) {
            $MusicBrainzMatch = [string]$Metadata.ReleaseMbid
        } else {
            $MusicBrainzMatch = 'none'
        }
    }

    $tracks   = if ($Metadata -and $Metadata.PSObject.Properties['Tracks']) { @($Metadata.Tracks).Count } else { 0 }
    $duration = if ($Metadata -and $Metadata.PSObject.Properties['Tracks']) {
                    $totalMs = ($Metadata.Tracks | Measure-Object -Property LengthMs -Sum).Sum
                    $secs    = [math]::Max(0.0, [double]$totalMs / 1000.0)
                    $mm      = [int][math]::Floor($secs / 60)
                    $ss      = [int][math]::Floor($secs - ($mm * 60))
                    "{0}m{1:D2}s" -f $mm, $ss
                } else { '0m00s' }
    $artist   = if ($Metadata -and $Metadata.AlbumArtist) { [string]$Metadata.AlbumArtist } else { '(unknown)' }
    $album    = if ($Metadata -and $Metadata.Album)       { [string]$Metadata.Album }       else { '(unknown)' }

    $lines = @(
        "Reason:           $prefix - $reason"
        "Album:            $artist - $album"
        "RipDate:          $($RipDate.ToString('yyyy-MM-dd HH:mm:ss'))"
        "DiscId:           $DiscId"
        "MusicBrainzMatch: $MusicBrainzMatch"
        "Tracks:           $tracks"
        "Duration:         $duration"
        "SuggestedAction:  $action"
        "LogFile:          $LogFileName"
    )
    ($lines -join "`r`n") + "`r`n"
}


function New-RipperReviewImageCueText {
<#
.SYNOPSIS
    Build a CUE sheet pointing at a single-file album image.

.DESCRIPTION
    Pure function. Differs from New-RipperCueSheet (Phase 4) in two ways:
      1. Single FILE entry referencing the image, not one per track.
      2. INDEX 01 timestamps are cumulative across the image, computed
         from the supplied per-track sample counts.

    All track audio is assumed to be appended in order (no pregap
    handling — the image is just a decoded concatenation of the per-track
    FLACs). HTOA / hidden-track-one-audio is not supported here; this is
    a review-queue convenience artifact, not a re-burning master.

.PARAMETER ImageFileName
    File name (not path) of the single-file image, e.g. 'Spirit.flac'.

.PARAMETER AlbumArtist
.PARAMETER Album
.PARAMETER Year
    Album-level identification. AlbumArtist is used as PERFORMER.

.PARAMETER TrackTitles
    [string[]] of track titles in order.

.PARAMETER TrackTotalSamples
    [long[]] of per-track sample counts (44.1 kHz stereo). Must have
    the same length as TrackTitles.

.PARAMETER DiscId
    Optional. Stored as REM DISCID for round-tripping.

.NOTES
    CRLF line endings (CUE convention). String values containing double
    quotes are escaped by single quotes (matches Phase 4 New-RipperCueSheet).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$ImageFileName,
        [Parameter(Mandatory)] [string]$AlbumArtist,
        [Parameter(Mandatory)] [string]$Album,
        [int]$Year,
        [Parameter(Mandatory)] [string[]]$TrackTitles,
        [Parameter(Mandatory)] [long[]]$TrackTotalSamples,
        [string]$DiscId
    )

    if ($TrackTitles.Count -ne $TrackTotalSamples.Count) {
        throw "TrackTitles ($($TrackTitles.Count)) and TrackTotalSamples ($($TrackTotalSamples.Count)) must have the same length."
    }

    $sb = [System.Text.StringBuilder]::new()
    $esc = { param($s) ([string]$s).Replace('"', "'") }
    if ($Year)   { [void]$sb.AppendLine("REM DATE $Year") }
    if ($DiscId) { [void]$sb.AppendLine("REM DISCID $DiscId") }
    [void]$sb.AppendLine("REM COMMENT `"MusicRipper review-queue image`"")
    [void]$sb.AppendLine("PERFORMER `"$(& $esc $AlbumArtist)`"")
    [void]$sb.AppendLine("TITLE `"$(& $esc $Album)`"")
    [void]$sb.AppendLine("FILE `"$(& $esc $ImageFileName)`" WAVE")

    $cumulative = 0L
    for ($i = 0; $i -lt $TrackTitles.Count; $i++) {
        $n = $i + 1
        [void]$sb.AppendLine(("  TRACK {0:D2} AUDIO" -f $n))
        [void]$sb.AppendLine("    TITLE `"$(& $esc $TrackTitles[$i])`"")
        [void]$sb.AppendLine("    INDEX 01 $(ConvertTo-RipperCueTime -Samples $cumulative)")
        $cumulative += $TrackTotalSamples[$i]
    }

    # Force CRLF (CUE convention). StringBuilder.AppendLine uses Environment.NewLine.
    $sb.ToString() -replace "(?<!`r)`n", "`r`n"
}


function New-RipperReviewImage {
<#
.SYNOPSIS
    Generate the single-file image FLAC + CUE under _image\ inside a
    review-queue album folder.

.DESCRIPTION
    Steps:
      1. Enumerate per-track .flac files in $ReviewFolder via
         Get-RipperRipFolderTracks (defined in Write-Tags.ps1).
      2. For each track, run `flac.exe -d --stdout --force-raw-format
         --sign=signed --endian=little` and append the raw 16-bit
         little-endian stereo PCM bytes to a temp .raw file.
      3. Read the per-track sample counts from the raw byte counts
         (4 bytes per stereo sample).
      4. Run `flac.exe --force-raw-format --sign=signed --endian=little
         --channels=2 --bps=16 --sample-rate=44100 -o <image>.flac
         <image>.raw` to encode the concatenation.
      5. Emit <Album>.cue via New-RipperReviewImageCueText pointing at
         the image.
      6. Delete the temp .raw.

    Cmd.exe redirection is used for the per-track decode because PS7's
    pipeline coerces native-exe stdout to strings, corrupting binary
    PCM. Quoted paths are passed via cmd.exe to handle spaces.

.PARAMETER ReviewFolder
    Absolute path to the review-queue album folder (output of
    Move-RipToLibrary when IsReviewQueue is $true).

.PARAMETER Metadata
    Normalized metadata. AlbumArtist/Album/Year used in CUE/file naming.
    May be $null for UNKNOWN rips (we'll fall back to '_unknown_').

.PARAMETER DiscId
    MusicBrainz disc id.

.PARAMETER FlacPath
    Override the flac.exe location (mostly for tests). Default: resolved
    from PATH (Xiph.FLAC installs flac alongside metaflac).

.NOTES
    Returns: { ImagePath, CuePath, RawBytes, Tracks, ElapsedMs }

    Skips and logs a warning (does NOT throw) if flac.exe is unavailable
    — image generation is convenience-only; the per-track FLACs and the
    album-root .cue still allow inspection in foobar2000.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$ReviewFolder,
        $Metadata,
        [Parameter(Mandatory)] [string]$DiscId,
        [string]$FlacPath
    )

    if (-not (Test-Path -LiteralPath $ReviewFolder -PathType Container)) {
        throw "ReviewFolder not found: $ReviewFolder"
    }

    if (-not $FlacPath) {
        $cmd = Get-Command flac.exe -ErrorAction SilentlyContinue
        if ($cmd) { $FlacPath = $cmd.Source }
    }
    if (-not $FlacPath -or -not (Test-Path -LiteralPath $FlacPath)) {
        Write-RipperLog WARN 'Review-Image' "flac.exe not found — skipping single-file image generation. Per-track FLACs at album root are still usable in foobar2000."
        return $null
    }

    # Re-use the pure helper from Write-Tags.ps1. Caller is expected to
    # have dot-sourced both — Start-Ripper does so explicitly.
    if (-not (Get-Command Get-RipperRipFolderTracks -ErrorAction SilentlyContinue)) {
        . (Join-Path $repoRoot 'src\core\Write-Tags.ps1')
    }
    $tracks = Get-RipperRipFolderTracks -RipFolder $ReviewFolder
    if (-not $tracks -or $tracks.Count -eq 0) {
        Write-RipperLog WARN 'Review-Image' "No per-track FLACs in $ReviewFolder — skipping image generation."
        return $null
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()

    $albumName = if ($Metadata -and $Metadata.Album) { [string]$Metadata.Album } else { '_unknown_' }
    $safeAlbum = ConvertTo-SafeWindowsPathSegment -Name $albumName
    $imageDir  = Join-Path $ReviewFolder '_image'
    if (-not (Test-Path -LiteralPath $imageDir)) {
        New-Item -ItemType Directory -Path $imageDir | Out-Null
    }
    $rawPath   = Join-Path $imageDir "$safeAlbum.raw"
    $imagePath = Join-Path $imageDir "$safeAlbum.flac"
    $cuePath   = Join-Path $imageDir "$safeAlbum.cue"
    if (Test-Path -LiteralPath $rawPath)   { Remove-Item -LiteralPath $rawPath   -Force }
    if (Test-Path -LiteralPath $imagePath) { Remove-Item -LiteralPath $imagePath -Force }

    $perTrackSamples = New-Object 'System.Collections.Generic.List[long]'
    $previousRawSize = 0L

    foreach ($t in $tracks) {
        # cmd.exe handles the >> redirection; PowerShell would coerce binary stdout to text.
        $arglist = "/d /c `"`"$FlacPath`" -d --stdout --force-raw-format --sign=signed --endian=little -- `"$($t.FullName)`" >> `"$rawPath`"`""
        $proc    = Start-Process -FilePath cmd.exe -ArgumentList $arglist -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "flac.exe -d failed for $($t.FullName) (exit $($proc.ExitCode))."
        }
        $newSize = (Get-Item -LiteralPath $rawPath).Length
        $delta   = $newSize - $previousRawSize
        $perTrackSamples.Add([long]($delta / 4))   # 16-bit stereo = 4 bytes/sample
        $previousRawSize = $newSize
    }

    & $FlacPath --silent --force-raw-format --sign=signed --endian=little `
        --channels=2 --bps=16 --sample-rate=44100 -o $imagePath $rawPath
    if ($LASTEXITCODE -ne 0) {
        throw "flac.exe encode failed (exit $LASTEXITCODE)."
    }
    Remove-Item -LiteralPath $rawPath -Force

    # CUE generation.
    $titles = @($tracks | ForEach-Object {
        if ($_.BaseName -match '^\d{2,}\s*-\s*(.+)$') { $Matches[1] } else { $_.BaseName }
    })
    $artist = if ($Metadata -and $Metadata.AlbumArtist) { [string]$Metadata.AlbumArtist } else { '_unknown_' }
    $year   = if ($Metadata -and $Metadata.PSObject.Properties['Year'] -and $Metadata.Year) { [int]$Metadata.Year } else { 0 }
    $cueArgs = @{
        ImageFileName     = "$safeAlbum.flac"
        AlbumArtist       = $artist
        Album             = $albumName
        TrackTitles       = $titles
        TrackTotalSamples = $perTrackSamples.ToArray()
        DiscId            = $DiscId
    }
    if ($year) { $cueArgs.Year = $year }
    $cueText = New-RipperReviewImageCueText @cueArgs
    [System.IO.File]::WriteAllText($cuePath, $cueText, [System.Text.Encoding]::UTF8)

    $sw.Stop()
    Write-RipperLog INFO 'Review-Image' "Generated $imagePath ($($tracks.Count) tracks, $([int]$sw.Elapsed.TotalSeconds) s)."

    [pscustomobject]@{
        ImagePath = $imagePath
        CuePath   = $cuePath
        Tracks    = $tracks.Count
        ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    }
}


function Write-RipperReviewTxt {
<#
.SYNOPSIS
    Write REVIEW.txt to a review-queue album folder.

.DESCRIPTION
    Thin I/O wrapper around New-RipperReviewTxt. Always writes UTF-8
    (no BOM) so the file opens identically in Notepad and Picard.

.PARAMETER ReviewFolder
    Absolute path to the review-queue album folder.

.PARAMETER Quality
    Test-RipQuality result.

.PARAMETER Metadata
    Normalized metadata (may be $null for UNKNOWN rips).

.PARAMETER DiscId
    MusicBrainz disc id.

.PARAMETER LogFileName
    Base name of the rip log file inside the review folder.

.PARAMETER RipDate
    Optional. Defaults to now.

.NOTES
    Returns the absolute path to the written file.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$ReviewFolder,
        [Parameter(Mandatory)] $Quality,
        $Metadata,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [string]$LogFileName,
        [datetime]$RipDate = (Get-Date)
    )

    if (-not (Test-Path -LiteralPath $ReviewFolder -PathType Container)) {
        throw "ReviewFolder not found: $ReviewFolder"
    }
    $body = New-RipperReviewTxt -Quality $Quality -Metadata $Metadata -DiscId $DiscId `
                -LogFileName $LogFileName -RipDate $RipDate
    $target = Join-Path $ReviewFolder 'REVIEW.txt'
    # UTF-8 without BOM so Notepad and Picard render the same bytes.
    [System.IO.File]::WriteAllText($target, $body, [System.Text.UTF8Encoding]::new($false))
    $target
}
