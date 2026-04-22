<#
.SYNOPSIS
    Phase 5 tagging stage: apply the full Vorbis tag set, embed cover
    art, and compute ReplayGain over a finished rip folder.

.DESCRIPTION
    Pipeline position:
        Step 6 of the daily flow. Called from Start-Ripper.ps1 after
        Test-RipQuality routes a rip to the main library (we do NOT
        run this on _ReviewQueue items — those keep Phase 4's minimal
        tags so the user can re-tag in Picard without our edits in
        the way). Output of this script feeds Move-ToLibrary.

    Why metaflac (and not the CUETools .NET DLLs):
        See docs/DECISIONS.md D-009. CUETools' tagging code is wired
        through TagLib-Sharp internally and is not exposed as a public
        API in the shipped DLLs. ReplayGain (the audio-analysis half
        of this stage) has no .NET equivalent in CUETools at all. The
        Xiph reference `metaflac.exe` does both, in-place, and respects
        the 8192-byte padding Phase 4 reserves on every encoder, so
        cover-art embed and tag rewrites are essentially instant — no
        audio rewrite.

    What this script DOES (per track):
        1. `metaflac --remove-all-tags` — strips Phase 4's minimal tag
           set so we can write the full one cleanly. PICTURE blocks
           survive this (different metadata block type).
        2. `metaflac --set-tag=...` for the full Plex-friendly Vorbis
           tag set — see New-RipperFlacTagSet below for the exact list.
        3. `metaflac --remove --block-type=PICTURE` then
           `--import-picture-from cover.jpg` if cover bytes are present.

    What this script DOES (per album):
        4. Writes cover.jpg sidecar to the rip folder (Plex grid art)
           if -CoverArtBytes provided AND no cover.jpg already exists.
        5. `metaflac --add-replay-gain track1.flac track2.flac ...` over
           every track in numeric order — ONE invocation so metaflac
           computes a single ALBUM gain alongside per-track gains.

    What this script does NOT do:
        - Move files into the library tree (Move-ToLibrary.ps1).
        - Decide quality (Test-RipQuality.ps1).
        - Re-encode any audio. metaflac is a metadata-only editor; the
          PCM blocks are not touched.

.NOTES
    Tag set chosen for Plex matching, per plan.md Phase 5 §2. See:
      - https://support.plex.tv/articles/200265296-adding-music-media/
      - https://xiph.org/flac/format.html#metadata_block_picture
      - metaflac(1) man page (Xiph FLAC tools v1.5.0)

    The pure helper New-RipperFlacTagSet is exported so the Pester suite
    can assert tag values without invoking metaflac on disk.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force


function New-RipperFlacTagSet {
<#
.SYNOPSIS
    Build the full Vorbis-comment NAME=value list for a single FLAC track.

.DESCRIPTION
    Pure function — no I/O. Given the album metadata object (shape:
    Phase 3 normalized candidate) plus a track index, returns the full
    string[] of "NAME=value" strings to be passed to
    `metaflac --set-tag=...`.

    Tag list (Plex-friendly + Picard-parity; see plan.md Phase 5 §2 and
    https://picard-docs.musicbrainz.org/en/appendices/tag_mapping.html):
        ALBUMARTIST, ARTIST, ALBUM, TITLE,
        TRACKNUMBER, TRACKTOTAL, DISCNUMBER, DISCTOTAL,
        ALBUMARTISTSORT                   (only if AlbumArtistSort is set)
        ARTISTSORT                        (track ArtistSort, falls back to album)
        DATE                              (full ReleaseDate; falls back to Year)
        ORIGINALDATE                      (only if OriginalDate is set)
        ORIGINALYEAR                      (only if OriginalYear is set)
        GENRE                             (only if Genre is set)
        COMPILATION=1                     (only if -IsCompilation)
        RELEASESTATUS                     (only if ReleaseStatus is set)
        RELEASETYPE                       (only if ReleaseType is set)
        RELEASECOUNTRY                    (only if Country is set)
        SCRIPT                            (only if Script is set)
        LANGUAGE                          (only if Language is set)
        LABEL                             (only if LabelName is set)
        CATALOGNUMBER                     (only if CatalogNumber is set)
        BARCODE                           (only if Barcode is set)
        ASIN                              (only if Asin is set)
        MUSICBRAINZ_DISCID                (always)
        MUSICBRAINZ_ALBUMID               (only if ReleaseMbid is set)
        MUSICBRAINZ_ALBUMARTISTID         (only if AlbumArtistMbid is set;
                                           multi-artist values are '/'-joined
                                           per Picard convention)
        MUSICBRAINZ_ARTISTID              (only if track has ArtistMbid)
        MUSICBRAINZ_TRACKID               (only if track has RecordingMbid)
        MUSICBRAINZ_RELEASEGROUPID        (only if ReleaseGroupMbid is set)

    ARTIST defaults to AlbumArtist when the per-track Artist is blank
    (single-artist album) — Plex requires both ARTIST and ALBUMARTIST
    to populate compilation grouping correctly.

.PARAMETER Metadata
    The normalized metadata object (shape produced by
    ConvertFrom-MusicBrainzDiscIdResponse, possibly post-edited via
    Show-MetadataDialog).

.PARAMETER TrackIndex
    Zero-based index into Metadata.Tracks.

.PARAMETER DiscId
    The MusicBrainz disc id (28-char base64-ish). Stored verbatim as
    MUSICBRAINZ_DISCID so re-rips can be deduplicated downstream.

.PARAMETER IsCompilation
    When $true, emits COMPILATION=1 (Plex / iTunes / MusicBee all
    honour this for "Various Artists" grouping).

.EXAMPLE
    PS> $tags = New-RipperFlacTagSet -Metadata $md -TrackIndex 0 `
                    -DiscId 'abc...' -IsCompilation $false
    PS> $tags | Where-Object { $_ -like 'TITLE=*' }
    TITLE=The Wall

.NOTES
    Order is stable so re-runs produce byte-identical metaflac
    invocations (helps debugging and testing).
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [int]$TrackIndex,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [bool]$IsCompilation
    )

    if ($TrackIndex -lt 0 -or $TrackIndex -ge @($Metadata.Tracks).Count) {
        throw "TrackIndex $TrackIndex out of range (0..$(@($Metadata.Tracks).Count - 1))."
    }

    $tm           = $Metadata.Tracks[$TrackIndex]
    $albumArtist  = [string]$Metadata.AlbumArtist
    $trackArtist  = if ($tm.PSObject.Properties['Artist'] -and $tm.Artist) {
                        [string]$tm.Artist
                    } else {
                        $albumArtist
                    }
    $trackTotal   = @($Metadata.Tracks).Count
    $discNumber   = if ($Metadata.PSObject.Properties['DiscNumber'] -and $Metadata.DiscNumber) {
                        [int]$Metadata.DiscNumber
                    } else { 1 }
    $discTotal    = if ($Metadata.PSObject.Properties['TotalDiscs'] -and $Metadata.TotalDiscs) {
                        [int]$Metadata.TotalDiscs
                    } else { 1 }

    $tags = New-Object 'System.Collections.Generic.List[string]'
    $tags.Add("ALBUMARTIST=$albumArtist")
    $tags.Add("ARTIST=$trackArtist")
    $tags.Add("ALBUM=$($Metadata.Album)")
    $tags.Add("TITLE=$($tm.Title)")
    $tags.Add("TRACKNUMBER=$($tm.Number)")
    $tags.Add("TRACKTOTAL=$trackTotal")
    $tags.Add("DISCNUMBER=$discNumber")
    $tags.Add("DISCTOTAL=$discTotal")

    # ---- Sort-name forms (Picard-standard; lets clients sort 'The Beatles'
    # under 'B', 'Lowell Mason' under 'M', etc.) -------------------------
    if ($Metadata.PSObject.Properties['AlbumArtistSort'] -and $Metadata.AlbumArtistSort) {
        $tags.Add("ALBUMARTISTSORT=$($Metadata.AlbumArtistSort)")
    }
    $trackArtistSort = if ($tm.PSObject.Properties['ArtistSort'] -and $tm.ArtistSort) {
                          [string]$tm.ArtistSort
                      } elseif ($Metadata.PSObject.Properties['AlbumArtistSort'] -and $Metadata.AlbumArtistSort) {
                          [string]$Metadata.AlbumArtistSort
                      } else { $null }
    if ($trackArtistSort) { $tags.Add("ARTISTSORT=$trackArtistSort") }

    # ---- Dates: prefer the full release date, fall back to bare year ----
    if ($Metadata.PSObject.Properties['ReleaseDate'] -and $Metadata.ReleaseDate) {
        $tags.Add("DATE=$($Metadata.ReleaseDate)")
    } elseif ($Metadata.PSObject.Properties['Year'] -and $Metadata.Year) {
        $tags.Add("DATE=$($Metadata.Year)")
    }
    if ($Metadata.PSObject.Properties['OriginalDate'] -and $Metadata.OriginalDate) {
        $tags.Add("ORIGINALDATE=$($Metadata.OriginalDate)")
    }
    if ($Metadata.PSObject.Properties['OriginalYear'] -and $Metadata.OriginalYear) {
        $tags.Add("ORIGINALYEAR=$($Metadata.OriginalYear)")
    }

    if ($Metadata.PSObject.Properties['Genre'] -and $Metadata.Genre) { $tags.Add("GENRE=$($Metadata.Genre)") }
    if ($IsCompilation) { $tags.Add('COMPILATION=1') }

    # ---- Release-level descriptors (all Picard-standard) ----------------
    if ($Metadata.PSObject.Properties['ReleaseStatus']  -and $Metadata.ReleaseStatus)  { $tags.Add("RELEASESTATUS=$($Metadata.ReleaseStatus)") }
    if ($Metadata.PSObject.Properties['ReleaseType']    -and $Metadata.ReleaseType)    { $tags.Add("RELEASETYPE=$($Metadata.ReleaseType)") }
    if ($Metadata.PSObject.Properties['Country']        -and $Metadata.Country)        { $tags.Add("RELEASECOUNTRY=$($Metadata.Country)") }
    if ($Metadata.PSObject.Properties['Script']         -and $Metadata.Script)         { $tags.Add("SCRIPT=$($Metadata.Script)") }
    if ($Metadata.PSObject.Properties['Language']       -and $Metadata.Language)       { $tags.Add("LANGUAGE=$($Metadata.Language)") }
    if ($Metadata.PSObject.Properties['LabelName']      -and $Metadata.LabelName)      { $tags.Add("LABEL=$($Metadata.LabelName)") }
    if ($Metadata.PSObject.Properties['CatalogNumber']  -and $Metadata.CatalogNumber)  { $tags.Add("CATALOGNUMBER=$($Metadata.CatalogNumber)") }
    if ($Metadata.PSObject.Properties['Barcode']        -and $Metadata.Barcode)        { $tags.Add("BARCODE=$($Metadata.Barcode)") }
    if ($Metadata.PSObject.Properties['Asin']           -and $Metadata.Asin)           { $tags.Add("ASIN=$($Metadata.Asin)") }

    $tags.Add("MUSICBRAINZ_DISCID=$DiscId")
    if ($Metadata.PSObject.Properties['ReleaseMbid']      -and $Metadata.ReleaseMbid)      { $tags.Add("MUSICBRAINZ_ALBUMID=$($Metadata.ReleaseMbid)") }
    if ($Metadata.PSObject.Properties['AlbumArtistMbid']  -and $Metadata.AlbumArtistMbid)  { $tags.Add("MUSICBRAINZ_ALBUMARTISTID=$($Metadata.AlbumArtistMbid)") }
    if ($tm.PSObject.Properties['ArtistMbid']             -and $tm.ArtistMbid)             { $tags.Add("MUSICBRAINZ_ARTISTID=$($tm.ArtistMbid)") }
    if ($tm.PSObject.Properties['RecordingMbid']          -and $tm.RecordingMbid)          { $tags.Add("MUSICBRAINZ_TRACKID=$($tm.RecordingMbid)") }
    if ($Metadata.PSObject.Properties['ReleaseGroupMbid'] -and $Metadata.ReleaseGroupMbid) { $tags.Add("MUSICBRAINZ_RELEASEGROUPID=$($Metadata.ReleaseGroupMbid)") }

    , $tags.ToArray()
}


function Get-RipperRipFolderTracks {
<#
.SYNOPSIS
    Return the per-track .flac files in a rip folder, sorted by leading
    track number embedded in the filename.

.DESCRIPTION
    Phase 4 names files via New-RipperTrackFileName, which always starts
    with a zero-padded track number followed by " - " (e.g.
    "01 - Carol of the Bells.flac"). This helper enumerates the rip
    folder, parses that prefix, and returns the files in the same
    order metaflac should see them for a coherent ALBUM ReplayGain
    pass. Files that don't match the pattern are skipped (e.g. a
    single-file image FLAC that may sit alongside in some workflows).

.PARAMETER RipFolder
    Absolute path to the rip output folder.

.NOTES
    Used by Invoke-RipperWriteTags; exported for unit testability.
#>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory)] [string]$RipFolder
    )
    if (-not (Test-Path -LiteralPath $RipFolder -PathType Container)) {
        throw "RipFolder not found: $RipFolder"
    }
    $files = @(Get-ChildItem -LiteralPath $RipFolder -File -Filter '*.flac' |
        Where-Object { $_.Name -match '^(\d{2,})\s*-\s*' } |
        Sort-Object @{ Expression = { [int]([regex]::Match($_.Name, '^(\d{2,})').Groups[1].Value) } })
    # Comma-prefix forces array semantics for single-element results so callers
    # can rely on .Count without re-wrapping.
    ,$files
}


function Invoke-RipperWriteTags {
<#
.SYNOPSIS
    Apply the full Vorbis tag set, embed cover art, and compute
    ReplayGain over a finished rip folder.

.DESCRIPTION
    Drives `metaflac.exe` (Xiph FLAC tools) over every track FLAC in
    the rip folder. See the file header for the full per-track and
    per-album sequence.

.PARAMETER RipFolder
    Absolute path to the rip output folder produced by Invoke-Rip.ps1.

.PARAMETER Metadata
    The (possibly user-edited) normalized metadata object.

.PARAMETER DiscId
    MusicBrainz disc id (stored as MUSICBRAINZ_DISCID).

.PARAMETER CoverArtBytes
    Optional. Cover art bytes (typically JPEG from CoverArtArchive). If
    provided and no cover.jpg exists yet in the rip folder, written as
    a sidecar AND embedded as the FLAC PICTURE block on every track.

.PARAMETER SkipReplayGain
    When set, the per-album ReplayGain pass is skipped. Used by tests
    and by manual harnesses where the audio analysis isn't relevant.

.PARAMETER MetaflacPath
    Override the metaflac.exe location (mostly for tests). Default
    resolves via Common\Get-MetaflacPath.

.PARAMETER PreserveTimestamps
    When $true (the default), the LastWriteTime and CreationTime of
    every FLAC are captured before tagging and restored afterward, so
    `metaflac` editing the file in place does not bump the file's
    mtime. Matches Picard's "Preserve timestamps of tagged files"
    option. Pass `-PreserveTimestamps:$false` to let the OS update
    the timestamps as normal (e.g. if a downstream sync tool keys off
    mtime to detect "changed" files).

.EXAMPLE
    PS> Invoke-RipperWriteTags -RipFolder 'D:\Music\_inbox\Foo - Bar' `
            -Metadata $md -DiscId 'abc...' -CoverArtBytes $bytes

.NOTES
    Returns a result object:
        { RipFolder, FlacFiles[], TagsWrittenPerFile, CoverEmbedded,
          CoverSidecarWritten, ReplayGainComputed, TimestampsPreserved,
          ElapsedMs }
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$RipFolder,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string]$DiscId,
        [byte[]]$CoverArtBytes,
        [switch]$SkipReplayGain,
        [string]$MetaflacPath,
        [bool]$PreserveTimestamps = $true
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $MetaflacPath) { $MetaflacPath = Get-MetaflacPath }
    if (-not (Test-Path -LiteralPath $MetaflacPath)) {
        throw "Metaflac binary not found at: $MetaflacPath"
    }

    $tracks = Get-RipperRipFolderTracks -RipFolder $RipFolder
    if ($tracks.Count -eq 0) {
        throw "No track FLAC files found in $RipFolder (expected files like '01 - <Title>.flac')."
    }
    if ($tracks.Count -ne @($Metadata.Tracks).Count) {
        throw "Track-count mismatch: $($tracks.Count) FLAC files in $RipFolder, but Metadata has $(@($Metadata.Tracks).Count) tracks."
    }

    Write-RipperLog INFO 'Write-Tags' "Tagging $($tracks.Count) FLAC files in $RipFolder via $MetaflacPath."

    # --- Snapshot timestamps (Picard-style preserve) -----------------------
    # Capture both LastWriteTime and CreationTime so a restore round-trip is
    # complete. We also stash the cover.jpg sidecar's stamps if it already
    # exists, to keep its mtime stable across re-runs.
    $stampMap = @{}   # path -> @{ LastWrite, Creation }
    if ($PreserveTimestamps) {
        foreach ($t in $tracks) {
            $stampMap[$t.FullName] = @{
                LastWrite = $t.LastWriteTime
                Creation  = $t.CreationTime
            }
        }
    }

    # --- Cover art sidecar -------------------------------------------------
    $coverPath = Join-Path $RipFolder 'cover.jpg'
    $coverPreExisting = Test-Path -LiteralPath $coverPath
    if ($PreserveTimestamps -and $coverPreExisting) {
        $coverItem = Get-Item -LiteralPath $coverPath
        $stampMap[$coverPath] = @{
            LastWrite = $coverItem.LastWriteTime
            Creation  = $coverItem.CreationTime
        }
    }
    $coverSidecarWritten = $false
    if ($CoverArtBytes -and -not $coverPreExisting) {
        [System.IO.File]::WriteAllBytes($coverPath, $CoverArtBytes)
        $coverSidecarWritten = $true
        Write-RipperLog INFO 'Write-Tags' "Wrote cover.jpg sidecar ($($CoverArtBytes.Length) bytes)."
    }
    $coverAvailable = Test-Path -LiteralPath $coverPath

    # --- Per-track tagging -------------------------------------------------
    $coverEmbeddedCount = 0
    $tagsWrittenPerFile = @{}

    for ($i = 0; $i -lt $tracks.Count; $i++) {
        $flac = $tracks[$i].FullName
        $tags = New-RipperFlacTagSet -Metadata $Metadata -TrackIndex $i `
                    -DiscId $DiscId `
                    -IsCompilation ([bool]($Metadata.PSObject.Properties['IsCompilation'] -and $Metadata.IsCompilation))

        # Step 1+2: wipe Phase 4's minimal tags + write the full set.
        $args = New-Object 'System.Collections.Generic.List[string]'
        $args.Add('--remove-all-tags')
        foreach ($kv in $tags) { $args.Add("--set-tag=$kv") }
        & $MetaflacPath @args $flac
        if ($LASTEXITCODE -ne 0) {
            throw "metaflac --set-tag failed for $flac (exit $LASTEXITCODE)."
        }

        # Step 3: cover art. metaflac's --import-picture-from supports a
        # bare filename, which uses default picture type 3 (front cover)
        # and auto-detects mime from the file's magic bytes.
        if ($coverAvailable) {
            & $MetaflacPath --remove --block-type=PICTURE --dont-use-padding $flac
            if ($LASTEXITCODE -ne 0) {
                throw "metaflac --remove PICTURE failed for $flac (exit $LASTEXITCODE)."
            }
            & $MetaflacPath "--import-picture-from=$coverPath" $flac
            if ($LASTEXITCODE -ne 0) {
                throw "metaflac --import-picture-from failed for $flac (exit $LASTEXITCODE)."
            }
            $coverEmbeddedCount++
        }

        $tagsWrittenPerFile[$tracks[$i].Name] = $tags.Count
    }

    # --- Per-album ReplayGain ---------------------------------------------
    # Pass every track in one invocation so metaflac computes a single
    # ALBUM gain alongside per-track gains. Re-runs are safe: existing
    # REPLAYGAIN_* tags are overwritten.
    $replayGainComputed = $false
    if (-not $SkipReplayGain) {
        $rgArgs = New-Object 'System.Collections.Generic.List[string]'
        $rgArgs.Add('--add-replay-gain')
        foreach ($t in $tracks) { $rgArgs.Add($t.FullName) }
        & $MetaflacPath @rgArgs
        if ($LASTEXITCODE -ne 0) {
            throw "metaflac --add-replay-gain failed (exit $LASTEXITCODE)."
        }
        $replayGainComputed = $true
        Write-RipperLog INFO 'Write-Tags' 'ReplayGain computed (album + per-track).'
    }

    # --- Restore timestamps (after metaflac is fully done writing) ---------
    if ($PreserveTimestamps -and $stampMap.Count -gt 0) {
        foreach ($path in $stampMap.Keys) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $s = $stampMap[$path]
            try {
                [System.IO.File]::SetLastWriteTime($path, $s.LastWrite)
                [System.IO.File]::SetCreationTime($path,  $s.Creation)
            } catch {
                Write-RipperLog WARN 'Write-Tags' "Could not restore timestamps on $path : $($_.Exception.Message)"
            }
        }
        Write-RipperLog INFO 'Write-Tags' "Restored timestamps on $($stampMap.Count) file(s)."
    }

    $sw.Stop()
    Write-RipperLog INFO 'Write-Tags' "Done in $([int]$sw.Elapsed.TotalMilliseconds) ms."

    [pscustomobject]@{
        RipFolder            = $RipFolder
        FlacFiles            = $tracks.FullName
        TagsWrittenPerFile   = $tagsWrittenPerFile
        CoverEmbedded        = $coverEmbeddedCount
        CoverSidecarWritten  = $coverSidecarWritten
        ReplayGainComputed   = $replayGainComputed
        TimestampsPreserved  = [bool]$PreserveTimestamps
        ElapsedMs            = [int]$sw.Elapsed.TotalMilliseconds
    }
}
