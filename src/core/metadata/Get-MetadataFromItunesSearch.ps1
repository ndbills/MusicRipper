<#
.SYNOPSIS
    Metadata provider: iTunes Search API (free, no auth) — text-search only.

.DESCRIPTION
    Pipeline position:
        Plug-in for the text-search orchestrator in
        src/core/Search-DiscMetadataByText.ps1. iTunes does not expose
        a disc-id endpoint, so this module is text-search ONLY — it
        does not register an Invoke-ItunesMetadataProvider entry point
        in the disc-id chain.

    Provider contract: same uniform response shape as MusicBrainz —
        @{ Source; Status; BestMatch; Candidates; Diagnostic }
    Each candidate shape mirrors the MusicBrainz disc-id parser output
    enough for ConvertTo-MetadataViewModel + ConvertFrom-MetadataViewModel
    to round-trip without losing fields. iTunes carries no MBIDs, no
    barcode, no script/language, etc. — those land as $null.

    Two-step lookup:
        1. /search?term=Artist+Album&entity=album&limit=Limit
        2. /lookup?id={collectionId}&entity=song   (per top-N hit)
        Step 2 produces the per-track listing; the first row in the
        lookup response is the album record itself, songs follow.

.NOTES
    No API key required. Soft rate limit ~20 req/min from one IP.
    Reference: https://performance-partners.apple.com/search-api
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

function ConvertFrom-ItunesAlbumLookup {
<#
.SYNOPSIS
    Parse a /lookup?id={collectionId}&entity=song response into a single
    normalized metadata candidate with .Tracks[] populated.

.DESCRIPTION
    Pure function — no network. iTunes' lookup-with-songs response
    starts with the collection (album) wrapper followed by one entry
    per song; we use the wrapper for album fields and the rest as
    tracks (filtered to wrapperType=track / kind=song).

    Returns $null when the response has no album entry — so the
    caller can safely concatenate results.

.PARAMETER Response
    Parsed JSON from Invoke-RestMethod. Expected shape: { results:[...] }.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Response
    )

    if (-not $Response -or -not $Response.PSObject.Properties['results']) { return $null }
    $rows = @($Response.results)
    if ($rows.Count -eq 0) { return $null }

    # First row that's a collection (the album wrapper).
    $album = $rows | Where-Object {
        $_.PSObject.Properties['wrapperType'] -and $_.wrapperType -eq 'collection'
    } | Select-Object -First 1
    if (-not $album) { return $null }

    $songs = @($rows | Where-Object {
        $_.PSObject.Properties['wrapperType'] -and $_.wrapperType -eq 'track' -and
        (-not $_.PSObject.Properties['kind'] -or $_.kind -eq 'song')
    })

    $year = $null
    if ($album.PSObject.Properties['releaseDate'] -and $album.releaseDate -and
        $album.releaseDate -match '^(\d{4})') {
        $year = [int]$Matches[1]
    }

    $isCompilation = $false
    if ($album.PSObject.Properties['artistName'] -and $album.artistName) {
        if ([string]$album.artistName -match '^(Various Artists?|VA)$') { $isCompilation = $true }
    }

    $tracks = foreach ($s in $songs) {
        $num = if ($s.PSObject.Properties['trackNumber']) { [int]$s.trackNumber } else { 0 }
        $title = if ($s.PSObject.Properties['trackName']) { [string]$s.trackName } else { '' }
        $art   = if ($s.PSObject.Properties['artistName']) { [string]$s.artistName } else { '' }
        $lenMs = if ($s.PSObject.Properties['trackTimeMillis']) { [int]$s.trackTimeMillis } else { 0 }
        [pscustomobject]@{
            Number           = $num
            Title            = $title
            Artist           = $art
            Artists          = @($art) | Where-Object { $_ }
            ArtistSort       = $art
            ArtistMbid       = @()
            RecordingMbid    = $null
            ReleaseTrackMbid = $null
            LengthMs         = $lenMs
        }
    }
    # Sort + de-dup by track number; iTunes sometimes returns disc-2 tracks
    # interleaved when a release has multiple discs. Trust trackNumber.
    $tracks = @($tracks | Where-Object { $_.Number -gt 0 } | Sort-Object Number)

    $albumArtist = if ($album.PSObject.Properties['artistName']) { [string]$album.artistName } else { '' }
    $albumTitle  = if ($album.PSObject.Properties['collectionName']) { [string]$album.collectionName } else { '' }
    $country     = if ($album.PSObject.Properties['country']) { [string]$album.country } else { $null }
    $trackCount  = if ($album.PSObject.Properties['trackCount']) { [int]$album.trackCount } else { @($tracks).Count }
    $discCount   = if ($album.PSObject.Properties['discCount'])  { [int]$album.discCount }  else { 1 }

    # Carry the artwork URL forward so callers can fetch the image
    # directly without re-querying iTunes by AlbumArtist+Album (which
    # often misses for compilation/multi-artist titles). We hand back
    # the 600x600 variant; high enough quality for the dialog thumbnail
    # and the embedded FLAC cover, and small enough not to time out.
    $artworkUrl = $null
    if ($album.PSObject.Properties['artworkUrl100'] -and $album.artworkUrl100) {
        $artworkUrl = ([string]$album.artworkUrl100) -replace '100x100bb\.(jpg|png)$', '600x600bb.$1'
    }

    [pscustomobject]@{
        Source           = 'iTunesSearch'
        AlbumArtist      = $albumArtist
        AlbumArtists     = @($albumArtist) | Where-Object { $_ }
        AlbumArtistSort  = $albumArtist
        AlbumArtistMbid  = @()
        Album            = $albumTitle
        Media            = 'Digital Media'
        ReleaseMbid      = $null
        ReleaseGroupMbid = $null
        Year             = $year
        ReleaseDate      = if ($album.PSObject.Properties['releaseDate']) { [string]$album.releaseDate } else { $null }
        OriginalYear     = $year
        OriginalDate     = $null
        Country          = $country
        ReleaseStatus    = $null
        ReleaseType      = 'Album'
        Script           = $null
        Language         = $null
        Asin             = $null
        Barcode          = $null
        LabelName        = $null
        CatalogNumber    = $null
        TrackCount       = $trackCount
        DiscNumber       = 1
        TotalDiscs       = $discCount
        IsCompilation    = $isCompilation
        HasCoverArt      = ($album.PSObject.Properties['artworkUrl100'] -and [bool]$album.artworkUrl100)
        ArtworkUrl       = $artworkUrl
        Tracks           = @($tracks)
    }
}

function Invoke-ItunesSearchTextSearchProvider {
<#
.SYNOPSIS
    Provider entry point: text-search iTunes by artist/album and return
    candidates in the uniform contract.

.PARAMETER Artist
    Album-artist text. Optional but at least one of -Artist or -Album
    must be non-empty.

.PARAMETER Album
    Album title text. Optional (see -Artist).

.PARAMETER Year
    Currently unused by the iTunes search endpoint (no date filter
    parameter). Accepted for interface parity with the orchestrator
    so callers don't need to special-case providers.

.PARAMETER Limit
    Max album hits from /search. Defaults to 10.

.PARAMETER DetailLimit
    Max top-N albums to /lookup for full track listings. Defaults to 5.

.PARAMETER InvokeWebRequest
    Test seam — scriptblock invoked as `& $sb -Url <url>` instead of
    Invoke-RestMethod. Production callers omit this.

.EXAMPLE
    PS> Invoke-ItunesSearchTextSearchProvider -Artist 'Pink Floyd' -Album 'The Wall'
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Artist,
        [string]$Album,
        [int]$Year,
        [int]$Limit       = 10,
        [int]$DetailLimit = 5,
        [scriptblock]$InvokeWebRequest
    )

    if ([string]::IsNullOrWhiteSpace($Artist) -and [string]::IsNullOrWhiteSpace($Album)) {
        return [pscustomobject]@{
            Source = 'iTunesSearch'; Status = 'NoMatch'
            BestMatch = $null; Candidates = @()
            Diagnostic = 'Text search needs at least an artist or album.'
        }
    }

    $term = [System.Uri]::EscapeDataString(("$Artist $Album").Trim())
    $searchUrl = "https://itunes.apple.com/search?term=$term&entity=album&limit=$Limit"

    $invoke = if ($InvokeWebRequest) { $InvokeWebRequest } else {
        { param($Url) Invoke-RestMethod -Uri $Url -TimeoutSec 30 -UseBasicParsing }
    }

    Write-RipperLog INFO 'iTunesSearch' "Text search: '$Artist' / '$Album'"

    try {
        $searchResp = & $invoke -Url $searchUrl
    } catch {
        $msg = "iTunes search failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'iTunesSearch' $msg
        return [pscustomobject]@{
            Source = 'iTunesSearch'; Status = 'Offline'
            BestMatch = $null; Candidates = @()
            Diagnostic = $msg
        }
    }

    $hits = @()
    if ($searchResp -and $searchResp.PSObject.Properties['results']) { $hits = @($searchResp.results) }
    if ($hits.Count -eq 0) {
        Write-RipperLog INFO 'iTunesSearch' "Text search: no albums for '$Artist' / '$Album'."
        return [pscustomobject]@{
            Source = 'iTunesSearch'; Status = 'NoMatch'
            BestMatch = $null; Candidates = @()
            Diagnostic = $null
        }
    }

    $candidates = foreach ($h in ($hits | Select-Object -First $DetailLimit)) {
        if (-not $h.PSObject.Properties['collectionId'] -or -not $h.collectionId) { continue }
        $detailUrl = "https://itunes.apple.com/lookup?id=$($h.collectionId)&entity=song"
        try {
            $detail = & $invoke -Url $detailUrl
            ConvertFrom-ItunesAlbumLookup -Response $detail
        } catch {
            Write-RipperLog WARN 'iTunesSearch' "Lookup failed for id=$($h.collectionId): $($_.Exception.Message)"
            $null
        }
    }
    $candidates = @($candidates | Where-Object { $_ })

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            Source = 'iTunesSearch'; Status = 'NoMatch'
            BestMatch = $null; Candidates = @()
            Diagnostic = "iTunes returned $($hits.Count) album hit(s) but no detail records."
        }
    }

    $status = if ($candidates.Count -gt 1) { 'MultiMatch' } else { 'Match' }
    Write-RipperLog INFO 'iTunesSearch' "Text search produced $($candidates.Count) candidate(s); top: '$($candidates[0].AlbumArtist) - $($candidates[0].Album)'."

    [pscustomobject]@{
        Source     = 'iTunesSearch'
        Status     = $status
        BestMatch  = $candidates[0]
        Candidates = $candidates
        Diagnostic = $null
    }
}
