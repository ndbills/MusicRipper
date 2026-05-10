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
            # Phase 6.4.5: realistic AR table forms -- full model strings,
            # matching what AccurateRip actually publishes. The matcher
            # uses token-aligned strict equality so prefix-only entries
            # like 'ASUS DRW-24' would no longer hit 'ASUS DRW-24F1ST'
            # (and that's correct -- AR doesn't store prefix stubs).
            @{ match = 'PIONEER BD-RW BDR-209M';   offset = 6 }
            @{ match = 'ASUS DRW-24F1ST';          offset = 6 }
            @{ match = 'LITE-ON DVDRW SOHW-1693S'; offset = 12 }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:fixtureCache
}

Describe 'Find-RipperAccurateRipOffset (cache only)' {
    It 'returns the offset for an exact token-aligned match' {
        $r = Find-RipperAccurateRipOffset -DriveName 'ASUS DRW-24F1ST' `
                                          -CachedListPath $script:fixtureCache `
                                          -SkipLive
        $r | Should -Be 6
    }

    It 'matches when AR tokens are a contiguous prefix of the Windows-reported name (e.g. trailing "ATA Device")' {
        # Win32_CDROMDrive.Name often appends 'ATA Device' / 'USB Device'
        # that AR doesn't include. Token-aligned matching lets the AR
        # entry's token sequence appear anywhere as a contiguous run
        # inside the drive token list.
        $r = Find-RipperAccurateRipOffset -DriveName 'PIONEER BD-RW BDR-209M ATA Device' `
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
<tr><td>ASUS DRW-24F1ST</td><td>42</td></tr>
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
            _comment       = 'Phase 6.4.3 + 6.4.5 regression fixture'
            _schemaVersion = 1
            drives = @(
                # AR's actual stored form for the parents-PC drive
                # (extra ' - ' separator after the vendor) -- this MUST
                # match the Windows form 'TSSTcorp DVD+-RW TS-H653H'.
                @{ match = 'TSSTcorp - DVD+-RW TS-H653H';  offset = 6 }
                # Vendor-only row + a full-model row that BOTH match a
                # Pioneer drive name; the most-specific (more tokens)
                # wins on tiebreak.
                @{ match = 'PIONEER';                      offset = 999 }
                @{ match = 'PIONEER BD-RW BDR-209M';       offset = 6   }
                # Ultra-short noise key. Under Phase 6.4.5 token-aligned
                # matching this can't accidentally match a real drive
                # because token equality is strict ('a' != 'asus').
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
        # pair; the normalized + token-aligned match returns the offset.
        $r = Find-RipperAccurateRipOffset `
                -DriveName 'TSSTcorp DVD+-RW TS-H653H' `
                -CachedListPath $script:tssCache `
                -SkipLive
        $r | Should -Be 6
    }

    It 'prefers the cache entry with more matching tokens (most-specific wins)' {
        # Both 'PIONEER' (1 token, offset 999) and 'PIONEER BD-RW BDR-209M'
        # (4 tokens, offset 6) match the drive's token sequence. The
        # longer (more-specific) entry must win or a generic vendor row
        # would shadow the specific model.
        $r = Find-RipperAccurateRipOffset `
                -DriveName 'PIONEER BD-RW BDR-209M ATA Device' `
                -CachedListPath $script:tssCache `
                -SkipLive
        $r | Should -Be 6
    }

    It 'rejects single-character noise keys (token equality is strict)' {
        # The 'A' fixture row would have substring-matched any drive
        # name with a letter A under the pre-Phase-6.4.5 rule. Token
        # equality requires 'a' to be one of the drive's whole tokens,
        # which it never is for vendor names like 'asus' / 'no' / etc.
        $r = Find-RipperAccurateRipOffset `
                -DriveName 'no such known drive zzz' `
                -CachedListPath $script:tssCache `
                -SkipLive
        $r | Should -BeNullOrEmpty
    }
}

Describe 'Find-RipperAccurateRipEntry (Phase 6.4.4 rich result)' {

    BeforeAll {
        $script:richCache = Join-Path $TestDrive 'driveoffsets.rich.json'
        @{
            _comment       = 'Phase 6.4.4 fixture (updated for 6.4.5 token matching)'
            _schemaVersion = 1
            drives = @(
                @{ match = 'TSSTcorp - DVD+-RW TS-H653H'; offset = 6 }
                @{ match = 'PIONEER';                     offset = 999 }
                @{ match = 'PIONEER BD-RW BDR-209M';      offset = 6 }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:richCache
    }

    It 'returns Offset + MatchedName + Source on a cache hit' {
        $r = Find-RipperAccurateRipEntry `
                -DriveName 'TSSTcorp DVD+-RW TS-H653H' `
                -CachedListPath $script:richCache `
                -SkipLive
        $r          | Should -Not -BeNullOrEmpty
        $r.Offset   | Should -Be 6
        # MatchedName must be the RAW AR-table form (preserves
        # contributor spelling) so log lines are useful for support.
        $r.MatchedName | Should -Be 'TSSTcorp - DVD+-RW TS-H653H'
        $r.Source   | Should -Be 'Cache'
    }

    It 'reports MatchedName for the most-specific winner, not the vendor-only entry' {
        $r = Find-RipperAccurateRipEntry `
                -DriveName 'PIONEER BD-RW BDR-209M ATA Device' `
                -CachedListPath $script:richCache `
                -SkipLive
        $r.Offset      | Should -Be 6
        $r.MatchedName | Should -Be 'PIONEER BD-RW BDR-209M'
    }

    It 'returns $null on a miss' {
        $r = Find-RipperAccurateRipEntry `
                -DriveName 'ACME 9000 (no such drive)' `
                -CachedListPath $script:richCache `
                -SkipLive
        $r | Should -BeNullOrEmpty
    }

    It 'tags Source=Live when the live page hits before falling through to cache' {
        $html = @'
<html><body><table>
<tr><td>SOMETHING-XYZ</td><td>99</td></tr>
<tr><td>ASUS DRW-24F1ST</td><td>42</td></tr>
</table></body></html>
'@
        Mock -ModuleName DriveRegistration Invoke-WebRequest {
            [pscustomobject]@{ Content = $html }
        }
        $r = Find-RipperAccurateRipEntry `
                -DriveName 'ASUS DRW-24F1ST' `
                -CachedListPath $script:richCache
        $r.Offset      | Should -Be 42
        $r.MatchedName | Should -Be 'ASUS DRW-24F1ST'
        $r.Source      | Should -Be 'Live'
    }
}

Describe 'Find-RipperAccurateRipEntry (Phase 6.4.5 token-aligned matching)' {

    BeforeAll {
        # Real-world AR-table shape that surfaced the bug: there are
        # TWO ASUS BW-12B1ST rows -- one for the actual drive ('ASUS -
        # BW-12B1ST') and one for a firmware variant ('ASUS - BW-12B1ST a').
        # Under the pre-6.4.5 raw-substring rule both matched the
        # Windows-reported 'ASUS BW-12B1ST ATA Device' (the variant's
        # trailing 'a' aligned with the leading 'a' in 'ata' purely by
        # accident), and longest-key-wins picked the variant. Token
        # equality rejects the variant cleanly because 'a' != 'ata'.
        $script:bwCache = Join-Path $TestDrive 'driveoffsets.bw.json'
        @{
            _comment       = 'Phase 6.4.5 BW-12B1ST regression fixture'
            _schemaVersion = 1
            drives = @(
                @{ match = 'ASUS - BW-12B1ST';   offset = 6 }
                @{ match = 'ASUS - BW-12B1ST a'; offset = 42 }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:bwCache
    }

    It 'picks the actual drive (BW-12B1ST), not the variant (BW-12B1ST a), for a real ASUS drive (regression)' {
        $r = Find-RipperAccurateRipEntry `
                -DriveName 'ASUS BW-12B1ST ATA Device' `
                -CachedListPath $script:bwCache `
                -SkipLive
        $r          | Should -Not -BeNullOrEmpty
        $r.Offset   | Should -Be 6
        $r.MatchedName | Should -Be 'ASUS - BW-12B1ST'
    }

    It 'still picks the variant when the variant entry is the actual drive (does not under-match)' {
        # If a parent owns the BW-12B1ST 'a' variant AND Windows happens
        # to report it that way (rare but possible firmware quirk), the
        # variant entry must still be matchable. Demonstrates the rule
        # is symmetric -- token equality both ways.
        $r = Find-RipperAccurateRipEntry `
                -DriveName 'ASUS BW-12B1ST a' `
                -CachedListPath $script:bwCache `
                -SkipLive
        $r          | Should -Not -BeNullOrEmpty
        $r.Offset   | Should -Be 42
        $r.MatchedName | Should -Be 'ASUS - BW-12B1ST a'
    }

    It 'rejects an AR entry whose extra trailing token does not appear in the drive name' {
        # Direct unit test of the token-alignment rule. The AR row
        # 'ASUS BW-12B1ST a' is 4 tokens; the drive is 4 tokens but
        # token 3 is 'foo', not 'a' -- no match.
        $script:misCache = Join-Path $TestDrive 'driveoffsets.mismatch.json'
        @{ _comment='mismatch fixture'; _schemaVersion=1; drives=@(
            @{ match='ASUS - BW-12B1ST a'; offset=42 }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:misCache
        $r = Find-RipperAccurateRipEntry `
                -DriveName 'ASUS BW-12B1ST foo' `
                -CachedListPath $script:misCache `
                -SkipLive
        $r | Should -BeNullOrEmpty
    }
}
