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
            # Unary-comma wrap so PowerShell's pipeline doesn't unroll the
            # byte[] into Object[] of individual bytes when this function
            # returns. The caller unwraps with `,$x`-style indexing or by
            # accepting the wrapped form -- see Get-RipperBestCoverArt.
            return ,$resp.Bytes
        }
    }

    Write-RipperLog INFO 'Get-CoverArt' 'Cover-art chain: every provider came up empty.'
    return $null
}

function Get-RipperCoverArtCandidates {
<#
.SYNOPSIS
    Run every configured cover-art provider and return one response per
    provider (NOT short-circuit). Used by the "Change cover..." picker
    so the user can see all available images side-by-side.

.DESCRIPTION
    Parallel to Get-RipperCoverArtChain, but keeps going instead of
    stopping at the first non-empty Bytes. Returns an array of
    responses in provider-list order. Providers that came up empty
    or errored are still in the array (Bytes = $null) so the caller
    can decide whether to show a placeholder or hide them entirely.

.PARAMETER Candidate
    The chosen metadata candidate.

.PARAMETER Providers
    Optional override of the configured provider list (string[]). Same
    resolution order as Get-RipperCoverArtChain: param > cfg > default.

.EXAMPLE
    PS> $all = Get-RipperCoverArtCandidates -Candidate $best
    PS> $all | Where-Object { $_.Bytes } | Measure-Object  # count hits
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
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

    Write-RipperLog INFO 'Get-CoverArt' "Cover-art picker: querying all providers ($($Providers -join ', '))."

    $responses = foreach ($name in $Providers) {
        try {
            switch ($name) {
                'CoverArtArchive' { Invoke-CoverArtArchiveProvider     -Candidate $Candidate }
                'iTunesSearch'    { Invoke-ItunesSearchCoverArtProvider -Candidate $Candidate }
                'Deezer'          { Invoke-DeezerCoverArtProvider       -Candidate $Candidate }
                default {
                    Write-RipperLog WARN 'Get-CoverArt' "Unknown cover-art provider '$name'; skipping."
                    [pscustomobject]@{ Source=$name; Bytes=$null; Url=$null; Diagnostic='Unknown provider.' }
                }
            }
        } catch {
            Write-RipperLog WARN 'Get-CoverArt' "Provider '$name' threw: $($_.Exception.Message)"
            [pscustomobject]@{ Source=$name; Bytes=$null; Url=$null; Diagnostic=$_.Exception.Message }
        }
    }

    # Emit each response straight to the pipeline. Don't use the
    # unary-comma wrap (`,@($responses)`) here: that trick is only
    # needed for byte[] returns to stop PS from element-unrolling
    # the bytes. For an array of pscustomobjects, the normal
    # pipeline-unroll is what both `$x = func` (→ Object[]) and
    # `@(func)` (→ Object[]) already want.
    $responses
}

