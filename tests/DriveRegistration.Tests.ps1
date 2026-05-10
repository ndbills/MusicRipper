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

Describe 'ConvertTo-RipperDriveNameKey (Phase 6.4.3)' {
    It 'lowercases and collapses every non-alphanumeric run to one space' {
        ConvertTo-RipperDriveNameKey -Name 'TSSTcorp DVD+-RW TS-H653H' |
            Should -Be 'tsstcorp dvd rw ts h653h'
    }
    It 'normalizes the AccurateRip-table form of the same drive identically' {
        # The whole point of the helper -- both Windows and AccurateRip
        # spellings of the same physical drive collapse to one key.
        $win = ConvertTo-RipperDriveNameKey -Name 'TSSTcorp DVD+-RW TS-H653H'
        $ar  = ConvertTo-RipperDriveNameKey -Name 'TSSTcorp - DVD+-RW TS-H653H'
        $win | Should -Be $ar
    }
    It 'collapses runs of whitespace to a single space' {
        ConvertTo-RipperDriveNameKey -Name 'PIONEER  BD-RW   BDR-209M' |
            Should -Be 'pioneer bd rw bdr 209m'
    }
    It 'returns empty for $null or whitespace-only input' {
        (ConvertTo-RipperDriveNameKey -Name $null) | Should -Be ''
        (ConvertTo-RipperDriveNameKey -Name '   ')  | Should -Be ''
    }
    It 'preserves embedded digits' {
        ConvertTo-RipperDriveNameKey -Name 'LITE-ON DVDRW SOHW-1693S' |
            Should -Be 'lite on dvdrw sohw 1693s'
    }
}

Describe 'Find-RipperAccurateRipOffset (Phase 6.4.3 normalization)' {

    BeforeAll {
        $script:tssCache = Join-Path $TestDrive 'driveoffsets.tsst.json'
        @{
            _comment       = 'Phase 6.4.3 regression fixture'
            _schemaVersion = 1
            drives = @(
                # AR's actual stored form for the parents-PC drive
                # (extra ' - ' separator after the vendor) -- this MUST
                # match the Windows form 'TSSTcorp DVD+-RW TS-H653H'.
                @{ match = 'TSSTcorp - DVD+-RW TS-H653H';  offset = 6 }
                # Two entries that share a prefix; the longer one must
                # win when the Windows name contains both.
                @{ match = 'PIONEER';                      offset = 999 }
                @{ match = 'PIONEER BD-RW BDR-209';        offset = 6   }
                # Ultra-short noise key the lookup must skip even
                # though it would substring into everything.
                @{ match = 'A';                            offset = 42  }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:tssCache
    }

    It 'matches the parents-PC TSSTcorp drive across the punctuation difference (regression)' {
        # Real-world miss reported by user: Windows says
        #   "TSSTcorp DVD+-RW TS-H653H"
        # but AR stores
        #   "TSSTcorp - DVD+-RW TS-H653H".
        # The pre-Phase-6.4.3 substring match returned $null for this
        # pair; the normalized key match returns the offset.
        $r = Find-RipperAccurateRipOffset `
                -DriveName 'TSSTcorp DVD+-RW TS-H653H' `
                -CachedListPath $script:tssCache `
                -SkipLive
        $r | Should -Be 6
    }

    It 'prefers the longest matching cache entry (most-specific wins)' {
        # Both 'PIONEER' (offset 999) and 'PIONEER BD-RW BDR-209'
        # (offset 6) substring into the Windows name. The longer
        # entry must win or a generic vendor row would shadow the
        # specific model.
        $r = Find-RipperAccurateRipOffset `
                -DriveName 'PIONEER BD-RW BDR-209M (1.41)' `
                -CachedListPath $script:tssCache `
                -SkipLive
        $r | Should -Be 6
    }

    It 'ignores ultra-short cache keys that would over-match (length < 4)' {
        # The 'A' fixture row is a stand-in for any ultra-short
        # noise that snuck into the cache; without the length guard
        # it would match every drive name with a letter A in it.
        $r = Find-RipperAccurateRipOffset `
                -DriveName 'no such known drive zzz' `
                -CachedListPath $script:tssCache `
                -SkipLive
        $r | Should -BeNullOrEmpty
    }
}
