<#
.SYNOPSIS
    Run a free-text artist/album metadata search across the configured
    text-search provider chain and return aggregated candidates.

.DESCRIPTION
    Pipeline position:
        Sibling of Get-DiscMetadata.ps1. Where that file looks releases
        up by disc-id, this one looks them up by user-typed strings —
        used by the confirm-dialog's "Search by text…" fallback when
        the disc-id round produced no usable match (or the wrong one).

    Provider model (Phase 5.2 text-search):
        Same uniform contract as the disc-id chain. Every provider that
        supports text search exposes
            Invoke-XxxTextSearchProvider -Artist -Album -Year
        and returns
            @{ Source; Status; BestMatch; Candidates; Diagnostic }
        Source carries the provider's name so the dialog can label
        rows in the candidates list.

        Supported providers:
            1. MusicBrainz   (Commit A — implemented)
            2. iTunes Search (Commit B — TBD)
            3. Deezer        (Commit B — TBD)
            4. GnuDB         (Commit C — TBD)

        Note: CTDB has no text-search API and is intentionally absent
        from the supported set even though it's a disc-id metadata
        provider.

    Result merging:
        Unlike the disc-id chain there is no synthesized "Merged"
        candidate — each text-search hit is a distinct release the user
        manually picks among. The aggregated list is returned as-is
        (provider-by-provider, in chain order).

.NOTES
    See docs/DECISIONS.md D-013 for the text-search rationale.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

# Re-use the disc-id provider files (each one ALSO defines its
# Invoke-XxxTextSearchProvider entry point, when supported).
. (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromMusicBrainz.ps1')

# Providers known to expose a text-search entry point. Extending this
# set to iTunes/Deezer/GnuDB happens in Commits B and C. The dialog
# uses Get-RipperTextSearchProviderNames to render its provider
# checkbox list, so adding a name here automatically makes it appear
# in the UI (so long as the provider is also in cfg.MetadataProviders).
$script:TextSearchSupported = @{
    'MusicBrainz' = $true
}

function Get-RipperTextSearchProviderNames {
<#
.SYNOPSIS
    Return the list of configured providers that support text search.

.DESCRIPTION
    Intersects cfg.MetadataProviders (the user's configured chain)
    with the hard-coded support set. Used by the dialog to render
    its provider checkboxes dynamically.

.EXAMPLE
    PS> Get-RipperTextSearchProviderNames
    MusicBrainz
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $configured = $null
    try {
        Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
        $cfg = Import-RipperConfig
        if ($cfg.PSObject.Properties['MetadataProviders'] -and $cfg.MetadataProviders) {
            $configured = @($cfg.MetadataProviders)
        }
    } catch {
        # Tests / fresh installs with no config — fall through to defaults.
    }
    if (-not $configured -or $configured.Count -eq 0) {
        $configured = @('MusicBrainz', 'CuetoolsDb', 'GnuDb')
    }

    , @($configured | Where-Object { $script:TextSearchSupported.ContainsKey($_) })
}

function Search-RipperMetadataByText {
<#
.SYNOPSIS
    Search the configured metadata provider chain by free-text
    artist/album and return aggregated candidates.

.DESCRIPTION
    Calls each requested provider's text-search entry point in chain
    order and concatenates their candidates. Each candidate carries
    its provider name in .Source.

.PARAMETER Artist
    Free-text artist (album-artist) query. Optional but at least one
    of -Artist or -Album must be non-empty.

.PARAMETER Album
    Free-text album/release title. Optional (see -Artist).

.PARAMETER Year
    Optional year filter passed through to providers that support it.

.PARAMETER Providers
    Optional override of the provider list (string[]). Defaults to
    Get-RipperTextSearchProviderNames. Names not in the supported set
    are skipped with a warning.

.EXAMPLE
    PS> $r = Search-RipperMetadataByText -Artist 'Pink Floyd' -Album 'The Wall'
    PS> $r.Candidates.Count
    5
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Artist,
        [string]$Album,
        [int]$Year,
        [string[]]$Providers
    )

    if ([string]::IsNullOrWhiteSpace($Artist) -and [string]::IsNullOrWhiteSpace($Album)) {
        return [pscustomobject]@{
            Status          = 'NoMatch'
            Candidates      = @()
            ProviderResults = @()
            Diagnostic      = 'Text search needs at least an artist or album.'
        }
    }

    if (-not $Providers -or $Providers.Count -eq 0) {
        $Providers = @(Get-RipperTextSearchProviderNames)
    }
    $Providers = @($Providers | Where-Object {
        if ($script:TextSearchSupported.ContainsKey($_)) { $true }
        else {
            Write-RipperLog WARN 'Search-DiscMetadataByText' "Provider '$_' has no text-search entry point; skipping."
            $false
        }
    })

    if ($Providers.Count -eq 0) {
        return [pscustomobject]@{
            Status          = 'NoMatch'
            Candidates      = @()
            ProviderResults = @()
            Diagnostic      = 'No text-search-capable providers configured.'
        }
    }

    Write-RipperLog INFO 'Search-DiscMetadataByText' "Text search: artist='$Artist' album='$Album' year=$Year providers=$($Providers -join ',')"

    $responses = foreach ($name in $Providers) {
        switch ($name) {
            'MusicBrainz' {
                Invoke-MusicBrainzTextSearchProvider -Artist $Artist -Album $Album -Year $Year
            }
            default {
                Write-RipperLog WARN 'Search-DiscMetadataByText' "Unknown text-search provider '$name'; skipping."
                $null
            }
        }
    }
    $responses = @($responses | Where-Object { $_ })

    $allCandidates = @()
    foreach ($r in $responses) {
        if ($r.Candidates) { $allCandidates += @($r.Candidates) }
    }

    $status = if ($allCandidates.Count -eq 0) {
        # If every provider was Offline/Error, surface that distinction.
        $bad = @($responses | Where-Object { $_.Status -in @('Offline','Error') })
        if ($bad.Count -gt 0 -and $bad.Count -eq $responses.Count) { 'Offline' } else { 'NoMatch' }
    } elseif ($allCandidates.Count -eq 1) { 'Match' }
      else { 'MultiMatch' }

    [pscustomobject]@{
        Status          = $status
        Candidates      = @($allCandidates)
        ProviderResults = @($responses)
        Diagnostic      = $null
    }
}
