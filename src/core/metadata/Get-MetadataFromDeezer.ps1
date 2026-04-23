<#
.SYNOPSIS
    Metadata provider: Deezer (free, no auth) — text-search only.

.DESCRIPTION
    Pipeline position:
        Plug-in for the text-search orchestrator in
        src/core/Search-DiscMetadataByText.ps1. Deezer doesn't take CD
        TOCs / disc-ids, so this module is text-search ONLY.

    Provider contract: same uniform shape as MusicBrainz —
        @{ Source; Status; BestMatch; Candidates; Diagnostic }
    Each candidate is shaped like the MusicBrainz disc-id parser
    output enough that ConvertTo-/ConvertFrom-MetadataViewModel can
    round-trip without losing fields.

    Two-step lookup:
        1. /search/album?q=artist:"X" album:"Y"&limit=Limit
        2. /album/{id}                         (per top-N hit)
        Step 2 carries the per-track listing in tracks.data[].

.NOTES
    No API key needed for the public search/album endpoints.
    Reference: https://developers.deezer.com/api/album
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

function ConvertFrom-DeezerAlbumDetail {
<#
.SYNOPSIS
    Parse a Deezer /album/{id} response into a single normalized
    metadata candidate with .Tracks[] populated.

.DESCRIPTION
    Pure function — no network. Returns $null when the response is
    missing the album or has no tracks.

.PARAMETER Response
    Parsed JSON from Invoke-RestMethod.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Response
    )

    if (-not $Response) { return $null }
    if (-not $Response.PSObject.Properties['title'] -or -not $Response.title) { return $null }

    $albumTitle  = [string]$Response.title
    $albumArtist = ''
    if ($Response.PSObject.Properties['artist'] -and $Response.artist -and
        $Response.artist.PSObject.Properties['name']) {
        $albumArtist = [string]$Response.artist.name
    }

    $year = $null
    $releaseDate = $null
    if ($Response.PSObject.Properties['release_date'] -and $Response.release_date) {
        $releaseDate = [string]$Response.release_date
        if ($releaseDate -match '^(\d{4})') { $year = [int]$Matches[1] }
    }

    $isCompilation = $false
    if ($albumArtist -match '^(Various Artists?|VA)$') { $isCompilation = $true }
    if ($Response.PSObject.Properties['record_type'] -and $Response.record_type -eq 'compile') {
        $isCompilation = $true
    }

    $rawTracks = @()
    if ($Response.PSObject.Properties['tracks'] -and $Response.tracks -and
        $Response.tracks.PSObject.Properties['data']) {
        $rawTracks = @($Response.tracks.data)
    }

    $tracks = foreach ($t in $rawTracks) {
        $num   = if ($t.PSObject.Properties['track_position']) { [int]$t.track_position } else { 0 }
        $title = if ($t.PSObject.Properties['title'])          { [string]$t.title }       else { '' }
        $art   = $albumArtist
        if ($t.PSObject.Properties['artist'] -and $t.artist -and
            $t.artist.PSObject.Properties['name'] -and $t.artist.name) {
            $art = [string]$t.artist.name
        }
        # Deezer's `duration` is in whole seconds.
        $lenMs = if ($t.PSObject.Properties['duration']) { [int]$t.duration * 1000 } else { 0 }
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
    $tracks = @($tracks | Where-Object { $_.Number -gt 0 } | Sort-Object Number)

    $label = if ($Response.PSObject.Properties['label']) { [string]$Response.label } else { $null }
    $upc   = if ($Response.PSObject.Properties['upc'])   { [string]$Response.upc }   else { $null }
    $hasArt = $false
    foreach ($f in 'cover_xl','cover_big','cover_medium','cover') {
        if ($Response.PSObject.Properties[$f] -and $Response.$f) { $hasArt = $true; break }
    }

    [pscustomobject]@{
        Source           = 'Deezer'
        AlbumArtist      = $albumArtist
        AlbumArtists     = @($albumArtist) | Where-Object { $_ }
        AlbumArtistSort  = $albumArtist
        AlbumArtistMbid  = @()
        Album            = $albumTitle
        Media            = 'Digital Media'
        ReleaseMbid      = $null
        ReleaseGroupMbid = $null
        Year             = $year
        ReleaseDate      = $releaseDate
        OriginalYear     = $year
        OriginalDate     = $null
        Country          = $null
        ReleaseStatus    = $null
        ReleaseType      = if ($Response.PSObject.Properties['record_type']) { [string]$Response.record_type } else { 'album' }
        Script           = $null
        Language         = $null
        Asin             = $null
        Barcode          = $upc
        LabelName        = $label
        CatalogNumber    = $null
        TrackCount       = if ($Response.PSObject.Properties['nb_tracks']) { [int]$Response.nb_tracks } else { @($tracks).Count }
        DiscNumber       = 1
        TotalDiscs       = 1
        IsCompilation    = $isCompilation
        HasCoverArt      = $hasArt
        Tracks           = @($tracks)
    }
}

function Invoke-DeezerTextSearchProvider {
<#
.SYNOPSIS
    Provider entry point: text-search Deezer by artist/album and return
    candidates in the uniform contract.

.PARAMETER Artist
    Album-artist text. Optional but at least one of -Artist or -Album
    must be non-empty.

.PARAMETER Album
    Album title text. Optional (see -Artist).

.PARAMETER Year
    Currently ignored — Deezer's search endpoint has no date filter.
    Accepted for interface parity.

.PARAMETER Limit
    Max album hits from /search/album. Defaults to 10.

.PARAMETER DetailLimit
    Max top-N albums to /album/{id} for full track listings. Defaults to 5.

.PARAMETER InvokeWebRequest
    Test seam — scriptblock invoked as `& $sb -Url <url>` instead of
    Invoke-RestMethod. Production callers omit this.

.EXAMPLE
    PS> Invoke-DeezerTextSearchProvider -Artist 'Pink Floyd' -Album 'The Wall'
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
            Source = 'Deezer'; Status = 'NoMatch'
            BestMatch = $null; Candidates = @()
            Diagnostic = 'Text search needs at least an artist or album.'
        }
    }

    # Deezer's advanced query syntax scopes terms to fields, much
    # better precision than free text. Quote each value so phrases stay
    # whole; Deezer treats unquoted spaces as ANDs.
    $parts = @()
    if ($Artist) { $parts += ('artist:"{0}"' -f ($Artist -replace '"','\"')) }
    if ($Album)  { $parts += ('album:"{0}"'  -f ($Album  -replace '"','\"')) }
    $q = $parts -join ' '
    $term = [System.Uri]::EscapeDataString($q)
    $searchUrl = "https://api.deezer.com/search/album?q=$term&limit=$Limit"

    $invoke = if ($InvokeWebRequest) { $InvokeWebRequest } else {
        { param($Url) Invoke-RestMethod -Uri $Url -TimeoutSec 30 -UseBasicParsing }
    }

    Write-RipperLog INFO 'Deezer' "Text search: '$Artist' / '$Album'"

    try {
        $searchResp = & $invoke -Url $searchUrl
    } catch {
        $msg = "Deezer search failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'Deezer' $msg
        return [pscustomobject]@{
            Source = 'Deezer'; Status = 'Offline'
            BestMatch = $null; Candidates = @()
            Diagnostic = $msg
        }
    }

    $hits = @()
    if ($searchResp -and $searchResp.PSObject.Properties['data']) { $hits = @($searchResp.data) }
    if ($hits.Count -eq 0) {
        Write-RipperLog INFO 'Deezer' "Text search: no albums for '$Artist' / '$Album'."
        return [pscustomobject]@{
            Source = 'Deezer'; Status = 'NoMatch'
            BestMatch = $null; Candidates = @()
            Diagnostic = $null
        }
    }

    $candidates = foreach ($h in ($hits | Select-Object -First $DetailLimit)) {
        if (-not $h.PSObject.Properties['id'] -or -not $h.id) { continue }
        $detailUrl = "https://api.deezer.com/album/$($h.id)"
        try {
            $detail = & $invoke -Url $detailUrl
            ConvertFrom-DeezerAlbumDetail -Response $detail
        } catch {
            Write-RipperLog WARN 'Deezer' "Album detail failed for id=$($h.id): $($_.Exception.Message)"
            $null
        }
    }
    $candidates = @($candidates | Where-Object { $_ })

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            Source = 'Deezer'; Status = 'NoMatch'
            BestMatch = $null; Candidates = @()
            Diagnostic = "Deezer returned $($hits.Count) album hit(s) but no detail records."
        }
    }

    $status = if ($candidates.Count -gt 1) { 'MultiMatch' } else { 'Match' }
    Write-RipperLog INFO 'Deezer' "Text search produced $($candidates.Count) candidate(s); top: '$($candidates[0].AlbumArtist) - $($candidates[0].Album)'."

    [pscustomobject]@{
        Source     = 'Deezer'
        Status     = $status
        BestMatch  = $candidates[0]
        Candidates = $candidates
        Diagnostic = $null
    }
}
