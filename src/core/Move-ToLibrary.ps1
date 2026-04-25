<#
.SYNOPSIS
    Phase 5 final stage: move a tagged rip folder into its final
    location under the music library tree (or _ReviewQueue) using the
    Plex-recommended layout.

.DESCRIPTION
    Pipeline position:
        Step 7 of the daily flow. Called from Start-Ripper.ps1 after
        Write-Tags has applied the full tag set + ReplayGain. Inputs:
        the rip folder (containing per-track FLACs, cover.jpg, .cue,
        .log) plus the Test-RipQuality result that determines whether
        we land in the main library or the review queue.

    Layout (per plan.md Phase 5 §3):

        <LibraryRoot>\<AlbumArtist>\<Album> (Year)\
            01 - Track.flac
            ...
            cover.jpg
            <Album>.cue
            <Album>.log

        Compilations -> <LibraryRoot>\Various Artists\<Album> (Year)\
        Multi-disc   -> <LibraryRoot>\<AlbumArtist>\<Album> (Year)\
                        <D><NN> - Track.flac     (flat at album root,
                                                  disc number prefixed
                                                  to track number per
                                                  Plex spec)

        Suspect / Unknown / LowMatch / Manual rips ->
        <LibraryRoot>\_ReviewQueue\<PREFIX> - <descriptor> - <discId>\
            (flat — keep easy to inspect in Picard)

    Move semantics:
        Same-volume  -> directory rename (essentially free).
        Cross-volume -> per-file copy + delete (Move-Item handles
                        both transparently).

    What this script does NOT do:
        - Run post-processors (OneDrive / NAS sync). That's Phase 6.
        - Generate a single-file image FLAC for review-queue items.
          That's a separate Phase 5 commit (uses CUETools .NET).
        - Write REVIEW.txt. Same separate commit.

.NOTES
    Pure helpers (Get-RipperLibraryTargetDir, New-RipperReviewQueueFolderName,
    Format-RipperDuration) are exported so the Pester suite can lock in
    the layout rules without hitting the disk.

    See:
      - src/lib/Common.psm1 :: ConvertTo-SafeWindowsPathSegment
      - plan.md Phase 5 §3 (Move-ToLibrary)
      - https://support.plex.tv/articles/200265296-adding-music-media/
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force


function Format-RipperDuration {
<#
.SYNOPSIS
    Format a TimeSpan-like total seconds value as 'MMmSSs' (used in
    UNKNOWN review-queue folder names).

.DESCRIPTION
    Pure helper. Examples:
        90       -> '1m30s'
        3600     -> '60m00s'
        0        -> '0m00s'
        $null    -> '0m00s'

.NOTES
    We deliberately don't roll over to hours; the "60m00s" form makes
    long classical works easy to spot in a folder listing.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([double]$TotalSeconds)
    if (-not $TotalSeconds -or $TotalSeconds -lt 0) { return '0m00s' }
    $minutes = [int][math]::Floor($TotalSeconds / 60)
    $seconds = [int][math]::Floor($TotalSeconds - ($minutes * 60))
    "{0}m{1:D2}s" -f $minutes, $seconds
}


function New-RipperReviewQueueFolderName {
<#
.SYNOPSIS
    Build the per-album folder name for a rip routed to _ReviewQueue.

.DESCRIPTION
    Per plan.md Phase 5 §3, four prefixes drive the format:

      UNKNOWN - <ripDate> - <NNtracks> <MMmSSs> - <discId>
      LOWMATCH - <Artist> - <Album> - <discId>
      SUSPECT  - <Artist> - <Album> - <discId>
      MANUAL   - <Artist> - <Album> - <discId>

    UNKNOWN is the no-metadata-match case, so it can't include
    Artist/Album. SUSPECT, LOWMATCH and MANUAL all have metadata
    (just with a quality / confidence / user-flag concern), so the
    Artist + Album form is what helps the user spot it later.

    Each component is sanitized via ConvertTo-SafeWindowsPathSegment.

.PARAMETER Prefix
    One of UNKNOWN | LOWMATCH | SUSPECT | MANUAL.

.PARAMETER DiscId
    MusicBrainz disc id (required — used for re-rip dedup).

.PARAMETER Metadata
    Optional. Required for LOWMATCH/SUSPECT/MANUAL. Ignored for UNKNOWN.

.PARAMETER RipDate
    Optional. Used by UNKNOWN; defaults to today.

.PARAMETER TrackCount
    Optional. Used by UNKNOWN.

.PARAMETER TotalSeconds
    Optional. Used by UNKNOWN.

.EXAMPLE
    PS> New-RipperReviewQueueFolderName -Prefix SUSPECT -DiscId 'abc' `
            -Metadata @{ AlbumArtist='Foo'; Album='Bar' }
    SUSPECT - Foo - Bar - abc

.EXAMPLE
    PS> New-RipperReviewQueueFolderName -Prefix UNKNOWN -DiscId 'abc' `
            -RipDate '2026-04-21' -TrackCount 12 -TotalSeconds 2400
    UNKNOWN - 2026-04-21 - 12tracks 40m00s - abc
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateSet('UNKNOWN','LOWMATCH','SUSPECT','MANUAL','USER-REVIEW')]
        [string]$Prefix,
        [Parameter(Mandatory)] [string]$DiscId,
        $Metadata,
        [string]$RipDate,
        [int]$TrackCount,
        [double]$TotalSeconds
    )

    $safeDiscId = ConvertTo-SafeWindowsPathSegment -Name $DiscId

    if ($Prefix -eq 'UNKNOWN') {
        if (-not $RipDate)   { $RipDate    = (Get-Date).ToString('yyyy-MM-dd') }
        if (-not $TrackCount){ $TrackCount = 0 }
        $duration = Format-RipperDuration -TotalSeconds $TotalSeconds
        $descriptor = "$RipDate - ${TrackCount}tracks $duration"
        return ConvertTo-SafeWindowsPathSegment -Name "UNKNOWN - $descriptor - $safeDiscId"
    }

    # SUSPECT / LOWMATCH / MANUAL all need metadata.
    if (-not $Metadata) {
        throw "Metadata is required for prefix '$Prefix'."
    }
    $artist = ConvertTo-SafeWindowsPathSegment -Name ([string]$Metadata.AlbumArtist)
    $album  = ConvertTo-SafeWindowsPathSegment -Name ([string]$Metadata.Album)
    "$Prefix - $artist - $album - $safeDiscId"
}


function Get-RipperLibraryTargetDir {
<#
.SYNOPSIS
    Compute the absolute directory where a rip should land, given its
    metadata + quality verdict + library root.

.DESCRIPTION
    Pure function — no I/O, no validation that the path exists. Returns
    the album-level directory (the per-track FLACs go directly inside
    it for single-disc, or into Disc N\ subfolders for multi-disc).

    Routing rules:
      - Quality.RoutingPrefix is empty  -> main library
      - Quality.RoutingPrefix is set    -> _ReviewQueue (folder name
        built via New-RipperReviewQueueFolderName)

    Main-library layout:
      Compilation: <LibraryRoot>\Various Artists\<Album> (<Year>)\
      Else:        <LibraryRoot>\<AlbumArtist>\<Album> (<Year>)\

    Year suffix is omitted when Metadata.Year is missing or 0.

.PARAMETER LibraryRoot
    Absolute path to the library root.

.PARAMETER Metadata
    Normalized metadata object (Phase 3 shape; may include IsCompilation).

.PARAMETER Quality
    Test-RipQuality result. Only RoutingPrefix is consulted.

.PARAMETER DiscId
    MusicBrainz disc id (used for review-queue folder naming).

.NOTES
    For multi-disc albums, this returns the album-level dir; the caller
    is responsible for fanning per-track files into Disc N\ subfolders.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] $Quality,
        [Parameter(Mandatory)] [string]$DiscId
    )

    $prefix = ''
    if ($Quality.PSObject.Properties['RoutingPrefix']) { $prefix = [string]$Quality.RoutingPrefix }

    if ($prefix) {
        $folderName = New-RipperReviewQueueFolderName -Prefix $prefix -DiscId $DiscId `
                          -Metadata $Metadata
        return Join-Path (Join-Path $LibraryRoot '_ReviewQueue') $folderName
    }

    # --- Main library -----------------------------------------------------
    $isComp = $false
    if ($Metadata.PSObject.Properties['IsCompilation'] -and $Metadata.IsCompilation) { $isComp = $true }

    $artistFolder = if ($isComp) {
        'Various Artists'
    } else {
        ConvertTo-SafeWindowsPathSegment -Name ([string]$Metadata.AlbumArtist)
    }

    $album = ConvertTo-SafeWindowsPathSegment -Name ([string]$Metadata.Album)
    $year  = $null
    if ($Metadata.PSObject.Properties['Year'] -and $Metadata.Year) { $year = [int]$Metadata.Year }
    $albumFolder = if ($year) { "$album ($year)" } else { $album }

    Join-Path (Join-Path $LibraryRoot $artistFolder) $albumFolder
}


function Move-RipToLibrary {
<#
.SYNOPSIS
    Move a finished rip folder into its final library destination.

.DESCRIPTION
    Resolves the target directory via Get-RipperLibraryTargetDir, creates
    it, and moves every file from the rip folder. Multi-disc albums land
    flat at the album root — disc number is already encoded in each
    track filename (e.g. `101 - In the Flesh.flac`) per Plex's spec.
    cover.jpg / .cue / .log live at the album root regardless.

    Same-volume moves are essentially free (Move-Item performs a
    directory entry rename). Cross-volume moves transparently fall back
    to copy+delete.

.PARAMETER RipFolder
    Absolute path to the source rip folder.

.PARAMETER LibraryRoot
    Absolute path to the music library root.

.PARAMETER Metadata
    Normalized metadata object.

.PARAMETER Quality
    Test-RipQuality result.

.PARAMETER DiscId
    MusicBrainz disc id.

.PARAMETER Force
    When set, an existing target directory is overwritten file-by-file.

.PARAMETER AllowSideBySide
    When set, an existing target directory triggers a side-by-side
    fallback: the rip lands in `<Album> (<Year>) [rip 2]` (then
    `[rip 3]`, etc.). Square brackets keep the suffix from being
    parsed as a year by Plex's filename heuristics. Used when the
    Phase-5.8 duplicate-disc dialog confirms the user wants to keep
    both copies.

.NOTES
    Returns:
        { Source, Target, IsReviewQueue, IsMultiDisc, IsSideBySide,
          FilesMoved, ElapsedMs }
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$RipFolder,
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] $Quality,
        [Parameter(Mandatory)] [string]$DiscId,
        [switch]$Force,
        [switch]$AllowSideBySide
    )

    if (-not (Test-Path -LiteralPath $RipFolder -PathType Container)) {
        throw "RipFolder not found: $RipFolder"
    }
    if (-not (Test-Path -LiteralPath $LibraryRoot -PathType Container)) {
        # Library root parent must already exist; we create LibraryRoot if missing.
        New-Item -ItemType Directory -Path $LibraryRoot | Out-Null
    }

    $sw     = [Diagnostics.Stopwatch]::StartNew()
    $target = Get-RipperLibraryTargetDir -LibraryRoot $LibraryRoot -Metadata $Metadata `
                  -Quality $Quality -DiscId $DiscId
    $isReviewQueue = $target -like "*\_ReviewQueue\*"
    $isMultiDisc   = $false
    if (-not $isReviewQueue `
            -and $Metadata.PSObject.Properties['TotalDiscs'] `
            -and [int]$Metadata.TotalDiscs -gt 1) {
        $isMultiDisc = $true
    }

    $isSideBySide = $false
    if ((Test-Path -LiteralPath $target) -and -not $Force -and -not $isMultiDisc) {
        if ($AllowSideBySide -and -not $isReviewQueue) {
            # Pick the next free `[rip N]` suffix. Plex parses the
            # `(<year>)` segment as the album year; square brackets are
            # ignored by its filename heuristics, so `[rip 2]` is safe.
            $orig = $target
            for ($n = 2; $n -lt 100; $n++) {
                $candidate = "$orig [rip $n]"
                if (-not (Test-Path -LiteralPath $candidate)) {
                    $target       = $candidate
                    $isSideBySide = $true
                    Write-RipperLog INFO 'Move-ToLibrary' "Side-by-side: '$orig' exists, using '$target'."
                    break
                }
            }
            if (-not $isSideBySide) {
                throw "Side-by-side fallback exhausted (>= 99 copies?) for: $orig"
            }
        } else {
            # Phase 5.11: tag the throw with Exception.Data so the caller
            # (Start-Ripper post-process catch) can offer the user an
            # interactive Side-by-side / Open existing / Send to Review /
            # Discard prompt instead of just dumping the rip in _inbox.
            $ex = [System.IO.IOException]::new(
                "Target directory already exists (use -Force to overlay or -AllowSideBySide for ``[rip N]`` fallback): $target")
            $ex.Data['TargetExists'] = $target
            throw $ex
        }
    }

    Write-RipperLog INFO 'Move-ToLibrary' "Moving $RipFolder -> $target (review=$isReviewQueue, multiDisc=$isMultiDisc)."

    if ($PSCmdlet.ShouldProcess($target, 'Create directory')) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    $filesMoved = 0
    foreach ($entry in (Get-ChildItem -LiteralPath $RipFolder -File)) {
        # All files — including per-disc track FLACs — land at the album
        # root. The disc number is already in the FLAC filename prefix
        # (e.g. `101 - Track.flac`) per the Plex naming spec.
        $dest = Join-Path $target $entry.Name
        if ($PSCmdlet.ShouldProcess($dest, "Move $($entry.Name)")) {
            Move-Item -LiteralPath $entry.FullName -Destination $dest -Force:$Force
            $filesMoved++
        }
    }

    # Remove the now-empty source rip folder. If anything is left
    # (subdir, hidden file), leave it alone — caller can investigate.
    $remaining = @(Get-ChildItem -LiteralPath $RipFolder -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0 -and $PSCmdlet.ShouldProcess($RipFolder, 'Remove empty rip folder')) {
        Remove-Item -LiteralPath $RipFolder -Force
    }

    $sw.Stop()
    Write-RipperLog INFO 'Move-ToLibrary' "Moved $filesMoved files in $([int]$sw.Elapsed.TotalMilliseconds) ms."

    [pscustomobject]@{
        Source        = $RipFolder
        Target        = $target
        IsReviewQueue = $isReviewQueue
        IsMultiDisc   = $isMultiDisc
        IsSideBySide  = $isSideBySide
        FilesMoved    = $filesMoved
        ElapsedMs     = [int]$sw.Elapsed.TotalMilliseconds
    }
}
