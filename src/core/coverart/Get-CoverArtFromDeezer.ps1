<#
.SYNOPSIS
    Cover-art provider: Deezer (free, no auth).

.DESCRIPTION
    Searches https://api.deezer.com/search/album for an album matching
    the candidate's artist + album. Deezer exposes four cover-size
    fields on each album result: cover, cover_small (56x56), cover_medium
    (250x250), cover_big (500x500), cover_xl (1000x1000). We fetch
    cover_xl. Deezer's source uploads are themselves 1000x1000 master
    files, so requesting larger doesn't help.

    Pipeline position:
        Plug-in for the cover-art chain orchestrated by
        src/core/coverart/Get-CoverArt.ps1.

    Provider contract: see Get-CoverArtFromCoverArtArchive.ps1.

.NOTES
    No API key required for the public search/album endpoints.

    Per-process throttle: minimum 25 ms gap between API calls
    (~40 req/sec, comfortably below Deezer's documented 50 req/sec/IP
    soft cap). Invisible at one-rip-at-a-time cadence; defensive
    against a future batch-tag use case. The CDN download of the
    actual image (cover_xl URL) is not an API call and is not
    throttled. See `docs/DECISIONS.md` D-030.

    User-Agent: identifies as `MusicRipper/<version> ( <contactAddress> )`
    when cfg.contactAddress is set, else plain `MusicRipper/<version>`.
    Deezer's ToU does not require an identifying UA (vs MusicBrainz
    which does), but it's good citizenship -- parallel to MB / CTDB /
    GnuDB.

    Reference: https://developers.deezer.com/api/album
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

# Per-process throttle state for the cover-art Deezer search call.
# Independent from the metadata text-search provider's counter
# (different file scope); the two don't fire concurrently in practice.
$script:LastDeezerCoverArtRequestTicks = 0L

function Wait-RipperDeezerCoverArtThrottle {
<#
.SYNOPSIS
    Sleep until at least 25 ms have elapsed since the previous Deezer
    API call from this provider in this process.

.DESCRIPTION
    Internal helper. See file-level .NOTES + D-030 for rationale.
#>
    [CmdletBinding()] param()
    $minIntervalTicks = [TimeSpan]::FromMilliseconds(25).Ticks
    $now = [DateTime]::UtcNow.Ticks
    $elapsed = $now - $script:LastDeezerCoverArtRequestTicks
    if ($script:LastDeezerCoverArtRequestTicks -gt 0 -and $elapsed -lt $minIntervalTicks) {
        $sleepMs = [int][math]::Ceiling(([double]($minIntervalTicks - $elapsed)) / [TimeSpan]::TicksPerMillisecond)
        Start-Sleep -Milliseconds $sleepMs
    }
    $script:LastDeezerCoverArtRequestTicks = [DateTime]::UtcNow.Ticks
}

function Get-RipperDeezerUserAgent {
<#
.SYNOPSIS
    Compose the Deezer User-Agent header from cfg.contactAddress +
    Get-RipperVersion. Falls back to plain version-only when config is
    unreadable or contactAddress is blank.

.DESCRIPTION
    Internal helper. Deezer doesn't *require* an identifying UA, but
    sending one is parallel to the MB / CTDB / GnuDB convention.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $contact = ''
    try {
        Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
        $cfgLocal = Import-RipperConfig
        if ($cfgLocal.PSObject.Properties['contactAddress'] -and $cfgLocal.contactAddress) {
            $contact = [string]$cfgLocal.contactAddress
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($contact)) {
        "MusicRipper/$(Get-RipperVersion)"
    } else {
        "MusicRipper/$(Get-RipperVersion) ( $contact )"
    }
}

function Invoke-DeezerCoverArtProvider {
<#
.SYNOPSIS
    Cover-art provider entry point: try Deezer for a candidate.

.PARAMETER Candidate
    The chosen metadata candidate. Uses .AlbumArtist + .Album for the
    query.

.EXAMPLE
    PS> $r = Invoke-DeezerCoverArtProvider -Candidate $best
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject]$Candidate)

    $artist = if ($Candidate.PSObject.Properties['AlbumArtist'] -and $Candidate.AlbumArtist) { [string]$Candidate.AlbumArtist } else { $null }
    $album  = if ($Candidate.PSObject.Properties['Album']       -and $Candidate.Album)       { [string]$Candidate.Album }       else { $null }
    if (-not $artist -or -not $album) {
        return [pscustomobject]@{ Source='Deezer'; Bytes=$null; Url=$null; Diagnostic='Candidate missing AlbumArtist/Album.' }
    }

    # Deezer's advanced query syntax lets us scope the term to fields
    # ("artist:foo album:bar") which dramatically improves precision
    # over a free-text search. URL-encoded as one string.
    $term = [System.Uri]::EscapeDataString("artist:`"$artist`" album:`"$album`"")
    $searchUrl = "https://api.deezer.com/search/album?q=$term&limit=5"
    $ua = Get-RipperDeezerUserAgent

    try {
        Wait-RipperDeezerCoverArtThrottle
        $resp = Invoke-RestMethod -Uri $searchUrl -TimeoutSec 30 -UseBasicParsing -Headers @{ 'User-Agent' = $ua }
    } catch {
        $msg = "Deezer search failed: $($_.Exception.Message)"
        Write-RipperLog INFO 'Get-CoverArt' "Deezer: $msg"
        return [pscustomobject]@{ Source='Deezer'; Bytes=$null; Url=$searchUrl; Diagnostic=$msg }
    }

    if (-not $resp -or -not $resp.PSObject.Properties['data'] -or -not $resp.data -or @($resp.data).Count -eq 0) {
        Write-RipperLog INFO 'Get-CoverArt' "Deezer: no results for '$artist - $album'."
        return [pscustomobject]@{ Source='Deezer'; Bytes=$null; Url=$searchUrl; Diagnostic='No results.' }
    }

    $top = @($resp.data)[0]
    # Prefer cover_xl (1000), then cover_big (500), then cover_medium (250).
    $artUrl = $null
    foreach ($field in 'cover_xl', 'cover_big', 'cover_medium', 'cover') {
        if ($top.PSObject.Properties[$field] -and $top.$field) {
            $artUrl = [string]$top.$field
            break
        }
    }
    if (-not $artUrl) {
        return [pscustomobject]@{ Source='Deezer'; Bytes=$null; Url=$searchUrl; Diagnostic='Top result has no cover URL.' }
    }

    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri $artUrl -OutFile $tmp -TimeoutSec 30 -UseBasicParsing | Out-Null
            $bytes = [System.IO.File]::ReadAllBytes($tmp)
            Write-RipperLog INFO 'Get-CoverArt' "Deezer: got $($bytes.Length) bytes from $artUrl"
            return [pscustomobject]@{ Source='Deezer'; Bytes=$bytes; Url=$artUrl; Diagnostic=$null }
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
    } catch {
        $msg = "Deezer image fetch failed: $($_.Exception.Message)"
        Write-RipperLog INFO 'Get-CoverArt' "Deezer: $msg"
        return [pscustomobject]@{ Source='Deezer'; Bytes=$null; Url=$artUrl; Diagnostic=$msg }
    }
}
