<#
.SYNOPSIS
    Run the configured cover-art provider chain for a chosen metadata
    candidate. First-non-empty wins.

.DESCRIPTION
    Pipeline position:
        Called from Get-RipperDiscMetadata (in src/core/Get-DiscMetadata.ps1)
        once it has picked a BestMatch. The returned bytes get attached
        to BestMatch.CoverArtBytes.

    Provider model (Phase 5.2, parallel to the metadata-provider model):
        Cover-art sources are pluggable. Each lives at
            src\core\coverart\Get-CoverArtFromXxx.ps1
        and exposes one entry-point function returning the uniform
        cover-art response shape:
            @{ Source; Bytes; Url; Diagnostic }
        See the file-level docstring of each provider for details.

        Default priority list (most-trusted first):
            1. CoverArtArchive  -- MB-tied, accurate per-release art.
            2. iTunesSearch     -- huge catalog, no auth, hi-res.
            3. Deezer           -- third backstop.
        Configurable via cfg.CoverArtProviders (string[]).

        Deferred for a later round (intentionally NOT v1, see
        docs/DECISIONS.md): Discogs (needs token), fanart.tv (needs key),
        Apple Music API, Last.fm, Spotify, Amazon.

    First-non-null wins -- as soon as a provider returns Bytes != null,
    we stop and return them. Subsequent providers are not contacted, so
    the chain is also a "free network calls" optimization (CAA hits
    succeed on the most common case, and we never touch iTunes/Deezer).
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# This file lives at src\core\coverart\. Walk three parents up to the
# repo root so we can resolve src\lib\Logging.psd1 and the sibling
# provider files unambiguously.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

# Dot-source every provider so the orchestrator can dispatch by name.
. (Join-Path $PSScriptRoot 'Get-CoverArtFromCoverArtArchive.ps1')
. (Join-Path $PSScriptRoot 'Get-CoverArtFromItunesSearch.ps1')
. (Join-Path $PSScriptRoot 'Get-CoverArtFromDeezer.ps1')

function Get-RipperCoverArtChain {
<#
.SYNOPSIS
    Walk the configured cover-art provider chain and return the first
    non-empty image bytes (or $null if every provider came up empty).

.PARAMETER Candidate
    The chosen metadata candidate. Provider-specific lookup keys come
    from this object (.ReleaseMbid for CAA; .AlbumArtist + .Album for
    iTunes / Deezer).

.PARAMETER Providers
    Optional override of the configured provider list (string[]).
    Used by tests; production callers omit this and accept the
    config.json setting (default:
    @('CoverArtArchive','iTunesSearch','Deezer')).

.EXAMPLE
    PS> $bytes = Get-RipperCoverArtChain -Candidate $best
#>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [pscustomobject]$Candidate,
        [string[]]$Providers
    )

    if (-not $Providers) {
        try {
            Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
            $cfg = Import-RipperConfig
            if ($cfg.PSObject.Properties['CoverArtProviders'] -and $cfg.CoverArtProviders) {
                $Providers = @($cfg.CoverArtProviders)
            }
        } catch { }
        if (-not $Providers -or $Providers.Count -eq 0) {
            $Providers = @('CoverArtArchive','iTunesSearch','Deezer')
        }
    }

    Write-RipperLog INFO 'Get-CoverArt' "Cover-art chain: $($Providers -join ', ')"

    foreach ($name in $Providers) {
        $resp = switch ($name) {
            'CoverArtArchive' { Invoke-CoverArtArchiveProvider     -Candidate $Candidate }
            'iTunesSearch'    { Invoke-ItunesSearchCoverArtProvider -Candidate $Candidate }
            'Deezer'          { Invoke-DeezerCoverArtProvider       -Candidate $Candidate }
            default {
                Write-RipperLog WARN 'Get-CoverArt' "Unknown cover-art provider '$name'; skipping."
                $null
            }
        }
        if ($resp -and $resp.Bytes -and $resp.Bytes.Length -gt 0) {
            Write-RipperLog INFO 'Get-CoverArt' "Cover-art chain accepted bytes from $($resp.Source)."
            return $resp.Bytes
        }
    }

    Write-RipperLog INFO 'Get-CoverArt' 'Cover-art chain: every provider came up empty.'
    return $null
}
