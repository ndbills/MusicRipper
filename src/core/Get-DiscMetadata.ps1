<#
.SYNOPSIS
    Look up disc metadata across a chain of providers and return a
    normalized result (single best + full candidates list).

.DESCRIPTION
    Pipeline position:
        Step 2 of the daily-flow sequence. Consumes the disc-id object
        produced by Get-DiscId.ps1 and emits the normalized metadata
        object Show-MetadataDialog (Phase 3) will display.

    Provider model (Phase 5.2):
        Metadata sources are pluggable. Each provider lives at
            src\core\metadata\Get-MetadataFromXxx.ps1
        and exposes one entry-point function returning a uniform
        response shape:
            @{ Source; Status; BestMatch; Candidates; Diagnostic }
        See the file-level docstring of each provider for details.

        Default priority list (most-trusted first):
            1. MusicBrainz   — peer-reviewed, the canonical source.
            2. CTDB          — community-submitted metadata that ships
                               alongside CUETools verification data;
                               often has releases MB doesn't.
        Configurable via cfg.MetadataProviders (string[]).

        Deferred for a later round (intentionally NOT v1 scope, see
        docs/DECISIONS.md): GnuDB, freedb, Discogs, fanart.tv.

    Result merging:
        Every provider's candidates are flattened into one list (each
        candidate carries .Source so the dialog can label its origin).
        When MULTIPLE providers return matches, an additional synthetic
        candidate with .Source = 'Merged (MB + CTDB)' is prepended:
        MB fields win on conflict; CTDB fills any nulls (track titles
        MB is missing, year, etc.). The synthetic candidate's
        ReleaseMbid comes from MB so cover-art lookup still works.

    Cover art:
        Pulled by the cover-art provider chain in
        src\core\coverart\ — see Get-CoverArt.ps1 for the orchestrator.
        Attached to BestMatch as .CoverArtBytes; failures yield $null
        rather than throwing (so a no-cover provider chain still lets
        the rip proceed).

    Logic split — pure parsers, ranking, and HTTP wrappers all live
    inside their respective provider files. Get-DiscMetadata.ps1 is
    the thin orchestrator only.

.NOTES
    Until 5.2, all metadata code lived in this file. The MB-specific
    pieces moved verbatim to
        src\core\metadata\Get-MetadataFromMusicBrainz.ps1
    and we re-dot-source them here so existing callers
    (Update-AlbumTags.ps1, Get-DiscMetadata.Tests.ps1) keep working
    without import-path churn.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

# Load all metadata providers. The orchestrator picks among them at
# runtime based on cfg.MetadataProviders.
. (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromMusicBrainz.ps1')
. (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromCuetoolsDb.ps1')
. (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromGnuDb.ps1')

# Cover-art chain orchestrator (CAA -> iTunes -> Deezer by default).
. (Join-Path $repoRoot 'src\core\coverart\Get-CoverArt.ps1')

function Get-RipperCoverArt {
<#
.SYNOPSIS
    Fetch the front cover image bytes for an MB release MBID, or $null.

.DESCRIPTION
    Cover Art Archive serves a 307 redirect to the underlying S3-hosted
    image. We grab the 1200px-bounded thumbnail rather than the
    unbounded `/front` original — see the .NOTES.

    Phase 5.2: this used to be the only cover-art source. It is now
    one of several, orchestrated by src\core\coverart\Get-CoverArt.ps1.
    The function stays here for back-compat with Update-AlbumTags.ps1
    (which only ever has a release MBID to work from).

.PARAMETER ReleaseMbid
    The release MBID to look up.

.EXAMPLE
    PS> $bytes = Get-RipperCoverArt -ReleaseMbid 'a1b2c3...'

.NOTES
    Returns $null on 404, throws on other failures.

    Why 1200px and not the original:
      - Plex / Picard / foobar2000 all render fine at 1200px.
      - Original CAA uploads are uncapped, often 3000x3000+ / 5+ MB.
        Embedding that in every track of a 12-track album adds ~60 MB
        of redundant pixels and breaks Windows Explorer's built-in
        FLAC tag handler (it drops Title/Album/Artist columns when
        the PICTURE block is too large).
      - 1200px JPEGs are typically 150-400 KB.
    https://wiki.musicbrainz.org/Cover_Art_Archive/API#Image_size
#>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [string]$ReleaseMbid
    )

    $url = "https://coverartarchive.org/release/$ReleaseMbid/front-1200"
    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 30 -UseBasicParsing | Out-Null
            return [System.IO.File]::ReadAllBytes($tmp)
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-RipperLog INFO 'Get-DiscMetadata' "No cover art at $url."
            return $null
        }
        throw
    }
}

function Get-RipperDiscMetadata {
<#
.SYNOPSIS
    Run the configured metadata-provider chain for a disc and return
    a normalized result.

.DESCRIPTION
    Orchestrator. Behavior:
      - Iterates cfg.MetadataProviders in order; calls each provider's
        Invoke-XxxMetadataProvider with the disc-id object.
      - Concatenates every provider's Candidates into one list (each
        candidate keeps its .Source).
      - When multiple providers returned hits, synthesizes a
        "Merged (MB + CTDB)" candidate (MB wins, CTDB fills nulls)
        and prepends it so the dialog defaults to it.
      - BestMatch = the first candidate in the merged list (or
        provider-chosen best when only one provider matched).
      - Status =
          'Match'      one or more providers returned a single match
          'MultiMatch' two or more candidates total
          'NoMatch'    every provider returned NoMatch
          'Offline'    every provider returned Offline / Error
      - Attempts cover-art for the chosen BestMatch via the cover-art
        provider chain (CoverArtArchive -> iTunes -> Deezer).

.PARAMETER DiscIdInfo
    Disc-id object from Get-RipperDiscId.

.PARAMETER PreferredCountry
    Optional 2-letter ISO country code to bias MB ranking.

.PARAMETER Providers
    Optional override of the configured provider list (string[]).
    Used by tests; production callers omit this and accept the
    config.json setting (default: @('MusicBrainz','CuetoolsDb')).

.EXAMPLE
    PS> $disc = Get-RipperDiscId
    PS> $meta = Get-RipperDiscMetadata -DiscIdInfo $disc
    PS> $meta.BestMatch.Album
    The Dark Side of the Moon

.NOTES
    Cover-art failures are non-fatal: the chosen BestMatch ends up
    with .CoverArtBytes = $null and the rip still proceeds.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$DiscIdInfo,

        [string]$PreferredCountry = 'US',

        [string[]]$Providers
    )

    # Resolve provider list: explicit override -> config -> default.
    if (-not $Providers) {
        Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
        try {
            $cfg = Import-RipperConfig
            if ($cfg.PSObject.Properties['MetadataProviders'] -and $cfg.MetadataProviders) {
                $Providers = @($cfg.MetadataProviders)
            }
        } catch {
            # Config load failure (e.g. tests with no config) -> defaults.
            Write-RipperLog WARN 'Get-DiscMetadata' "Config load failed; using default provider list. ($($_.Exception.Message))"
        }
        if (-not $Providers -or $Providers.Count -eq 0) {
            # Fallback when no config field is present (e.g. a config.json
            # written before Phase 5.2). Mirror the template default so a
            # missing key behaves the same as the documented out-of-the-box
            # config — otherwise pre-5.2 users silently lose CTDB / GnuDB.
            $Providers = @('MusicBrainz', 'CuetoolsDb', 'GnuDb')
        }
    }

    Write-RipperLog INFO 'Get-DiscMetadata' "Provider chain: $($Providers -join ', ')"

    # --- Run each provider --------------------------------------------------
    $providerResponses = foreach ($name in $Providers) {
        switch ($name) {
            'MusicBrainz' {
                Invoke-MusicBrainzMetadataProvider -DiscIdInfo $DiscIdInfo -PreferredCountry $PreferredCountry
            }
            'CuetoolsDb' {
                # Pull a UA out of config for the CTDB request. Falls back
                # to the provider's own default when config is unreadable.
                $ua = $null
                try {
                    Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
                    $cfgLocal = Import-RipperConfig
                    if ($cfgLocal.PSObject.Properties['MusicBrainzUserAgent'] -and $cfgLocal.MusicBrainzUserAgent) {
                        $ua = [string]$cfgLocal.MusicBrainzUserAgent
                    }
                } catch { }
                if ($ua) {
                    Invoke-CuetoolsDbMetadataProvider -DiscIdInfo $DiscIdInfo -UserAgent $ua
                } else {
                    Invoke-CuetoolsDbMetadataProvider -DiscIdInfo $DiscIdInfo
                }
            }
            'GnuDb' {
                # GnuDB reuses the same MB-shaped UA for its hello= field
                # (the email in the parens is what actually matters to GnuDB's
                # rate-limiter). Same cfg-lookup + fallback pattern as CTDB.
                $ua = $null
                try {
                    Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
                    $cfgLocal = Import-RipperConfig
                    if ($cfgLocal.PSObject.Properties['MusicBrainzUserAgent'] -and $cfgLocal.MusicBrainzUserAgent) {
                        $ua = [string]$cfgLocal.MusicBrainzUserAgent
                    }
                } catch { }
                if ($ua) {
                    Invoke-GnuDbMetadataProvider -DiscIdInfo $DiscIdInfo -UserAgent $ua
                } else {
                    Invoke-GnuDbMetadataProvider -DiscIdInfo $DiscIdInfo
                }
            }
            default {
                Write-RipperLog WARN 'Get-DiscMetadata' "Unknown provider '$name' in MetadataProviders list; skipping."
                $null
            }
        }
    }
    $providerResponses = @($providerResponses | Where-Object { $_ })

    # --- Aggregate ----------------------------------------------------------
    $allCandidates = @()
    foreach ($r in $providerResponses) {
        if ($r.Candidates) { $allCandidates += @($r.Candidates) }
    }

    if ($allCandidates.Count -eq 0) {
        # All providers said NoMatch / Offline. Pick the worst-case status
        # so the UI can decide whether to surface "no internet" vs
        # "nobody knows this disc".
        $anyOffline = $providerResponses | Where-Object { $_.Status -eq 'Offline' -or $_.Status -eq 'Error' }
        $finalStatus = if ($anyOffline -and $providerResponses.Count -eq @($anyOffline).Count) { 'Offline' } else { 'NoMatch' }
        Write-RipperLog INFO 'Get-DiscMetadata' "No candidates from any provider. Status=$finalStatus."
        return [pscustomobject]@{
            DiscId          = $DiscIdInfo.DiscId
            Status          = $finalStatus
            BestMatch       = $null
            Candidates      = @()
            ProviderResults = @($providerResponses)
        }
    }

    # When two or more providers contributed candidates, synthesize a
    # merged candidate. MB wins conflicts because it's the curated source;
    # CTDB fills any nulls. The merged form goes first so the dropdown
    # defaults to it.
    $contributing = @($providerResponses | Where-Object { $_.Candidates -and @($_.Candidates).Count -gt 0 })
    if ($contributing.Count -ge 2) {
        $merged = Merge-DiscMetadataCandidates -ProviderResults $contributing
        if ($merged) { $allCandidates = @($merged) + $allCandidates }
    }

    $best = $allCandidates[0]

    # Cover art for the chosen pick. Module-level helper so the call here
    # stays one line; ignore failures (return $null).
    try {
        $bytes = Get-RipperBestCoverArt -Candidate $best
        $best | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue $bytes -Force
    } catch {
        Write-RipperLog WARN 'Get-DiscMetadata' "Cover art lookup failed: $($_.Exception.Message)"
        $best | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue $null -Force
    }

    $finalStatus = if ($allCandidates.Count -gt 1) { 'MultiMatch' } else { 'Match' }
    Write-RipperLog INFO 'Get-DiscMetadata' `
        "Status=$finalStatus, $($allCandidates.Count) candidate(s); best='$($best.AlbumArtist) - $($best.Album)' (Source=$($best.Source))."

    [pscustomobject]@{
        DiscId          = $DiscIdInfo.DiscId
        Status          = $finalStatus
        BestMatch       = $best
        Candidates      = @($allCandidates)
        ProviderResults = @($providerResponses)
    }
}

function Merge-DiscMetadataCandidates {
<#
.SYNOPSIS
    Combine the best candidate from each provider into one synthesized
    "Merged" candidate (primary provider wins on conflict, others fill
    nulls).

.DESCRIPTION
    Pure helper. Walks ProviderResults in priority order (MB first by
    convention), takes each provider's BestMatch, and produces a new
    candidate where:
      - For every scalar field, the FIRST non-null value across the
        provider chain wins. So MB's release date beats CTDB's null
        year, but CTDB's year fills MB's null.
      - For Tracks[]: MB tracks win wherever the index has a title;
        CTDB titles fill MB nulls / shorter arrays.
      - The merged candidate inherits MB's ReleaseMbid (so cover-art
        lookup against CoverArtArchive still works).
      - .Source = "Merged (<P1> + <P2> + ...)" so the dropdown labels it.

.PARAMETER ProviderResults
    Array of provider responses (the orchestrator's $providerResponses).
    Only those with Candidates.Count > 0 are merged.

.EXAMPLE
    PS> $m = Merge-DiscMetadataCandidates -ProviderResults @($mbResp, $ctdbResp)
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject[]]$ProviderResults
    )

    $bestPerProvider = @($ProviderResults |
        Where-Object { $_.BestMatch } |
        ForEach-Object { $_.BestMatch })
    if ($bestPerProvider.Count -eq 0) { return $null }
    if ($bestPerProvider.Count -eq 1) { return $null }   # nothing to merge

    $primary = $bestPerProvider[0]
    $names   = ($bestPerProvider | ForEach-Object { $_.Source }) -join ' + '

    # Start from a shallow clone of the primary so all its fields, types,
    # and the .Tracks reference shape come along for free. Then fill nulls
    # from later providers.
    $merged = [ordered]@{}
    foreach ($p in $primary.PSObject.Properties) { $merged[$p.Name] = $p.Value }

    foreach ($cand in $bestPerProvider | Select-Object -Skip 1) {
        foreach ($p in $cand.PSObject.Properties) {
            $name = $p.Name
            if ($name -eq 'Source' -or $name -eq 'Tracks') { continue }
            $existing = $merged[$name]
            $isNull = ($null -eq $existing) -or
                      ($existing -is [string] -and [string]::IsNullOrWhiteSpace($existing)) -or
                      (($existing -is [System.Collections.IEnumerable]) -and
                       (-not ($existing -is [string])) -and
                       (@($existing).Count -eq 0))
            if ($isNull -and $null -ne $p.Value) {
                $merged[$name] = $p.Value
            }
        }

        # Track-level fill: where primary has nulls/shorter array, take
        # CTDB-side values.
        if ($cand.PSObject.Properties['Tracks'] -and $cand.Tracks) {
            $primTracks = @($merged['Tracks'])
            $secTracks  = @($cand.Tracks)
            $count      = [Math]::Max($primTracks.Count, $secTracks.Count)
            $newTracks  = for ($i = 0; $i -lt $count; $i++) {
                $a = if ($i -lt $primTracks.Count) { $primTracks[$i] } else { $null }
                $b = if ($i -lt $secTracks.Count)  { $secTracks[$i]  } else { $null }
                if (-not $a) { $b }
                elseif (-not $b) { $a }
                else {
                    $row = [ordered]@{}
                    foreach ($pp in $a.PSObject.Properties) { $row[$pp.Name] = $pp.Value }
                    foreach ($pp in $b.PSObject.Properties) {
                        $existing = $row[$pp.Name]
                        $isNull = ($null -eq $existing) -or
                                  ($existing -is [string] -and [string]::IsNullOrWhiteSpace($existing))
                        if ($isNull -and $null -ne $pp.Value) { $row[$pp.Name] = $pp.Value }
                    }
                    [pscustomobject]$row
                }
            }
            $merged['Tracks'] = @($newTracks)
        }
    }

    $merged['Source'] = "Merged ($names)"
    [pscustomobject]$merged
}

function Get-RipperBestCoverArt {
<#
.SYNOPSIS
    Run the cover-art provider chain for a chosen metadata candidate.

.DESCRIPTION
    Thin shim over Get-RipperCoverArtChain (in
    src/core/coverart/Get-CoverArt.ps1). Lives here so the metadata
    orchestrator can call cover art with a single line; tests can mock
    this name to skip the network entirely.

.PARAMETER Candidate
    The chosen candidate object.

.EXAMPLE
    PS> $bytes = Get-RipperBestCoverArt -Candidate $best
#>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)] [pscustomobject]$Candidate)

    Get-RipperCoverArtChain -Candidate $Candidate
}
