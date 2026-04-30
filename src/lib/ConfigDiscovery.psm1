<#
.SYNOPSIS
    Discover the available sync targets / metadata providers / cover-
    art providers by scanning src/sync/ + src/core/metadata/ +
    src/core/coverart/ for the matching naming-convention files.
    Used by the Phase 6.6.B WPF config editor (and available to the
    CLI prompts) so adding a new provider/target is a drop-in -- no
    menu list to edit.

.DESCRIPTION
    Naming conventions enforced by Phase 5.2 / 6.1+:
      * Metadata     : files `src\core\metadata\Get-MetadataFrom<Name>.ps1`.
      * Cover-art    : files `src\core\coverart\Get-CoverArtFrom<Name>.ps1`.
      * Sync target  : function `Invoke-RipperSyncTo<Name>` defined
                       somewhere under src\sync\. (The built-in 'Stub'
                       lives in Invoke-RipperSync.ps1, not its own file,
                       so filename-only discovery would miss it -- we
                       grep for the function declaration instead.)

    Sync-target discovery regex-greps .ps1 files rather than dot-
    sourcing them (cheaper, no side effects, no module-load order
    headaches in the WPF editor's runspace).

.NOTES
    -RepoRoot defaults to two levels up from this file (src\lib\ ->
    repo). Override for unit tests.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-RipperRepoRoot {
    # Walk up from this module file: src/lib/ConfigDiscovery.psm1 -> src -> repo.
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Find-RipperFunctionNames {
<#
.SYNOPSIS
    Internal: scan a folder for `function <Prefix><Name> {` definitions
    and return the unique sorted set of <Name> values.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string]$Folder,
        [Parameter(Mandatory)] [string]$Prefix
    )
    if (-not (Test-Path -LiteralPath $Folder)) { return @() }
    $files = Get-ChildItem -LiteralPath $Folder -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue
    if (-not $files) { return @() }
    # Match only function declarations at start-of-line so we don't
    # pick up comment/doc references like ".Invoke-RipperSyncTo<Name>".
    $pattern = '(?m)^\s*function\s+' + [regex]::Escape($Prefix) + '(?<name>[A-Za-z0-9_]+)\b'
    $names = @{}
    foreach ($f in $files) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $n = $m.Groups['name'].Value
            if ($n) { $names[$n] = $true }
        }
    }
    return @($names.Keys | Sort-Object)
}

function Find-RipperFileNameSuffixes {
<#
.SYNOPSIS
    Internal: list .ps1 files in a folder whose base name starts with
    the given prefix; return the suffix (everything after the prefix)
    for each, sorted unique.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string]$Folder,
        [Parameter(Mandatory)] [string]$Prefix
    )
    if (-not (Test-Path -LiteralPath $Folder)) { return @() }
    $files = Get-ChildItem -LiteralPath $Folder -Filter ($Prefix + '*.ps1') -File -ErrorAction SilentlyContinue
    if (-not $files) { return @() }
    $names = @{}
    foreach ($f in $files) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($base.Length -gt $Prefix.Length) {
            $names[$base.Substring($Prefix.Length)] = $true
        }
    }
    return @($names.Keys | Sort-Object)
}

# Canonical-casing fixups for provider names whose filename casing
# diverges from the dispatcher's switch labels (and from the names
# stored in cfg.MetadataProviders / cfg.CoverArtProviders). The
# filename `Get-CoverArtFromItunesSearch.ps1` discovers as
# 'ItunesSearch' but cfg + the switch case use 'iTunesSearch'. Keep
# this list short -- ideally future providers use a casing that
# survives the round-trip and never need an entry here.
$script:RipperProviderCanonicalNames = @{
    'itunessearch' = 'iTunesSearch'
}

function ConvertTo-RipperCanonicalProviderName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$Name)
    $key = $Name.ToLowerInvariant()
    if ($script:RipperProviderCanonicalNames.ContainsKey($key)) {
        return $script:RipperProviderCanonicalNames[$key]
    }
    return $Name
}

function Get-RipperAvailableSyncTargets {
<#
.SYNOPSIS
    Return the sorted list of sync target names available in this
    checkout (anything with an `Invoke-RipperSyncTo<Name>` function
    under src/sync/). The built-in 'Stub' target is included because
    its function lives in Invoke-RipperSync.ps1.

.PARAMETER RepoRoot
    Override the repo root. Defaults to the parent-of-src directory
    of this module.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-RipperRepoRoot }
    Find-RipperFunctionNames -Folder (Join-Path $RepoRoot 'src\sync') -Prefix 'Invoke-RipperSyncTo'
}

function Get-RipperAvailableMetadataProviders {
<#
.SYNOPSIS
    Return the sorted list of metadata provider names available
    (one per `Get-MetadataFrom<Name>.ps1` file under
    src/core/metadata/). The dispatcher's switch statement maps
    these names back to the provider's `Invoke-<Name>MetadataProvider`
    function, but the canonical "is this provider available?" check
    is whether the filename exists.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-RipperRepoRoot }
    $raw = Find-RipperFileNameSuffixes -Folder (Join-Path $RepoRoot 'src\core\metadata') -Prefix 'Get-MetadataFrom'
    return @($raw | ForEach-Object { ConvertTo-RipperCanonicalProviderName $_ } | Sort-Object -Unique)
}

function Get-RipperAvailableCoverArtProviders {
<#
.SYNOPSIS
    Return the sorted list of cover-art provider names available
    (one per `Get-CoverArtFrom<Name>.ps1` file under
    src/core/coverart/).
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-RipperRepoRoot }
    $raw = Find-RipperFileNameSuffixes -Folder (Join-Path $RepoRoot 'src\core\coverart') -Prefix 'Get-CoverArtFrom'
    return @($raw | ForEach-Object { ConvertTo-RipperCanonicalProviderName $_ } | Sort-Object -Unique)
}

Export-ModuleMember -Function `
    Get-RipperAvailableSyncTargets, `
    Get-RipperAvailableMetadataProviders, `
    Get-RipperAvailableCoverArtProviders
