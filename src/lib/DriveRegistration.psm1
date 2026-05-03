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
            foreach ($m in $rows) {
                $name = $m.Groups['name'].Value.Trim()
                if ($name -match '^\s*-\s+(.*)$') { $name = $Matches[1].Trim() }
                if ($DriveName -like "*$name*") {
                    return [int]$m.Groups['off'].Value
                }
            }
        } catch {
            # Fall through to cache on any failure (network blip,
            # page reformat, DNS, etc.). Caller decides how loud.
        }
    }

    if (-not (Test-Path -LiteralPath $CachedListPath)) {
        return $null
    }
    $cache = Get-Content -LiteralPath $CachedListPath -Raw | ConvertFrom-Json
    foreach ($entry in $cache.drives) {
        if ($DriveName -like "*$($entry.match)*") {
            return [int]$entry.offset
        }
    }
    return $null
}

Export-ModuleMember -Function Get-RipperOpticalDrives, Find-RipperAccurateRipOffset
