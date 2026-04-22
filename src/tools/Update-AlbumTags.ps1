<#
.SYNOPSIS
    Re-tag an existing album folder by re-querying MusicBrainz for the
    full release metadata. Useful when the tag schema has changed (new
    Picard-parity tags landed) or the original rip was tagged from a
    stale MB snapshot.

.DESCRIPTION
    Companion to the daily rip flow. Operates on a folder of finished
    FLAC files (typically one already in the library), looks the album
    up on MusicBrainz, and re-runs Phase-5 tagging in place via
    Invoke-RipperWriteTags. The audio is never re-encoded — metaflac is
    a metadata-only editor and Phase 4 reserves enough padding that the
    rewrite is essentially instant.

    Lookup strategy (first hit wins):
      1. -ReleaseMbid argument                   (explicit override)
      2. MUSICBRAINZ_ALBUMID tag on track 1      (preferred — exact)
      3. MUSICBRAINZ_DISCID tag on track 1       (exact, via /discid endpoint)
      4. Text search ALBUMARTIST + ALBUM         (best-effort, fuzzy)

    All MusicBrainz HTTP goes through Invoke-RipperMusicBrainzRequest,
    which enforces the >= 1100 ms anonymous rate limit and uses the
    User-Agent from config.json — same etiquette as a fresh rip.

    Cover art: re-fetched ONLY when -RefreshCoverArt is set or no
    cover.jpg sidecar exists yet. The default keeps your existing
    cover even if MB now has a different upload.

    What this script DOES touch on disk:
      - Per-track Vorbis comments (full --remove-all-tags + --set-tag)
      - PICTURE block on each FLAC (re-imported from cover.jpg if
        present, or the freshly fetched bytes if -RefreshCoverArt)
      - cover.jpg sidecar (only when -RefreshCoverArt and bytes are
        available)
      - REPLAYGAIN_* tags (re-computed unless -SkipReplayGain)

    What this script does NOT touch:
      - Folder/file names. Renaming an existing library item is the
        caller's job (Plex / your own follow-up). This tool only
        rewrites the in-file metadata.
      - Audio. PCM blocks are never touched.

.PARAMETER AlbumFolder
    Absolute path to the album folder. Must contain at least one
    "NN - <title>.flac" file produced by Phase-4 naming.

.PARAMETER ReleaseMbid
    Optional MusicBrainz release MBID override. When given, lookup
    skips straight to /ws/2/release/{ReleaseMbid}. Use this when you
    want to re-tag against a specific release (e.g. you found the
    original pressing rather than the remaster the file was first
    tagged from).

.PARAMETER RefreshCoverArt
    Re-fetch cover.jpg from Cover Art Archive (front-1200) and
    overwrite both the sidecar and the embedded PICTURE block. Without
    this flag, an existing cover.jpg is preserved and re-embedded.

.PARAMETER SkipReplayGain
    Skip the per-album ReplayGain pass. Useful when you just want a
    fast tag-only refresh and the existing REPLAYGAIN_* values are
    fine.

.PARAMETER PreferredCountry
    Two-letter ISO country to bias text-search ranking. Defaults to
    'US'. Only consulted in lookup mode 4 (text search).

.EXAMPLE
    PS> ./src/tools/Update-AlbumTags.ps1 'E:\digitize\MusicRipper\Pink Floyd\The Dark Side of the Moon (1973)'
    Reads MUSICBRAINZ_ALBUMID off track 1, refetches the release JSON,
    and rewrites every FLAC in place with the current tag schema.

.EXAMPLE
    PS> ./src/tools/Update-AlbumTags.ps1 'D:\Music\Some Album' -ReleaseMbid 'a1b2c3...' -RefreshCoverArt
    Re-tag against a specific release MBID and pull a fresh cover.

.NOTES
    Returns the result object from Invoke-RipperWriteTags, plus a
    LookupSource property indicating which strategy identified the
    release ('ParamMbid' | 'AlbumIdTag' | 'DiscIdTag' | 'TextSearch').

    This tool is read-only against the MusicBrainz API; it never
    modifies the upstream database.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $AlbumFolder,

    [Parameter()]
    [string] $ReleaseMbid,

    [switch] $RefreshCoverArt,

    [switch] $SkipReplayGain,

    [string] $PreferredCountry = 'US'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

. (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
. (Join-Path $repoRoot 'src\core\Write-Tags.ps1')

$logPath = Start-RipperLog -Context 'update-album-tags'
Write-RipperLog INFO 'Update-Tags' "Tool start. AlbumFolder=$AlbumFolder ReleaseMbid=$ReleaseMbid"

if (-not (Test-Path -LiteralPath $AlbumFolder -PathType Container)) {
    throw "AlbumFolder not found: $AlbumFolder"
}

# Resolve metaflac once.
$metaflac = Get-MetaflacPath

# Track listing (Phase-4 naming convention, sorted by leading number).
$tracks = Get-RipperRipFolderTracks -RipFolder $AlbumFolder
if ($tracks.Count -eq 0) {
    throw "No 'NN - <title>.flac' files in $AlbumFolder. Is this really an album folder produced by MusicRipper?"
}
$firstFlac = $tracks[0].FullName
Write-RipperLog INFO 'Update-Tags' "Found $($tracks.Count) FLAC files. Probe file: $($tracks[0].Name)"


# --- helpers ---------------------------------------------------------------

function Read-FlacTagValue {
    <#
    .SYNOPSIS
        Read the first value of a Vorbis comment from a FLAC via metaflac.
        Returns $null when the tag is absent or empty.
    #>
    param([string]$Flac, [string]$Name)
    $out = & $metaflac "--show-tag=$Name" $Flac 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if (-not $out) { return $null }
    $line = @($out)[0]
    if ($line -match '^[^=]+=(.*)$') {
        $v = $Matches[1].Trim()
        if ($v) { return $v }
    }
    return $null
}

function Get-ReleaseFromMbid {
    <#
    .SYNOPSIS
        Hit /ws/2/release/{mbid} and return the parsed release object.
    #>
    param([string]$Mbid)
    $url = 'https://musicbrainz.org/ws/2/release/' + $Mbid +
           '?inc=artists+recordings+release-groups+labels&fmt=json'
    Write-RipperLog INFO 'Update-Tags' "GET $url"
    return Invoke-RipperMusicBrainzRequest -Url $url
}

function Search-ReleaseMbidByText {
    <#
    .SYNOPSIS
        Search MB for a release matching ALBUMARTIST + ALBUM, return
        the top-scoring release MBID or $null.

    .DESCRIPTION
        Uses /ws/2/release/?query=... with field-qualified Lucene
        search. We bias toward CD media to match what we rip, and
        prefer the user's PreferredCountry as a tie-breaker. The
        track count is included as a soft hint (`tracks:N`) — MB
        treats it as advisory.
    #>
    param(
        [string]$AlbumArtist,
        [string]$Album,
        [int]$TrackCount,
        [string]$PreferredCountry
    )
    if (-not $AlbumArtist -or -not $Album) { return $null }

    # Lucene quoting: escape embedded double-quotes; wrap in quotes so
    # the whole phrase is one term.
    function _q([string]$s) { '"' + ($s -replace '"', '\"') + '"' }
    $q = "artist:$(_q $AlbumArtist) AND release:$(_q $Album) AND format:CD"
    if ($TrackCount -gt 0) { $q += " AND tracks:$TrackCount" }
    $url = 'https://musicbrainz.org/ws/2/release/?query=' +
           [System.Uri]::EscapeDataString($q) + '&limit=10&fmt=json'
    Write-RipperLog INFO 'Update-Tags' "GET $url"
    $resp = Invoke-RipperMusicBrainzRequest -Url $url
    if (-not $resp -or -not $resp.PSObject.Properties['releases']) { return $null }
    $hits = @($resp.releases)
    if ($hits.Count -eq 0) { return $null }

    # Bias the API's score by country preference (MB's ext:score is 0-100).
    $best = $hits | Sort-Object @(
        @{ Expression = {
            $score = if ($_.PSObject.Properties['score']) { [int]$_.score } else { 0 }
            $bias  = if ($_.PSObject.Properties['country'] -and $_.country -eq $PreferredCountry) { 5 } else { 0 }
            -($score + $bias)
        }; Ascending = $true }
    ) | Select-Object -First 1
    Write-RipperLog INFO 'Update-Tags' "Text search picked: $($best.id) ($($best.title)) score=$($best.score)"
    return [string]$best.id
}


# --- 1. Probe existing tags -----------------------------------------------

$existingAlbumId   = Read-FlacTagValue -Flac $firstFlac -Name 'MUSICBRAINZ_ALBUMID'
$existingDiscId    = Read-FlacTagValue -Flac $firstFlac -Name 'MUSICBRAINZ_DISCID'
$existingArtist    = Read-FlacTagValue -Flac $firstFlac -Name 'ALBUMARTIST'
$existingAlbum     = Read-FlacTagValue -Flac $firstFlac -Name 'ALBUM'
Write-RipperLog INFO 'Update-Tags' (
    "Existing tags: ALBUMARTIST='$existingArtist' ALBUM='$existingAlbum' " +
    "MUSICBRAINZ_ALBUMID='$existingAlbumId' MUSICBRAINZ_DISCID='$existingDiscId'"
)


# --- 2. Resolve release MBID via the lookup ladder -------------------------

$releaseMbidResolved = $null
$lookupSource        = $null
$discIdForTags       = $existingDiscId   # what we'll write back as MUSICBRAINZ_DISCID
$releaseObject       = $null

if ($ReleaseMbid) {
    $lookupSource        = 'ParamMbid'
    $releaseMbidResolved = $ReleaseMbid
    $releaseObject       = Get-ReleaseFromMbid -Mbid $ReleaseMbid
}
elseif ($existingAlbumId) {
    $lookupSource        = 'AlbumIdTag'
    $releaseMbidResolved = $existingAlbumId
    $releaseObject       = Get-ReleaseFromMbid -Mbid $existingAlbumId
}
elseif ($existingDiscId) {
    # Disc-id endpoint returns { releases: [...] }; pick the best then
    # refetch with full includes (the discid endpoint already includes
    # what we need, but going via Get-ReleaseFromMbid keeps one code
    # path for the parser).
    $lookupSource = 'DiscIdTag'
    $url = 'https://musicbrainz.org/ws/2/discid/' + $existingDiscId +
           '?inc=artists+recordings+release-groups+labels&fmt=json'
    Write-RipperLog INFO 'Update-Tags' "GET $url"
    $discResp = Invoke-RipperMusicBrainzRequest -Url $url
    if (-not $discResp -or -not $discResp.PSObject.Properties['releases'] -or @($discResp.releases).Count -eq 0) {
        throw "MUSICBRAINZ_DISCID '$existingDiscId' returned no matches. Re-run with -ReleaseMbid <mbid>."
    }
    # Reuse the disc-id parser to rank candidates the same way a fresh rip would.
    $cands = ConvertFrom-MusicBrainzDiscIdResponse -Response $discResp -DiscId $existingDiscId
    $best  = Select-BestMusicBrainzCandidate -Candidates $cands -PreferredCountry $PreferredCountry
    if (-not $best) {
        throw "No usable release for disc id '$existingDiscId'."
    }
    $releaseMbidResolved = $best.ReleaseMbid
    $releaseObject       = Get-ReleaseFromMbid -Mbid $releaseMbidResolved
}
else {
    if (-not $existingArtist -or -not $existingAlbum) {
        throw @"
Cannot identify this album: no MUSICBRAINZ_ALBUMID or MUSICBRAINZ_DISCID
tag, and ALBUMARTIST/ALBUM are also empty. Re-run with -ReleaseMbid <mbid>.
"@
    }
    $lookupSource = 'TextSearch'
    $releaseMbidResolved = Search-ReleaseMbidByText `
        -AlbumArtist $existingArtist -Album $existingAlbum `
        -TrackCount $tracks.Count -PreferredCountry $PreferredCountry
    if (-not $releaseMbidResolved) {
        throw @"
Text search for '$existingArtist - $existingAlbum' returned no matches.
Re-run with -ReleaseMbid <mbid> (look it up at https://musicbrainz.org/).
"@
    }
    $releaseObject = Get-ReleaseFromMbid -Mbid $releaseMbidResolved
}

if (-not $releaseObject) {
    throw "MusicBrainz returned no release body for MBID '$releaseMbidResolved' (lookup=$lookupSource)."
}
Write-RipperLog INFO 'Update-Tags' "Resolved release MBID '$releaseMbidResolved' via $lookupSource."


# --- 3. Normalize via the existing parser ---------------------------------
# /ws/2/release/{mbid} returns the release object directly; the parser
# expects the disc-id-endpoint shape ({ releases: [<rel>] }), so wrap.
$wrapped    = [pscustomobject]@{ releases = @($releaseObject) }
$discIdHint = if ($discIdForTags) { $discIdForTags } else { '' }
$candidates = ConvertFrom-MusicBrainzDiscIdResponse -Response $wrapped -DiscId $discIdHint
if (-not $candidates -or @($candidates).Count -eq 0) {
    throw "Parser returned no candidates for release '$releaseMbidResolved'."
}
$metadata = @($candidates)[0]

# Sanity: track count parity. Multi-disc releases that don't carry our
# disc id will fall through to "first medium with tracks" — that's
# usually right, but warn if it disagrees with the file count.
if ($metadata.Tracks.Count -ne $tracks.Count) {
    Write-RipperLog WARN 'Update-Tags' (
        "Track-count mismatch: $($tracks.Count) FLAC files but MB medium has " +
        "$($metadata.Tracks.Count) tracks. This often means a multi-disc release " +
        "and the disc-id tag is missing or wrong. Aborting before tags get scrambled."
    )
    throw "Track-count mismatch ($($tracks.Count) files vs $($metadata.Tracks.Count) MB tracks). Re-run with -ReleaseMbid pointing at the right medium, or restore MUSICBRAINZ_DISCID first."
}


# --- 4. Cover art (optional refresh) --------------------------------------
$coverPath  = Join-Path $AlbumFolder 'cover.jpg'
$coverBytes = $null
if ($RefreshCoverArt) {
    Write-RipperLog INFO 'Update-Tags' "Refreshing cover art from CAA."
    $coverBytes = Get-RipperCoverArt -ReleaseMbid $releaseMbidResolved
    if ($coverBytes) {
        [System.IO.File]::WriteAllBytes($coverPath, $coverBytes)
        Write-RipperLog INFO 'Update-Tags' "Wrote refreshed cover.jpg ($($coverBytes.Length) bytes)."
    } else {
        Write-RipperLog WARN 'Update-Tags' "No cover art available at CAA for $releaseMbidResolved; keeping existing PICTURE block (if any)."
    }
}


# --- 5. Tag write (re-uses the Phase-5 pipeline) --------------------------
$discIdForWrite = if ($discIdForTags) { $discIdForTags } else { '' }
$result = Invoke-RipperWriteTags `
    -RipFolder      $AlbumFolder `
    -Metadata       $metadata `
    -DiscId         $discIdForWrite `
    -CoverArtBytes  $coverBytes `
    -SkipReplayGain:$SkipReplayGain `
    -MetaflacPath   $metaflac

# Tack on the lookup provenance for the caller / log.
$result | Add-Member -NotePropertyName LookupSource -NotePropertyValue $lookupSource -PassThru |
          Add-Member -NotePropertyName ReleaseMbid  -NotePropertyValue $releaseMbidResolved -PassThru | Out-Null

Write-RipperLog INFO 'Update-Tags' "Done. LookupSource=$lookupSource ReleaseMbid=$releaseMbidResolved Files=$($result.FlacFiles.Count) ElapsedMs=$($result.ElapsedMs)"
Stop-RipperLog
return $result
