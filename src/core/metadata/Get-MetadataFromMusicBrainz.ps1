<#
.SYNOPSIS
    Metadata provider: MusicBrainz.

.DESCRIPTION
    Pipeline position:
        Plug-in for the metadata-provider chain orchestrated by
        src/core/Get-DiscMetadata.ps1. The orchestrator calls
        Invoke-MusicBrainzMetadataProvider with a disc-id object and
        receives a normalized response in the uniform provider contract.

    Provider contract (every provider returns this shape):
        Source     : 'MusicBrainz' | 'CTDB' | ...   (constant per provider)
        Status     : 'Match' | 'MultiMatch' | 'NoMatch' | 'Offline' | 'Error'
        BestMatch  : provider's pick, or $null
        Candidates : array (length 0..N) of normalized candidate objects;
                     each candidate carries a .Source = this provider's name
                     so the merged orchestrator output can attribute rows
                     in the dropdown.
        Diagnostic : optional [string] free-text shown to the user when
                     Status = 'Offline' / 'Error'.

    The pure parsing and ranking helpers
    (ConvertFrom-MusicBrainzDiscIdResponse, Select-BestMusicBrainzCandidate)
    plus the throttled HTTP wrapper (Invoke-RipperMusicBrainzRequest) all
    live here. Get-DiscMetadata.ps1 was their previous home; they were
    moved verbatim and re-dot-sourced from there for back-compat with
    existing tests and Update-AlbumTags.

.NOTES
    See Get-DiscMetadata.ps1 .NOTES for MusicBrainz API + Cover Art
    Archive references and the rate-limiting story.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

# Per-process throttle state for MusicBrainz. UTC ticks of the last request.
$script:LastMbRequestTicks = 0L

# MBID for the "Various Artists" placeholder artist on MusicBrainz.
$script:VariousArtistsMbid = '89ad4ac3-39f7-470e-963a-56509c546377'

function ConvertFrom-MusicBrainzDiscIdResponse {
<#
.SYNOPSIS
    Parse a MusicBrainz /ws/2/discid/<id> JSON response into a candidates
    array of normalized metadata objects.

.DESCRIPTION
    Pure function — no network, no disk. See the per-field shape contract
    in the .DESCRIPTION block of Get-DiscMetadata.ps1.

.PARAMETER Response
    The parsed JSON response object (an `ConvertFrom-Json` result).

.PARAMETER DiscId
    The disc ID we queried with — used to pick which medium on a
    multi-disc release the inserted disc actually is.

.EXAMPLE
    PS> $json = Get-Content fixtures/single-match.json -Raw | ConvertFrom-Json
    PS> $candidates = ConvertFrom-MusicBrainzDiscIdResponse -Response $json -DiscId 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-'
    PS> $candidates.Count
    1
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Response,

        [Parameter(Mandatory)]
        [string]$DiscId
    )

    if ($null -eq $Response) { return @() }

    # MB returns an `error`/`releases:[]` shape on no-match depending on
    # endpoint variant; treat both as empty.
    $releases = if ($Response.PSObject.Properties.Name -contains 'releases') { $Response.releases } else { @() }
    if ($null -eq $releases -or $releases.Count -eq 0) { return @() }

    $out = foreach ($rel in $releases) {
        # Find the medium (= "disc N") whose disc-id list contains the one
        # we queried with. Multi-disc releases will list multiple media; we
        # only care about the one that matches.
        $matchingMedium = $null
        $discNumber     = 1
        $totalDiscs     = if ($rel.media) { @($rel.media).Count } else { 1 }
        if ($rel.media) {
            foreach ($m in $rel.media) {
                # `discs` is only present when the release was fetched via
                # /discid/ (or /release/?inc=discids). The plain
                # /release/{mbid}?inc=artists+recordings+release-groups+labels
                # response Update-AlbumTags uses doesn't include it, so guard
                # under strict mode.
                if ($m.PSObject.Properties['discs'] -and $m.discs) {
                    foreach ($d in $m.discs) {
                        if ($d.id -eq $DiscId) {
                            $matchingMedium = $m
                            $discNumber     = [int]$m.position
                            break
                        }
                    }
                }
                if ($matchingMedium) { break }
            }
            # Fallback: if no medium explicitly listed our disc-id, pick the
            # first medium that has tracks. (Happens when MB returned the
            # release via toc-fuzzy-match rather than exact disc-id match.)
            if (-not $matchingMedium) {
                $matchingMedium = @($rel.media) | Where-Object { $_.tracks } | Select-Object -First 1
            }
        }

        # Media format (e.g. 'CD', 'Digital Media', 'Vinyl') from the matching
        # medium. Picard's MEDIA tag.
        $mediaFormat = $null
        if ($matchingMedium -and $matchingMedium.PSObject.Properties['format'] -and $matchingMedium.format) {
            $mediaFormat = [string]$matchingMedium.format
        }

        # Album-level artist credit -> joined phrase (handles "Foo feat. Bar").
        $albumArtist = ($rel.'artist-credit' | ForEach-Object {
            "$($_.name)$($_.joinphrase)"
        }) -join ''
        # Multi-value album artists (Picard ALBUMARTISTS): one entry per
        # artist-credit, no joinphrases. Stored as a string[] so callers can
        # emit multiple ALBUMARTISTS=... tag lines.
        $albumArtists = @($rel.'artist-credit' | ForEach-Object { [string]$_.name } | Where-Object { $_ })
        # Sort form: same shape as the joined ALBUMARTIST string, just
        # substituting artist.sort-name for artist.name. Picard preserves
        # the artist-credit joinphrases (' & ', ' feat. ', etc.) here too,
        # so a credit of 'X & Y' renders as 'Xsort & Ysort' (NOT 'Xsort;
        # Ysort'). The '; ' MULTI_VALUED_JOINER applies only to the
        # parallel multi-value ALBUMARTISTS tag, not to this joined form.
        $albumArtistSort = ($rel.'artist-credit' | ForEach-Object {
            $sn = $_.name
            if ($_.PSObject.Properties['artist'] -and $_.artist) {
                if ($_.artist.PSObject.Properties['sort-name'] -and $_.artist.'sort-name') {
                    $sn = $_.artist.'sort-name'
                }
            }
            "$sn$($_.joinphrase)"
        }) -join ''
        # Per-credit album-artist MBIDs (Picard parity). Stored as a
        # string[] so callers emit one MUSICBRAINZ_ALBUMARTISTID= line
        # per credited artist, matching Picard's behavior. Falls back to
        # an empty array when MB returned no artist objects.
        $albumArtistMbid = if ($rel.'artist-credit') {
            @($rel.'artist-credit' | ForEach-Object {
                if ($_.artist) { [string]$_.artist.id } else { $null }
            } | Where-Object { $_ })
        } else { @() }

        # Year: first 4 chars of release.date if present.
        $year = $null
        if ($rel.date -and $rel.date -match '^(\d{4})') { $year = [int]$Matches[1] }
        $releaseDate = if ($rel.date) { [string]$rel.date } else { $null }

        # Original (release-group) first release date.
        $originalDate = $null
        $originalYear = $null
        if ($rel.'release-group' -and $rel.'release-group'.PSObject.Properties['first-release-date'] `
                -and $rel.'release-group'.'first-release-date') {
            $originalDate = [string]$rel.'release-group'.'first-release-date'
            if ($originalDate -match '^(\d{4})') { $originalYear = [int]$Matches[1] }
        }

        # Release type: release-group.primary-type, e.g. 'Album', 'EP', 'Single'.
        $releaseType = $null
        if ($rel.'release-group' -and $rel.'release-group'.PSObject.Properties['primary-type'] `
                -and $rel.'release-group'.'primary-type') {
            $releaseType = [string]$rel.'release-group'.'primary-type'
        }

        # Status, script, language, asin, barcode -- straight pulls (strict-safe).
        $releaseStatus = if ($rel.PSObject.Properties['status']  -and $rel.status)  { [string]$rel.status }  else { $null }
        $asin          = if ($rel.PSObject.Properties['asin']    -and $rel.asin)    { [string]$rel.asin }    else { $null }
        $barcode       = if ($rel.PSObject.Properties['barcode'] -and $rel.barcode) { [string]$rel.barcode } else { $null }
        $script        = $null
        $language      = $null
        if ($rel.PSObject.Properties['text-representation'] -and $rel.'text-representation') {
            $tr = $rel.'text-representation'
            if ($tr.PSObject.Properties['script']   -and $tr.script)   { $script   = [string]$tr.script }
            if ($tr.PSObject.Properties['language'] -and $tr.language) { $language = [string]$tr.language }
        }

        # Label / catalog-number from the first label-info entry. Releases
        # often have multiple labels; we pick the first as the canonical
        # one (matches Picard's default behaviour).
        $labelName     = $null
        $catalogNumber = $null
        if ($rel.PSObject.Properties['label-info'] -and $rel.'label-info' -and @($rel.'label-info').Count -gt 0) {
            $li = @($rel.'label-info')[0]
            if ($li.PSObject.Properties['label']          -and $li.label -and $li.label.name) { $labelName     = [string]$li.label.name }
            if ($li.PSObject.Properties['catalog-number'] -and $li.'catalog-number')          { $catalogNumber = [string]$li.'catalog-number' }
        }

        # Compilation? Two signals: VA artist OR release-group secondary-type.
        $isCompilation = $false
        if ($albumArtistMbid -eq $script:VariousArtistsMbid) { $isCompilation = $true }
        if ($rel.'release-group' -and $rel.'release-group'.'secondary-types') {
            if (@($rel.'release-group'.'secondary-types') -contains 'Compilation') {
                $isCompilation = $true
            }
        }

        # Cover art availability flag from the release record. The actual
        # bytes are fetched separately by Get-RipperCoverArt.
        $hasCoverArt = $false
        if ($rel.'cover-art-archive') {
            $hasCoverArt = [bool]$rel.'cover-art-archive'.front
        }

        # Per-track normalization.
        $tracks = @()
        if ($matchingMedium -and $matchingMedium.tracks) {
            $tracks = foreach ($t in $matchingMedium.tracks) {
                $trackArtist = ($t.'artist-credit' | ForEach-Object {
                    "$($_.name)$($_.joinphrase)"
                }) -join ''
                # Multi-value form (Picard ARTISTS).
                $trackArtists = @($t.'artist-credit' | ForEach-Object { [string]$_.name } | Where-Object { $_ })
                $trackArtistSort = ($t.'artist-credit' | ForEach-Object {
                    $sn = $_.name
                    if ($_.PSObject.Properties['artist'] -and $_.artist) {
                        if ($_.artist.PSObject.Properties['sort-name'] -and $_.artist.'sort-name') {
                            $sn = $_.artist.'sort-name'
                        }
                    }
                    "$sn$($_.joinphrase)"
                }) -join ''
                # Per-credit track-artist MBIDs (Picard parity).
                $trackArtistMbid = if ($t.'artist-credit') {
                    @($t.'artist-credit' | ForEach-Object {
                        if ($_.artist) { [string]$_.artist.id } else { $null }
                    } | Where-Object { $_ })
                } else { @() }
                # Length: prefer track.length (medium-specific); fall back to
                # recording.length (canonical, may differ slightly).
                $lengthMs = if ($t.length) { [int]$t.length }
                            elseif ($t.recording -and $t.recording.length) { [int]$t.recording.length }
                            else { 0 }
                # Release-track MBID (Picard MUSICBRAINZ_RELEASETRACKID =
                # Picard's "MusicBrainz Track Id"). Distinct from the
                # recording MBID, which is per-recording across releases.
                $releaseTrackMbid = if ($t.PSObject.Properties['id'] -and $t.id) { [string]$t.id } else { $null }
                [pscustomobject]@{
                    Number           = [int]$t.position
                    Title            = [string]$t.title
                    Artist           = $trackArtist
                    Artists          = $trackArtists
                    ArtistSort       = $trackArtistSort
                    ArtistMbid       = $trackArtistMbid
                    RecordingMbid    = if ($t.recording) { [string]$t.recording.id } else { $null }
                    ReleaseTrackMbid = $releaseTrackMbid
                    LengthMs         = $lengthMs
                }
            }
        }

        [pscustomobject]@{
            Source           = 'MusicBrainz'
            AlbumArtist      = $albumArtist
            AlbumArtists     = $albumArtists
            AlbumArtistSort  = $albumArtistSort
            AlbumArtistMbid  = $albumArtistMbid
            Album            = [string]$rel.title
            Media            = $mediaFormat
            ReleaseMbid      = [string]$rel.id
            ReleaseGroupMbid = if ($rel.'release-group') { [string]$rel.'release-group'.id } else { $null }
            Year             = $year
            ReleaseDate      = $releaseDate
            OriginalYear     = $originalYear
            OriginalDate     = $originalDate
            Country          = [string]$rel.country
            ReleaseStatus    = $releaseStatus
            ReleaseType      = $releaseType
            Script           = $script
            Language         = $language
            Asin             = $asin
            Barcode          = $barcode
            LabelName        = $labelName
            CatalogNumber    = $catalogNumber
            TrackCount       = @($tracks).Count
            DiscNumber       = $discNumber
            TotalDiscs       = $totalDiscs
            IsCompilation    = $isCompilation
            HasCoverArt      = $hasCoverArt
            Tracks           = @($tracks)
        }
    }

    @($out)
}

function Select-BestMusicBrainzCandidate {
<#
.SYNOPSIS
    Pick the highest-ranked candidate from a candidates array.

.DESCRIPTION
    Pure ranking function. Sort priority:
        1. Has cover art            (true beats false)
        2. Country preference       (PreferredCountry first, then 'US', 'GB',
                                     'XW' (worldwide), then everything else)
        3. Earliest release date    (canonical pressing tends to be the
                                     oldest dated release in the group)

    Returns $null on empty input. Single candidate -> returned as-is
    without ranking.

.PARAMETER Candidates
    The array from ConvertFrom-MusicBrainzDiscIdResponse.

.PARAMETER PreferredCountry
    Optional 2-letter ISO country code that wins ties before 'US'/'GB'.

.EXAMPLE
    PS> $best = Select-BestMusicBrainzCandidate -Candidates $candidates
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        $Candidates,

        [string]$PreferredCountry
    )

    $list = @($Candidates)
    if ($list.Count -eq 0) { return $null }
    if ($list.Count -eq 1) { return $list[0] }

    # Country score: lower is better (so Sort-Object ascending puts winner first).
    $countryScore = {
        param($c)
        if (-not $c) { return 9 }
        if ($PreferredCountry -and $c -eq $PreferredCountry) { return 0 }
        switch ($c) {
            'US' { 1 }
            'GB' { 2 }
            'XW' { 3 }   # MB code for "Worldwide"
            'XE' { 4 }   # "Europe"
            default { 8 }
        }
    }

    $list |
        Sort-Object `
            @{ Expression = { -not $_.HasCoverArt };       Ascending = $true }, `
            @{ Expression = { & $countryScore $_.Country }; Ascending = $true }, `
            @{ Expression = { if ($_.Year) { $_.Year } else { 9999 } }; Ascending = $true } |
        Select-Object -First 1
}

function Invoke-RipperMusicBrainzRequest {
<#
.SYNOPSIS
    HTTP GET against MusicBrainz with throttle + UA + JSON output.

.DESCRIPTION
    Anonymous MB clients are limited to 1 req/sec. We enforce >= 1100 ms
    between requests in this process. The UA is loaded from config.json
    (set by setup/New-RipperConfig.ps1).

.PARAMETER Url
    Full URL to GET. Caller is responsible for `&fmt=json` etc.

.EXAMPLE
    PS> $r = Invoke-RipperMusicBrainzRequest -Url 'https://musicbrainz.org/ws/2/discid/Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-?inc=artists+recordings+release-groups&fmt=json'

.NOTES
    Returns a parsed JSON object on 2xx, $null on 404 (= "no match"),
    throws on any other status.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Url
    )

    Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
    $cfg = Import-RipperConfig
    $ua  = $cfg.MusicBrainzUserAgent
    if (-not $ua) { throw "config.json missing MusicBrainzUserAgent. Re-run setup/New-RipperConfig.ps1." }

    # Throttle. MB asks for <= 1 req/sec; we leave 100 ms slack.
    $minIntervalTicks = [TimeSpan]::FromMilliseconds(1100).Ticks
    $now = [DateTime]::UtcNow.Ticks
    $elapsed = $now - $script:LastMbRequestTicks
    if ($script:LastMbRequestTicks -gt 0 -and $elapsed -lt $minIntervalTicks) {
        $sleepMs = [int][math]::Ceiling(([double]($minIntervalTicks - $elapsed)) / [TimeSpan]::TicksPerMillisecond)
        Start-Sleep -Milliseconds $sleepMs
    }
    $script:LastMbRequestTicks = [DateTime]::UtcNow.Ticks

    try {
        $resp = Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = $ua; 'Accept' = 'application/json' } `
                                  -TimeoutSec 30
        return $resp
    } catch {
        # 404 = no match for this disc id; that's a normal outcome, not an error.
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-RipperLog INFO 'Get-DiscMetadata' "MusicBrainz returned 404 for $Url (no match)."
            return $null
        }
        throw
    }
}

function Invoke-MusicBrainzMetadataProvider {
<#
.SYNOPSIS
    Provider entry point: query MusicBrainz for a disc and return the
    uniform provider response shape.

.DESCRIPTION
    See the file-level provider-contract docstring. Wraps the existing
    MB request + parse + rank pipeline so the orchestrator can mix it
    with other providers (CTDB, ...) using a single call signature.

.PARAMETER DiscIdInfo
    Disc-id object from Get-RipperDiscId.

.PARAMETER PreferredCountry
    Optional ISO country code passed through to the ranking step.

.EXAMPLE
    PS> Invoke-MusicBrainzMetadataProvider -DiscIdInfo $disc
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject]$DiscIdInfo,
        [string]$PreferredCountry = 'US'
    )

    $url = 'https://musicbrainz.org/ws/2/discid/' + $DiscIdInfo.DiscId +
           '?inc=artists+recordings+release-groups+labels&fmt=json'

    Write-RipperLog INFO 'MusicBrainz' "Querying MusicBrainz for disc id $($DiscIdInfo.DiscId)."

    try {
        $response = Invoke-RipperMusicBrainzRequest -Url $url
    } catch {
        $msg = "MusicBrainz request failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'MusicBrainz' $msg
        return [pscustomobject]@{
            Source     = 'MusicBrainz'
            Status     = 'Offline'
            BestMatch  = $null
            Candidates = @()
            Diagnostic = $msg
        }
    }

    $candidates = ConvertFrom-MusicBrainzDiscIdResponse -Response $response -DiscId $DiscIdInfo.DiscId

    if (-not $candidates -or $candidates.Count -eq 0) {
        Write-RipperLog INFO 'MusicBrainz' "No MusicBrainz match for disc id $($DiscIdInfo.DiscId)."
        return [pscustomobject]@{
            Source     = 'MusicBrainz'
            Status     = 'NoMatch'
            BestMatch  = $null
            Candidates = @()
            Diagnostic = $null
        }
    }

    $best = Select-BestMusicBrainzCandidate -Candidates $candidates -PreferredCountry $PreferredCountry
    $status = if ($candidates.Count -gt 1) { 'MultiMatch' } else { 'Match' }
    Write-RipperLog INFO 'MusicBrainz' `
        "Status=$status, $($candidates.Count) candidate(s); best='$($best.AlbumArtist) - $($best.Album)'."

    [pscustomobject]@{
        Source     = 'MusicBrainz'
        Status     = $status
        BestMatch  = $best
        Candidates = @($candidates)
        Diagnostic = $null
    }
}
