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
            2. iTunes Search (Commit B — implemented)
            3. Deezer        (Commit B — implemented)
            4. GnuDB         (Commit C — implemented)

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
. (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromItunesSearch.ps1')
. (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromDeezer.ps1')
. (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromGnuDb.ps1')

# Providers known to expose a text-search entry point. Extending this
# set to GnuDB happens in Commit C. The dialog uses
# Get-RipperTextSearchProviderNames to render its provider checkbox
# list, so adding a name here automatically makes it appear in the UI.
#
# IsDiscIdCapable controls how the picker decides whether to surface
# a provider:
#   - true  -> only show when the user has it in cfg.MetadataProviders
#              (it's a disc-id chain member; respect the user's chain).
#   - false -> always show (text-search-only provider; not part of the
#              disc-id chain at all, so cfg.MetadataProviders has no
#              opinion on it).
$script:TextSearchSupported = @{
    'MusicBrainz'  = @{ IsDiscIdCapable = $true  }
    'GnuDb'        = @{ IsDiscIdCapable = $true  }
    'iTunesSearch' = @{ IsDiscIdCapable = $false }
    'Deezer'       = @{ IsDiscIdCapable = $false }
}

function Get-RipperTextSearchProviderNames {
<#
.SYNOPSIS
    Return the list of providers that should appear in the dialog's
    text-search picker.

.DESCRIPTION
    Combines two sets:
      1. Disc-id-capable providers from cfg.MetadataProviders that
         also expose a text-search entry point (MusicBrainz today;
         GnuDB once Commit C lands). The user's chain order is
         honored.
      2. Text-search-only providers (iTunesSearch, Deezer). They
         aren't in the disc-id chain so cfg.MetadataProviders has
         no say; they're appended after the configured ones.

    The result is the dynamic checkbox list inside the
    "Search by text…" sub-modal.

.EXAMPLE
    PS> Get-RipperTextSearchProviderNames
    MusicBrainz
    iTunesSearch
    Deezer
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

    $out = @()
    # 1. Configured disc-id-capable providers, in chain order.
    foreach ($name in $configured) {
        if ($script:TextSearchSupported.ContainsKey($name) -and
            $script:TextSearchSupported[$name].IsDiscIdCapable) {
            $out += $name
        }
    }
    # 2. Text-search-only providers (independent of cfg.MetadataProviders).
    foreach ($name in $script:TextSearchSupported.Keys) {
        if (-not $script:TextSearchSupported[$name].IsDiscIdCapable -and
            $out -notcontains $name) {
            $out += $name
        }
    }

    , @($out)
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
            'iTunesSearch' {
                Invoke-ItunesSearchTextSearchProvider -Artist $Artist -Album $Album -Year $Year
            }
            'Deezer' {
                Invoke-DeezerTextSearchProvider -Artist $Artist -Album $Album -Year $Year
            }
            'GnuDb' {
                Invoke-GnuDbTextSearchProvider -Artist $Artist -Album $Album -Year $Year
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
