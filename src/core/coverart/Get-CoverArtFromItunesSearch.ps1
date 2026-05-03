<#
.SYNOPSIS
    Cover-art provider: iTunes Search API (free, no auth).

.DESCRIPTION
    Searches https://itunes.apple.com/search for an album matching the
    candidate's artist + album, then upgrades the returned artworkUrl100
    (a 100x100 px thumbnail) to the maximum-resolution version by
    rewriting the trailing "100x100bb.jpg" segment to a much larger
    dimension. Apple's CDN happily serves anything up to ~3000x3000 px
    via this trick (see .NOTES for source).

    Pipeline position:
        Plug-in for the cover-art chain orchestrated by
        src/core/coverart/Get-CoverArt.ps1.

    Provider contract: see Get-CoverArtFromCoverArtArchive.ps1.

.NOTES
    No API key required. Apple's published soft rate limit is
    ~20 req/min from a single IP. We enforce a per-process minimum
    of 1500 ms between iTunes API calls (~40 req/min) -- still well
    below Apple's burst threshold and invisible during normal
    rip-one-disc-at-a-time use. The CDN downloads (3000x3000bb.jpg
    etc.) are not iTunes API calls and are not throttled.
    See `docs/DECISIONS.md` D-028 for the rationale.

    The artworkUrl100 -> artworkUrl{N}x{N} trick is well-documented
    community knowledge:
      https://www.reddit.com/r/iOSProgramming/comments/82tv6b/
      https://itunes.apple.com/search?term=Pink+Floyd+Dark+Side&entity=album

    We cap at 3000x3000 because Apple sometimes 404s on requests above
    ~3500 (depends on the original master upload size). 3000px JPEGs
    are typically 800 KB - 2 MB; well within Plex / Picard tolerance,
    and resampleable down by tag-writers if needed.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

# Per-process throttle state for the iTunes Search API call this
# provider issues. Independent from the metadata-provider counter
# (different file scope); coordinated rate-limiting across both
# would need a global, and in practice they don't fire concurrently.
$script:LastItunesCoverArtRequestTicks = 0L

function Wait-RipperItunesCoverArtThrottle {
<#
.SYNOPSIS
    Sleep until at least 1500 ms have elapsed since the previous
    iTunes Search call from this provider in this process.

.DESCRIPTION
    Internal helper. See file-level .NOTES + D-028 for rationale.
#>
    [CmdletBinding()] param()
    $minIntervalTicks = [TimeSpan]::FromMilliseconds(1500).Ticks
    $now = [DateTime]::UtcNow.Ticks
    $elapsed = $now - $script:LastItunesCoverArtRequestTicks
    if ($script:LastItunesCoverArtRequestTicks -gt 0 -and $elapsed -lt $minIntervalTicks) {
        $sleepMs = [int][math]::Ceiling(([double]($minIntervalTicks - $elapsed)) / [TimeSpan]::TicksPerMillisecond)
        Start-Sleep -Milliseconds $sleepMs
    }
    $script:LastItunesCoverArtRequestTicks = [DateTime]::UtcNow.Ticks
}

function Invoke-ItunesSearchCoverArtProvider {
<#
.SYNOPSIS
    Cover-art provider entry point: try iTunes Search for a candidate.

.PARAMETER Candidate
    The chosen metadata candidate. Uses .AlbumArtist + .Album for the
    query. Returns Bytes=$null when either is missing or when iTunes
    has nothing.

.EXAMPLE
    PS> $r = Invoke-ItunesSearchCoverArtProvider -Candidate $best
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject]$Candidate)

    $artist = if ($Candidate.PSObject.Properties['AlbumArtist'] -and $Candidate.AlbumArtist) { [string]$Candidate.AlbumArtist } else { $null }
    $album  = if ($Candidate.PSObject.Properties['Album']       -and $Candidate.Album)       { [string]$Candidate.Album }       else { $null }
    if (-not $artist -or -not $album) {
        return [pscustomobject]@{ Source='iTunesSearch'; Bytes=$null; Url=$null; Diagnostic='Candidate missing AlbumArtist/Album.' }
    }

    $term = [System.Uri]::EscapeDataString("$artist $album")
    $searchUrl = "https://itunes.apple.com/search?term=$term&entity=album&limit=5"

    try {
        Wait-RipperItunesCoverArtThrottle
        $resp = Invoke-RestMethod -Uri $searchUrl -TimeoutSec 30 -UseBasicParsing
    } catch {
        $msg = "iTunes search failed: $($_.Exception.Message)"
        Write-RipperLog INFO 'Get-CoverArt' "iTunes: $msg"
        return [pscustomobject]@{ Source='iTunesSearch'; Bytes=$null; Url=$searchUrl; Diagnostic=$msg }
    }

    if (-not $resp -or -not $resp.results -or @($resp.results).Count -eq 0) {
        Write-RipperLog INFO 'Get-CoverArt' "iTunes: no results for '$artist - $album'."
        return [pscustomobject]@{ Source='iTunesSearch'; Bytes=$null; Url=$searchUrl; Diagnostic='No results.' }
    }

    $top = @($resp.results)[0]
    if (-not $top.PSObject.Properties['artworkUrl100'] -or -not $top.artworkUrl100) {
        return [pscustomobject]@{ Source='iTunesSearch'; Bytes=$null; Url=$searchUrl; Diagnostic='Top result has no artworkUrl100.' }
    }

    # Upgrade the thumbnail URL to a high-res variant. Apple's CDN
    # transforms the {WxH}bb.jpg segment on the fly. We try 3000 first;
    # if that 404s some uploads only go up to 1400, so we fall back.
    $thumbUrl = [string]$top.artworkUrl100
    foreach ($size in @(3000, 1400, 600)) {
        $hiUrl = $thumbUrl -replace '100x100bb\.(jpg|png)$', "${size}x${size}bb.`$1"
        try {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                Invoke-WebRequest -Uri $hiUrl -OutFile $tmp -TimeoutSec 30 -UseBasicParsing | Out-Null
                $bytes = [System.IO.File]::ReadAllBytes($tmp)
                Write-RipperLog INFO 'Get-CoverArt' "iTunes: got $($bytes.Length) bytes from $hiUrl"
                return [pscustomobject]@{ Source='iTunesSearch'; Bytes=$bytes; Url=$hiUrl; Diagnostic=$null }
            } finally {
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            }
        } catch {
            # 404 at this size -- try the next-smaller size.
            continue
        }
    }

    Write-RipperLog INFO 'Get-CoverArt' "iTunes: every high-res variant 404'd for $thumbUrl."
    return [pscustomobject]@{ Source='iTunesSearch'; Bytes=$null; Url=$thumbUrl; Diagnostic='All high-res variants 404.' }
}
