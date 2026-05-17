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


Describe 'Find-RipperAccurateRipEntry (v0.3.0 -MatchPartialModel for manual lookup)' {

    BeforeAll {
        # Real-world fixture for the v0.3.0 manual-lookup feature: a
        # parent on a SATA-to-USB adapter types the bare drive model
        # ('UJ8E2') into the manual lookup textbox. The AR cache has
        # 'Panasonic UJ8E2' as the canonical entry plus firmware
        # variants.
        #
        # Without -MatchPartialModel the strict forward-direction
        # rule rejects bare-model input because entryTokens.Count >
        # driveTokens.Count, so the sliding-window check never
        # executes. The new switch enables reverse-direction matching
        # AND a tiered tiebreak: a 'suffix' match (drive tokens at the
        # end of entry tokens, i.e. the canonical 'vendor + model'
        # shape) beats a 'middle' match (firmware variants etc.).
        # Within suffix matches, shortest entry wins (least vendor
        # padding); within middle matches, longest entry wins
        # (most-specific).
        $script:panaCache = Join-Path $TestDrive 'driveoffsets.panasonic.json'
        @{
            _comment       = 'v0.3.0 manual-lookup reverse-match fixture'
            _schemaVersion = 1
            drives = @(
                @{ match = 'Panasonic UJ8E2';            offset = 6   }
                @{ match = 'Panasonic UJ8E2 firmware-v2'; offset = 102 }
                @{ match = 'Some other drive';            offset = 999 }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:panaCache
    }

    It 'finds the prefixed entry when the user types just the bare model (the reported bug)' {
        # User types 'UJ8E2'. Both 'Panasonic UJ8E2' and 'Panasonic
        # UJ8E2 firmware-v2' contain those tokens. The CANONICAL
        # 'Panasonic UJ8E2' wins because the typed tokens land at the
        # END of its tokens (contig-suffix tier 1) vs the MIDDLE of
        # the firmware-variant's tokens (contig-non-suffix tier 3).
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $script:panaCache `
                -SkipLive `
                -MatchPartialModel
        $r            | Should -Not -BeNullOrEmpty
        $r.Offset     | Should -Be 6
        $r.MatchedName | Should -Be 'Panasonic UJ8E2'
    }

    It 'WITHOUT -MatchPartialModel, bare-model input still misses (regression guard for auto-lookup behavior)' {
        # Auto-lookup callers (the standalone Look-up-offset button)
        # MUST keep the original strict-forward-only behavior so the
        # v6.4.5 firmware-variant disambiguation stays intact. This
        # test locks that in by asserting the same bare-model input
        # WITHOUT the switch returns $null.
        $r = Find-RipperAccurateRipEntry `
                -DriveName      'UJ8E2' `
                -CachedListPath $script:panaCache `
                -SkipLive
        $r | Should -BeNullOrEmpty
    }

    It 'still matches a normal Windows-reported name in forward direction with the switch on' {
        # Switch must NOT degrade the forward-direction match. A
        # Windows-reported 'PIONEER BD-RW BDR-209D ATA Device' should
        # still match the 'PIONEER BD-RW BDR-209D' AR entry whether
        # or not the partial-model switch is enabled. (Forward path
        # is tier 0 = highest priority; reverse tiers only fire when
        # forward fails.)
        $cache = Join-Path $TestDrive 'driveoffsets.pioneer.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='PIONEER BD-RW BDR-209D'; offset=667 }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'PIONEER BD-RW BDR-209D ATA Device' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r          | Should -Not -BeNullOrEmpty
        $r.Offset   | Should -Be 667
        $r.MatchedName | Should -Be 'PIONEER BD-RW BDR-209D'
    }

    It 'with -MatchPartialModel does NOT match unrelated entries that happen to share a token' {
        # Defensive: 'UJ8E2' must not silently match
        # 'Some other drive' just because that string contains
        # neither 'uj8e2' nor any of its tokens. (Sanity: the matcher
        # is doing token comparison, not character-level substring.)
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $script:panaCache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Not -Be 'Some other drive'
    }

    It 'matches the simple bare-model case (entry = vendor + model, input = model only)' {
        # Tightest possible reproduction of the original bug,
        # without the firmware-variant duplicate confusing the
        # tiebreak. Locks in the minimum viable behavior.
        $cache = Join-Path $TestDrive 'driveoffsets.simple.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic UJ8E2'; offset=6 }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r            | Should -Not -BeNullOrEmpty
        $r.Offset     | Should -Be 6
        $r.MatchedName | Should -Be 'Panasonic UJ8E2'
    }

    # ---- v0.3.0 tier-priority tests --------------------------------
    # The tiered tiebreak (forward > contig-suffix > subseq-suffix >
    # contig-non-suffix > subseq-non-suffix, shorter-wins within
    # suffix tiers, longer-wins within non-suffix tiers) is the
    # user-facing contract. These tests pin each tier transition
    # explicitly so a future refactor that loses one tier shows up
    # as a precise failure.

    It 'tier 1 (canonical contig suffix) beats tier 3 (firmware variant in middle)' {
        # The user's actual reported case: 'Panasonic UJ8E2'
        # (suffix) MUST beat 'Panasonic UJ8E2 firmware-v2' (middle)
        # regardless of length. The pre-refactor 'longest-wins' rule
        # got this backwards.
        $cache = Join-Path $TestDrive 'driveoffsets.suffix-vs-middle.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic UJ8E2';            offset=6   }
            @{ match='Panasonic UJ8E2 firmware-v2'; offset=102 }
            @{ match='Panasonic UJ8E2 firmware-v3'; offset=103 }
            @{ match='Panasonic UJ8E2 firmware-v4'; offset=104 }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Be 'Panasonic UJ8E2'
        $r.Offset      | Should -Be 6
    }

    It 'tier 1 shortest-contig-suffix-wins: minimum vendor padding wins' {
        # When two entries both end with the typed model (both tier 1),
        # the SHORTER entry wins -- it has the least vendor padding
        # and is therefore the canonical entry. Real-world example:
        # the AR table sometimes has both 'Panasonic UJ8E2' and
        # 'Panasonic Matshita UJ8E2' from different submitters; the
        # tighter one is more canonical.
        $cache = Join-Path $TestDrive 'driveoffsets.short-suffix.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic Matshita UJ8E2'; offset=10 }   # 3 tokens
            @{ match='Panasonic UJ8E2';           offset=6  }   # 2 tokens -> wins
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Be 'Panasonic UJ8E2'
        $r.Offset      | Should -Be 6
    }

    It 'tier 3 longest-contig-middle-wins when only middle matches exist (no suffix candidate)' {
        # When there's no suffix match, we fall into tier 3 and the
        # LONGEST entry wins (most-specific). This preserves the
        # original 'longer = more specific' intuition for the
        # non-canonical case.
        $cache = Join-Path $TestDrive 'driveoffsets.middle-only.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic UJ8E2 v1'; offset=11 }   # middle, 3 tokens
            @{ match='Panasonic UJ8E2 v2 special'; offset=22 }   # middle, 4 tokens -> wins
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Be 'Panasonic UJ8E2 v2 special'
        $r.Offset      | Should -Be 22
    }

    It 'tier 0 (forward) beats tier 1 (contig suffix) even when both are matchable' {
        # If the user types something rich enough to match a short
        # entry in the forward direction AND match a longer entry in
        # the reverse-suffix direction, forward wins (it's the
        # higher-confidence match -- the entry's tokens are a
        # contiguous substring of what the user typed).
        $cache = Join-Path $TestDrive 'driveoffsets.forward-beats-suffix.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='UJ8E2';           offset=50 }   # forward match (1 token == drive)
            @{ match='Panasonic UJ8E2'; offset=99 }   # would be reverse-suffix
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Be 'UJ8E2'
        $r.Offset      | Should -Be 50
    }

    It 'preserves v6.4.5 firmware-variant disambiguation in tier 0 (no regression of the original asymmetric rule)' {
        # The classic Windows-reported case that v6.4.5 fixed must
        # still work IDENTICALLY whether -MatchPartialModel is on or
        # off. Picks the actual drive ('ASUS - BW-12B1ST'), not the
        # 'a'-suffix variant. Pre-v0.3.0 this was a separate test; we
        # re-assert it here with the switch on so the new code path
        # can't reintroduce the bug via a tier-routing mistake.
        $cache = Join-Path $TestDrive 'driveoffsets.bw-with-switch.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='ASUS - BW-12B1ST';   offset=6  }
            @{ match='ASUS - BW-12B1ST a'; offset=42 }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'ASUS BW-12B1ST ATA Device' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Be 'ASUS - BW-12B1ST'
        $r.Offset      | Should -Be 6
    }

    # ---- v0.3.0 subsequence matching tests (tiers 2 + 4) -----------
    # Real-world AR entries embed descriptors between the vendor and
    # the model: 'Panasonic - DVD-RAM UJ8E2' rather than 'Panasonic
    # UJ8E2'. A parent typing 'panasonic UJ8E2' (vendor + model with
    # NO descriptor) used to miss every Panasonic entry because the
    # pre-subseq matcher required the typed tokens to be CONTIGUOUS
    # in the entry. Subsequence matching (in-order, gaps allowed)
    # closes that gap.

    It "matches 'panasonic UJ8E2' to 'Panasonic - DVD-RAM UJ8E2' via tier 2 (subseq suffix) -- the user's reported bug" {
        # User's actual AR-table fixture: typed input has vendor +
        # model with no descriptor, real entry has 'DVD-RAM'
        # descriptor between vendor and model. Without subseq matching
        # this returns $null and the parent ends up at the manual
        # offset field with no good way to discover the right value.
        $cache = Join-Path $TestDrive 'driveoffsets.uj8e2-real.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic - DVD-RAM UJ8E2 S'; offset=666 }
            @{ match='Panasonic - DVD-RAM UJ8E2';   offset=6   }
            @{ match='Panasonic - DVD-RAM UJ8E2Q';  offset=999 }
            @{ match='Panasonic - DVD-RAM UJ8E2S';  offset=888 }
            @{ match='HP UJ8E2';                    offset=42  }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'panasonic UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r            | Should -Not -BeNullOrEmpty
        # The bare 'Panasonic ... UJ8E2' entry wins (tier 2,
        # subseq-suffix). The trailing-S variant is tier 4
        # (subseq-non-suffix) and the Q / S inline variants don't
        # match at all (their final token is 'uj8e2q' / 'uj8e2s',
        # not 'uj8e2'). The HP entry doesn't match because its
        # tokens are ['hp','uj8e2'] -- 'panasonic' is missing.
        $r.MatchedName | Should -Be 'Panasonic - DVD-RAM UJ8E2'
        $r.Offset      | Should -Be 6
    }

    It "rejects 'panasonic - dvd-ram UJ8E2Q' for input 'panasonic UJ8E2' (model-number mismatch is NOT a subseq match)" {
        # Defensive: subseq matching is TOKEN-level, not character.
        # 'UJ8E2Q' normalizes to a single 'uj8e2q' token which is
        # NOT equal to 'uj8e2'. Without this guard, a future
        # refactor toward character-level matching would silently
        # pick the wrong drive family.
        $cache = Join-Path $TestDrive 'driveoffsets.uj8e2q-only.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic - DVD-RAM UJ8E2Q'; offset=999 }
            @{ match='Panasonic - DVD-RAM UJ8E2S'; offset=888 }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'panasonic UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r | Should -BeNullOrEmpty
    }

    It 'tier 2 (subseq suffix) beats tier 3 (contig non-suffix) -- canonical with descriptors beats firmware variant' {
        # Demonstrates the cross-tier priority that solves the user's
        # bug. The 'firmware-v2' entry is CONTIG (drive tokens
        # adjacent at positions 0-1) but non-suffix, so it's tier 3.
        # The 'DVD-RAM' entry has a gap between drive tokens but
        # ends with the typed model, so it's tier 2. Tier 2 wins.
        $cache = Join-Path $TestDrive 'driveoffsets.suffix-vs-middle.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic UJ8E2 firmware-v2'; offset=102 }   # contig non-suffix -> tier 3
            @{ match='Panasonic - DVD-RAM UJ8E2';   offset=6   }   # subseq suffix    -> tier 2
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'panasonic UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Be 'Panasonic - DVD-RAM UJ8E2'
        $r.Offset      | Should -Be 6
    }

    It 'tier 1 (contig suffix) beats tier 2 (subseq suffix) -- tighter match wins within suffix class' {
        # When the same input has both a bare-model and a
        # with-descriptor canonical entry available, the tighter
        # (contiguous) match wins. Bare-model input 'UJ8E2' against
        # both 'Panasonic UJ8E2' (contig suffix, tier 1) and
        # 'Panasonic DVD-RAM UJ8E2' (subseq suffix, tier 2).
        $cache = Join-Path $TestDrive 'driveoffsets.contig-vs-subseq.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic DVD-RAM UJ8E2'; offset=2 }   # tier 2
            @{ match='Panasonic UJ8E2';          offset=1 }   # tier 1 -> wins
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r.MatchedName | Should -Be 'Panasonic UJ8E2'
        $r.Offset      | Should -Be 1
    }

    It 'tier 4 (subseq non-suffix) matches as a fallback when no higher-tier candidate exists' {
        # Tier 4 fires only when the entry has the typed tokens with
        # gaps AND extras after them. Real-world: 'Panasonic - DVD-
        # RAM UJ8E2 S' for someone who typed bare 'panasonic UJ8E2'.
        # This test makes sure the fallback IS reachable when nothing
        # better exists (otherwise the manual-lookup feature would
        # under-match). Tiebreak: longer token-count wins (most-
        # specific variant).
        $cache = Join-Path $TestDrive 'driveoffsets.tier4-only.json'
        @{ _schemaVersion=1; drives=@(
            @{ match='Panasonic - DVD-RAM UJ8E2 S';           offset=20 }   # 5 tokens
            @{ match='Panasonic - DVD-RAM UJ8E2 S special';   offset=30 }   # 6 tokens -> wins
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName          'panasonic UJ8E2' `
                -CachedListPath     $cache `
                -SkipLive `
                -MatchPartialModel
        $r            | Should -Not -BeNullOrEmpty
        # Tier 4 tiebreak: longer wins (most-specific).
        $r.MatchedName | Should -Be 'Panasonic - DVD-RAM UJ8E2 S special'
        $r.Offset      | Should -Be 30
    }

    It 'auto-lookup path (no -MatchPartialModel) ignores subseq matches entirely (preserves Phase 6.4.5)' {
        # The subseq tiers (2 + 4) are reachable ONLY with the
        # switch on. Without it, a Windows-reported name that does
        # NOT contiguously contain an AR entry must return $null --
        # the v6.4.5 token-aligned strictness has to be preserved
        # for auto-lookup callers. If a future refactor accidentally
        # leaks the subseq path into the auto flow, this test fails.
        $cache = Join-Path $TestDrive 'driveoffsets.no-switch.json'
        @{ _schemaVersion=1; drives=@(
            # This entry would match in tier 2 IF the switch were on,
            # but the auto path must reject it.
            @{ match='Panasonic - DVD-RAM UJ8E2'; offset=6 }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cache
        $r = Find-RipperAccurateRipEntry `
                -DriveName      'panasonic UJ8E2' `
                -CachedListPath $cache `
                -SkipLive
        $r | Should -BeNullOrEmpty
    }
}
