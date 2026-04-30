#Requires -Version 7.0
#Requires -Module Pester

<#
.SYNOPSIS
    Phase 6.6.E: pure-logic tests for src/lib/DriveRegistration.psm1.
#>

Set-StrictMode -Version 3.0

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\lib\DriveRegistration.psd1'
    Import-Module $modulePath -Force

    $script:fixtureCache = Join-Path $TestDrive 'driveoffsets.cached.json'
    @{
        _comment       = 'test fixture'
        _schemaVersion = 1
        drives = @(
            @{ match = 'PIONEER BD-RW   BDR-209'; offset = 6 }
            @{ match = 'ASUS DRW-24';              offset = 6 }
            @{ match = 'LITE-ON DVDRW SOHW-';      offset = 12 }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:fixtureCache
}

Describe 'Find-RipperAccurateRipOffset (cache only)' {
    It 'returns the offset for an exact substring match' {
        $r = Find-RipperAccurateRipOffset -DriveName 'ASUS DRW-24F1ST' `
                                          -CachedListPath $script:fixtureCache `
                                          -SkipLive
        $r | Should -Be 6
    }

    It 'matches against the longer Pioneer prefix' {
        $r = Find-RipperAccurateRipOffset -DriveName 'PIONEER BD-RW   BDR-209M (1.41)' `
                                          -CachedListPath $script:fixtureCache `
                                          -SkipLive
        $r | Should -Be 6
    }

    It 'returns $null when no entry matches' {
        $r = Find-RipperAccurateRipOffset -DriveName 'ACME 9000 (no such drive)' `
                                          -CachedListPath $script:fixtureCache `
                                          -SkipLive
        $r | Should -BeNullOrEmpty
    }

    It 'returns $null when the cache file is missing' {
        $r = Find-RipperAccurateRipOffset -DriveName 'ASUS DRW-24F1ST' `
                                          -CachedListPath (Join-Path $TestDrive 'no-such-cache.json') `
                                          -SkipLive
        $r | Should -BeNullOrEmpty
    }
}

Describe 'Find-RipperAccurateRipOffset (live + fallback)' {
    It 'falls back to cache when the live request throws' {
        Mock -ModuleName DriveRegistration Invoke-WebRequest { throw 'simulated dns failure' }
        $r = Find-RipperAccurateRipOffset -DriveName 'ASUS DRW-24F1ST' `
                                          -CachedListPath $script:fixtureCache
        $r | Should -Be 6
    }

    It 'parses the live AccurateRip table when reachable' {
        $html = @'
<html><body><table>
<tr><td>SOMETHING-XYZ</td><td>99</td></tr>
<tr><td>ASUS DRW-24</td><td>42</td></tr>
</table></body></html>
'@
        Mock -ModuleName DriveRegistration Invoke-WebRequest {
            [pscustomobject]@{ Content = $html }
        }
        $r = Find-RipperAccurateRipOffset -DriveName 'ASUS DRW-24F1ST' `
                                          -CachedListPath $script:fixtureCache
        $r | Should -Be 42
    }
}

Describe 'Get-RipperOpticalDrives' {
    It 'returns objects with Drive + Name properties (mocked CIM)' {
        Mock -ModuleName DriveRegistration Get-CimInstance {
            @(
                [pscustomobject]@{ Drive = 'E:'; Name = 'ASUS DRW-24F1ST' }
                [pscustomobject]@{ Drive = 'D:'; Name = 'PIONEER BD-RW BDR-209M' }
            )
        } -ParameterFilter { $ClassName -eq 'Win32_CDROMDrive' }

        $r = Get-RipperOpticalDrives
        $r.Count | Should -Be 2
        # Sorted by drive letter -> D: first.
        $r[0].Drive | Should -Be 'D:'
        $r[0].Name  | Should -Be 'PIONEER BD-RW BDR-209M'
        $r[1].Drive | Should -Be 'E:'
    }

    It 'returns an empty array when no drives are present' {
        Mock -ModuleName DriveRegistration Get-CimInstance { @() } `
            -ParameterFilter { $ClassName -eq 'Win32_CDROMDrive' }
        $r = @(Get-RipperOpticalDrives)
        $r.Count | Should -Be 0
    }
}
