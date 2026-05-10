<#
.SYNOPSIS
    Phase 6.6.E: pure-logic helpers shared between setup/Register-Drive.ps1
    and the new in-app "Register drive..." button on the config dialog's
    General tab.

.DESCRIPTION
    Two responsibilities, both side-effect-free except for the network call
    in Find-RipperAccurateRipOffset:

      Get-RipperOpticalDrives
        Enumerates Win32_CDROMDrive and returns a normalized array of
        @{ Drive='D:'; Name='PIONEER BD-RW BDR-209M' }. Sorted by drive
        letter for stable UI ordering.

      Find-RipperAccurateRipOffset
        Looks up the AccurateRip read offset (in samples) for a drive by
        substring-matching the Win32_CDROMDrive.Name field. Tries the live
        page first; on any failure (network, page format change) falls back
        to the bundled cache. Returns [int] on hit, $null on miss.

    Used by:
      - setup/Register-Drive.ps1                 (CLI flow)
      - src/ui/Show-RegisterDriveDialog.ps1      (WPF flow, runs the network
                                                  call in a worker runspace
                                                  so the UI stays responsive)
#>

Set-StrictMode -Version 3.0

function ConvertTo-RipperDriveNameKey {
<#
.SYNOPSIS
    Normalize a drive vendor/model string to a canonical, punctuation-
    insensitive key for AccurateRip lookup matching.

.DESCRIPTION
    AccurateRip's published list and Win32_CDROMDrive don't always agree
    on spacing or punctuation for the same physical drive -- AR entries
    are crowdsourced and contributors have used several formats. Real
    example: Windows reports "TSSTcorp DVD+-RW TS-H653H" but the same
    drive lives in AccurateRip's table as "TSSTcorp - DVD+-RW TS-H653H"
    (extra ' - ' separator after the vendor name). The pre-Phase-6.4.3
    literal substring check (-like "*$name*") missed every pair like
    that, even though the underlying drive was registered.

    Normalization rules:
      1. Lowercase (case-insensitive equality is what AR's table
         intends -- vendor casing varies row-to-row).
      2. Replace any run of non-alphanumeric characters with a single
         space (collapses '+', '-', '/', '(' ')', '.', tabs, multiple
         spaces, etc. -- the punctuation IS the inconsistency).
      3. Trim leading/trailing whitespace.

    Both example strings above normalize to "tsstcorp dvd rw ts h653h"
    -- a substring check on the normalized forms now matches.

.PARAMETER Name
    The raw vendor/model string from Win32_CDROMDrive.Name or one of
    AccurateRip's table cells. May be $null or empty (returns '').
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $lower = $Name.ToLowerInvariant()
    # Collapse any run of non-alphanumerics to a single space, then trim.
    return ([regex]::Replace($lower, '[^a-z0-9]+', ' ')).Trim()
}

function Get-RipperOpticalDrives {
<#
.SYNOPSIS
    Return all optical drives on this machine as an array of objects with
    Drive (e.g. 'D:') and Name (vendor + model) properties.
.DESCRIPTION
    Thin wrapper around Get-CimInstance Win32_CDROMDrive. Sorted by Drive
    so UI listings are stable across runs. Always returns an array
    (possibly empty).
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $rows = @(Get-CimInstance -ClassName Win32_CDROMDrive |
              Sort-Object Drive |
              ForEach-Object {
                  [pscustomobject]@{
                      Drive = [string]$_.Drive
                      Name  = [string]$_.Name
                  }
              })
    return $rows
}

function Find-RipperAccurateRipOffset {
<#
.SYNOPSIS
    Return the AccurateRip read offset (in samples) for a drive name, or
    $null if no match in either the live page or the cache.

.PARAMETER DriveName
    The Win32_CDROMDrive.Name string (vendor + model).

.PARAMETER CachedListPath
    Absolute path to data/driveoffsets.cached.json.

.PARAMETER TimeoutSec
    HTTP timeout for the live AccurateRip page request. Default 10s.

.PARAMETER SkipLive
    If set, bypass the live AccurateRip page and go straight to the cache.
    Tests use this to avoid network access; the UI passes it after the
    user has already tried once and we want a fast retry.
#>
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param(
        [Parameter(Mandatory)] [string]$DriveName,
        [Parameter(Mandatory)] [string]$CachedListPath,
        [int]$TimeoutSec = 10,
        [switch]$SkipLive
    )

    # Phase 6.4.3: normalize both sides before matching so we tolerate
    # the spacing/punctuation differences between Windows' Win32_CDROMDrive
    # and the crowdsourced AccurateRip entries (e.g. real-world miss
    # documented in the comment block on ConvertTo-RipperDriveNameKey).
    # Among multiple matches we pick the LONGEST normalized AR key,
    # which prefers the most specific entry (e.g. "ASUS DRW-24F1ST"
    # beats a generic "ASUS DRW" if both are present).
    $driveKey = ConvertTo-RipperDriveNameKey -Name $DriveName
    if ([string]::IsNullOrWhiteSpace($driveKey)) { return $null }

    # Local helper: scan a sequence of @{ Name; Offset } candidates,
    # return the offset whose normalized name is the longest substring
    # of $driveKey, or $null if none match.
    $bestMatch = {
        param([object[]]$Candidates)
        $bestKeyLen = -1
        $bestOffset = $null
        foreach ($c in $Candidates) {
            $entryKey = ConvertTo-RipperDriveNameKey -Name $c.Name
            # Skip empties and ultra-short keys; the latter can over-
            # match (e.g. a 3-char vendor token would substring into
            # everything). 4 chars matches the install-time scraper's
            # row-sanity threshold.
            if ($entryKey.Length -lt 4) { continue }
            if ($driveKey.Contains($entryKey) -and $entryKey.Length -gt $bestKeyLen) {
                $bestKeyLen = $entryKey.Length
                $bestOffset = [int]$c.Offset
            }
        }
        return $bestOffset
    }

    if (-not $SkipLive) {
        try {
            $resp = Invoke-WebRequest -Uri 'http://www.accuraterip.com/driveoffsets.htm' `
                                      -TimeoutSec $TimeoutSec -UseBasicParsing
            # The AccurateRip page wraps every cell in a
            # <font face="Arial" size="2"> tag and bullet-prefixes
            # drive names with '- '. setup/Install-DriveOffsetCache.ps1
            # uses the same pattern when seeding the cache.
            $rowPattern = '<td[^>]*>\s*(?:<font[^>]*>)?\s*(?<name>[^<]+?)\s*(?:</font>)?\s*</td>\s*' +
                          '<td[^>]*>\s*(?:<font[^>]*>)?\s*(?<off>[+\-]?\d+)\s*(?:</font>)?\s*</td>'
            $rows = [regex]::Matches($resp.Content, $rowPattern, 'IgnoreCase')
            $liveCandidates = foreach ($m in $rows) {
                $name = $m.Groups['name'].Value.Trim()
                if ($name -match '^\s*-\s+(.*)$') { $name = $Matches[1].Trim() }
                [pscustomobject]@{ Name = $name; Offset = [int]$m.Groups['off'].Value }
            }
            $liveHit = & $bestMatch -Candidates @($liveCandidates)
            if ($null -ne $liveHit) { return $liveHit }
        } catch {
            # Fall through to cache on any failure (network blip,
            # page reformat, DNS, etc.). Caller decides how loud.
        }
    }

    if (-not (Test-Path -LiteralPath $CachedListPath)) {
        return $null
    }
    $cache = Get-Content -LiteralPath $CachedListPath -Raw | ConvertFrom-Json
    $cacheCandidates = foreach ($entry in $cache.drives) {
        [pscustomobject]@{ Name = [string]$entry.match; Offset = [int]$entry.offset }
    }
    return (& $bestMatch -Candidates @($cacheCandidates))
}

Export-ModuleMember -Function Get-RipperOpticalDrives, Find-RipperAccurateRipOffset, ConvertTo-RipperDriveNameKey
