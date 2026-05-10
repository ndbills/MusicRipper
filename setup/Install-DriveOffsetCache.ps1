<#
.SYNOPSIS
    One-time install-time fetch of the AccurateRip drive-offset list.

.DESCRIPTION
    Pipeline position:
        Chained from Install-MusicRipper.ps1 between the dependency
        install and the shortcut install. Idempotent: if the cache
        file already exists and -Force isn't set, leaves it alone
        (so a re-run of Install-MusicRipper doesn't re-fetch).

    What this script does:
        Downloads the live AccurateRip drive-offset page at
        https://accuraterip.com/driveoffsets.htm, parses out
        <td>vendor model</td><td>offset</td> rows, and writes them
        as `data/driveoffsets.cached.json` next to this repo's
        existing schema (drives[].match + drives[].offset).

    Why this script exists:
        The AccurateRip drive-offset list is proprietary
        (c) Illustrate / Spoon. We are NOT permitted to redistribute
        it. Pre-Phase-C we shipped a stale cached copy in-tree;
        Phase C removed it. The runtime fallback path
        (`src/lib/DriveRegistration.psm1::Find-RipperAccurateRipOffset`)
        scrapes the live page anyway -- this script just primes the
        cache so the very first disc registration after install has
        a fast offline fallback.

.PARAMETER Force
    Re-fetch even if the cache file already exists. Not exposed
    via Install-MusicRipper.ps1; tests and manual runs use it.

.PARAMETER TimeoutSec
    HTTP timeout for the live page fetch. Default 30s.

.NOTES
    Internet access is required at install time. If the fetch
    fails (no internet, AccurateRip down, page reformat, etc.)
    we WARN and exit 0; the runtime path still works (it will
    just hit the live page on first disc registration). We do
    NOT fail the installer over this.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [int]$TimeoutSec = 30
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

$cachePath = Join-Path $repoRoot 'data\driveoffsets.cached.json'
$dataDir   = Split-Path -Parent $cachePath
if (-not (Test-Path -LiteralPath $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

if ((Test-Path -LiteralPath $cachePath) -and -not $Force) {
    Write-Host "[ok] AccurateRip offset cache already present; leaving as-is." -ForegroundColor DarkGreen
    Write-Host "     ($cachePath)" -ForegroundColor DarkGray
    Write-Host '     Pass -Force to re-fetch.' -ForegroundColor DarkGray
    return
}

if (-not $PSCmdlet.ShouldProcess($cachePath, 'Write AccurateRip offset cache from live page')) {
    return
}

$liveUrl = 'http://www.accuraterip.com/driveoffsets.htm'
Write-Host "[..] Fetching AccurateRip offset list from $liveUrl ..." -ForegroundColor Cyan

try {
    $resp = Invoke-WebRequest -Uri $liveUrl -TimeoutSec $TimeoutSec -UseBasicParsing
} catch {
    Write-Warning ("Could not fetch the AccurateRip offset list: " +
                   "$($_.Exception.Message). The runtime fallback path will still " +
                   "scrape the live page on first disc registration; this just " +
                   "means there's no offline cache yet. Continuing.")
    return
}

# Same regex shape Find-RipperAccurateRipOffset uses at runtime; the
# AccurateRip page wraps every cell in a <font face="Arial" size="2">
# tag, and drive names are bullet-prefixed with '- '. We capture the
# raw text and normalize below.
$rowPattern = '<td[^>]*>\s*(?:<font[^>]*>)?\s*(?<name>[^<]+?)\s*(?:</font>)?\s*</td>\s*' +
              '<td[^>]*>\s*(?:<font[^>]*>)?\s*(?<off>[+\-]?\d+)\s*(?:</font>)?\s*</td>'
$rowMatches = [regex]::Matches($resp.Content, $rowPattern, 'IgnoreCase')

if ($rowMatches.Count -eq 0) {
    Write-Warning ("Fetched the AccurateRip page but parsed 0 drive rows -- " +
                   "the page format may have changed. Leaving any existing cache " +
                   "in place. Continuing.")
    return
}

$drives = foreach ($m in $rowMatches) {
    $name = $m.Groups['name'].Value.Trim()
    # Strip the leading '- ' bullet prefix the page uses on every row.
    if ($name -match '^\s*-\s+(.*)$') { $name = $Matches[1].Trim() }
    # Drive-row sanity: skip obvious non-drive table noise (very short
    # tokens, pure numbers, etc.) so the cache stays small enough to
    # ConvertTo-Json without blowing up.
    if ($name.Length -lt 4) { continue }
    if ($name -match '^[+\-]?\d+$') { continue }
    [pscustomobject]@{
        match  = $name
        offset = [int]$m.Groups['off'].Value   # [int] eats a leading '+'
    }
}
$drives = @($drives)

# Match the existing on-disk schema -- DO NOT change field names without
# updating Find-RipperAccurateRipOffset to match.
$payload = [pscustomobject]@{
    '_comment'       = 'Cached fallback list of common optical drive AccurateRip read offsets. Used by setup/Register-Drive.ps1 (and src/ui/Show-RegisterDriveDialog.ps1) when the AccurateRip database is unreachable. Source: http://www.accuraterip.com/driveoffsets.htm. Phase 6.4.5 match rule: each name is normalized (lowercase + non-alphanumeric runs collapsed to one space) and split into tokens; an entry matches a Win32_CDROMDrive.Name when the entry tokens appear as a contiguous subsequence with strict per-token equality (most-specific entry wins on tie). Offsets are in samples; positive means the drive reads ahead.'
    '_schemaVersion' = 1
    '_fetchedFrom'   = $liveUrl
    '_fetchedAt'     = (Get-Date).ToUniversalTime().ToString('o')
    'drives'         = @($drives)
}

$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath -Encoding UTF8
Write-Host "[ok] Wrote $($drives.Count) drive entries to $cachePath" -ForegroundColor Green
