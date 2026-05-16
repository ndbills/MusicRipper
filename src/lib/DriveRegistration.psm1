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
    Drive (e.g. 'D:'), Name (vendor + model), and FirmwareRevision
    properties.
.DESCRIPTION
    Thin wrapper around Get-CimInstance Win32_CDROMDrive. Sorted by Drive
    so UI listings are stable across runs. Always returns an array
    (possibly empty).

    Phase 6.4.6: FirmwareRevision was added so the rip log captures
    enough drive identity to triangulate hardware-specific issues
    (e.g. the TS-H653H "ILLEGAL MODE FOR THIS TRACK" failure surfaces
    on some firmware revisions but not others). Always [string]; '' when
    Win32 doesn't expose it.
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $rows = @(Get-CimInstance -ClassName Win32_CDROMDrive |
              Sort-Object Drive |
              ForEach-Object {
                  $fw = ''
                  if ($_.PSObject.Properties['FirmwareRevision'] -and $_.FirmwareRevision) {
                      $fw = [string]$_.FirmwareRevision
                  }
                  [pscustomobject]@{
                      Drive            = [string]$_.Drive
                      Name             = [string]$_.Name
                      FirmwareRevision = $fw
                  }
              })
    return $rows
}

function Find-RipperAccurateRipEntry {
<#
.SYNOPSIS
    Look up a drive in the AccurateRip table; return @{ Offset; MatchedName;
    Source } on hit, $null on miss. The detail-rich form of
    Find-RipperAccurateRipOffset (which delegates here for the int
    return path).

.DESCRIPTION
    Same lookup semantics as Find-RipperAccurateRipOffset (normalize +
    longest-match across live page and bundled cache). The richer
    return surface lets callers log WHICH AccurateRip row matched the
    Win32_CDROMDrive name -- useful for the install-time drive
    registration log entry, where seeing the AR-side spelling is the
    fastest way to confirm the right physical drive was identified.

    Result keys:
      Offset      -- [int] sample offset.
      MatchedName -- [string] the raw AR-table name (before normalization)
                     so the log line shows the contributor's original
                     spelling, e.g. "TSSTcorp - DVD+-RW TS-H653H".
      Source      -- 'Live' or 'Cache' depending on which provider hit.

.PARAMETER DriveName
    Win32_CDROMDrive.Name (vendor + model).

.PARAMETER CachedListPath
    Absolute path to data/driveoffsets.cached.json.

.PARAMETER TimeoutSec
    HTTP timeout for the live AccurateRip page request. Default 10s.

.PARAMETER SkipLive
    If set, skip the live page and use only the bundled cache (tests
    + fast-retry path).

.PARAMETER MatchPartialModel
    v0.3.0: also accept matches where the input is SHORTER than the
    AccurateRip entry (e.g. user typed bare 'UJ8E2'; entry is
    'Panasonic UJ8E2'). The original strict rule -- entry tokens must
    be a contiguous subsequence of drive tokens -- was correct for
    auto-lookup against Windows-reported names which are always
    richer than AR entries ('ASUS BW-12B1ST ATA Device' vs 'ASUS
    BW-12B1ST'). The new manual-lookup WPF field inverts that
    relationship, so the WPF passes this switch.

    With the switch on, the matcher runs a tiered tiebreak:
      - Tier 0 (forward, entry tokens in drive tokens): preserves
        the v6.4.5 firmware-variant disambiguation -- longest entry
        wins. Auto-lookup callers stay here.
      - Tier 1 (reverse-suffix, drive tokens at END of entry tokens):
        the canonical 'vendor + model' shape -- shortest entry wins
        (least vendor padding).
      - Tier 2 (reverse-non-suffix, drive tokens elsewhere in entry
        tokens): a less-canonical match like 'Panasonic UJ8E2
        firmware-v2' -- longest entry wins (most-specific).

    Tiers 1 + 2 are reachable only with this switch on. Lower tier
    always beats higher tier; ties broken within tier as above.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$DriveName,
        [Parameter(Mandatory)] [string]$CachedListPath,
        [int]$TimeoutSec = 10,
        [switch]$SkipLive,
        [switch]$MatchPartialModel
    )

    # Phase 6.4.3: normalize both sides before matching so we tolerate
    # the spacing/punctuation differences between Windows' Win32_CDROMDrive
    # and the crowdsourced AccurateRip entries (real-world miss with the
    # TSSTcorp drive on the parents-PC install).
    #
    # Phase 6.4.5: token-aligned strict equality (was raw-substring +
    # longest-key tiebreak). The earlier rule had a real-world false
    # positive: Windows reports 'ASUS BW-12B1ST ATA Device', AR has
    # both 'ASUS - BW-12B1ST' (the actual drive) and 'ASUS - BW-12B1ST a'
    # (a firmware variant). After normalization both are substrings of
    # the Windows key, AND the variant's normalized key is longer
    # ('asus bw 12b1st a' vs 'asus bw 12b1st') because the trailing 'a'
    # incidentally aligns with the 'a' in 'ata'. Character-level
    # matching has no notion of word boundaries, so longest-wins picked
    # the wrong row.
    #
    # New rule: split each normalized key on whitespace into tokens,
    # then match only if the AR token list appears as a CONTIGUOUS
    # SUBSEQUENCE of the drive token list with strict per-token
    # equality. Tiebreak by token count (most-specific wins). The
    # 'asus bw 12b1st a' variant is now rejected because the drive's
    # 4th token is 'ata', not 'a'.
    $driveKey = ConvertTo-RipperDriveNameKey -Name $DriveName
    if ([string]::IsNullOrWhiteSpace($driveKey)) { return $null }
    $driveTokens = $driveKey.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($driveTokens.Count -eq 0) { return $null }

    # Local helper: scan a sequence of @{ Name; Offset } candidates,
    # return @{ Offset; MatchedName } for the best-scoring candidate, or
    # $null if none match.
    #
    # v0.3.0 scoring tiers (LOWER tier wins; ties broken by 2nd value
    # LOWER-wins). Real-world AR data has both canonical entries and
    # firmware variants for the same drive, AND entries often have
    # generic descriptors between vendor and model ('Panasonic - DVD-RAM
    # UJ8E2'). A parent typing a bare model ('UJ8E2') OR a vendor +
    # model ('panasonic UJ8E2') wants the most canonical entry --
    # the bare drive name, then the bare-with-descriptors entry, then
    # firmware variants -- regardless of how long the entry is.
    #
    #   Tier 0 (forward contig, entry tokens contiguous in drive tokens):
    #     The classic auto-lookup case. Windows-reported drive names
    #     are always richer than AR entries; longer entry = more
    #     specific = correct (v6.4.5 firmware-variant disambiguation).
    #     Tiebreak: -entryTokens.Count (longer wins).
    #
    #   Tier 1 (reverse contig suffix, drive tokens contiguous at END
    #     of entry tokens): the canonical manual-lookup case where the
    #     user typed the bare model. Shorter entry = least vendor
    #     padding = canonical. Tiebreak: +entryTokens.Count (shorter
    #     wins).
    #
    #   Tier 2 (reverse subsequence suffix, drive tokens appear in
    #     order with gaps in entry, last drive token at last entry
    #     position): the 'vendor + descriptors + model' case
    #     ('panasonic UJ8E2' -> 'Panasonic - DVD-RAM UJ8E2'). Same
    #     intent as Tier 1, just looser; goes after Tier 1 so a tight
    #     canonical match always beats one with descriptor gaps.
    #     Tiebreak: +entryTokens.Count (shorter wins).
    #
    #   Tier 3 (reverse contig non-suffix, drive tokens contiguous
    #     somewhere in entry but not at the end): the firmware-variant
    #     case of Tier 1 ('Panasonic UJ8E2 firmware-v2' when user
    #     typed 'UJ8E2'). Longer entry = more-specific variant.
    #     Tiebreak: -entryTokens.Count (longer wins).
    #
    #   Tier 4 (reverse subsequence non-suffix, drive tokens appear
    #     in order with gaps, NOT ending the entry): the firmware-
    #     variant case of Tier 2 ('Panasonic - DVD-RAM UJ8E2 S' when
    #     user typed 'panasonic UJ8E2'). Same intent as Tier 3, just
    #     looser. Tiebreak: -entryTokens.Count (longer wins).
    #
    # Tiers 1-4 are reachable ONLY when -MatchPartialModel is set.
    # Auto-lookup callers leave the switch off and stay in Tier 0,
    # preserving the v6.4.5 strict-forward-contig disambiguation.
    $bestMatch = {
        param([object[]]$Candidates)
        $bestTier     = 99
        $bestTiebreak = [int]::MaxValue
        $best         = $null
        foreach ($c in $Candidates) {
            $entryKey = ConvertTo-RipperDriveNameKey -Name $c.Name
            if ([string]::IsNullOrWhiteSpace($entryKey)) { continue }
            $entryTokens = $entryKey.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($entryTokens.Count -eq 0) { continue }

            $tier     = 99
            $tiebreak = [int]::MaxValue

            # ---- Tier 0: forward contiguous direction ----
            # Entry tokens must appear as a contiguous substring of
            # drive tokens. This is the only path reachable in the
            # auto-lookup flow (no -MatchPartialModel).
            $forwardMatched = $false
            $maxStart = $driveTokens.Count - $entryTokens.Count
            for ($i = 0; $i -le $maxStart; $i++) {
                $allEq = $true
                for ($j = 0; $j -lt $entryTokens.Count; $j++) {
                    if ($driveTokens[$i + $j] -ne $entryTokens[$j]) {
                        $allEq = $false
                        break
                    }
                }
                if ($allEq) { $forwardMatched = $true; break }
            }
            if ($forwardMatched) {
                $tier     = 0
                $tiebreak = -$entryTokens.Count
            }
            elseif ($MatchPartialModel -and $driveTokens.Count -lt $entryTokens.Count) {
                # ---- Tiers 1-4: reverse direction ----
                # Find drive tokens as an ORDERED subsequence inside
                # entry tokens (gaps allowed). The single subsequence
                # scan covers both the contig and the gap cases; we
                # then inspect the resulting positions to assign the
                # right tier.
                $positions  = New-Object 'System.Collections.Generic.List[int]'
                $searchFrom = 0
                $allFound   = $true
                foreach ($needleTok in $driveTokens) {
                    $found = -1
                    for ($k = $searchFrom; $k -lt $entryTokens.Count; $k++) {
                        if ($entryTokens[$k] -eq $needleTok) {
                            $found = $k
                            break
                        }
                    }
                    if ($found -lt 0) { $allFound = $false; break }
                    $positions.Add($found)
                    $searchFrom = $found + 1
                }

                if ($allFound) {
                    # Contiguous = positions are sequential (no gaps).
                    $isContig = $true
                    for ($p = 1; $p -lt $positions.Count; $p++) {
                        if ($positions[$p] -ne $positions[$p-1] + 1) {
                            $isContig = $false
                            break
                        }
                    }
                    # Suffix = the last drive token landed at the last
                    # entry position. Captures the 'entry ends with
                    # the typed model' shape regardless of gaps before.
                    $isSuffix = ($positions[$positions.Count - 1] -eq ($entryTokens.Count - 1))

                    if     ($isContig -and $isSuffix) { $tier = 1; $tiebreak =  $entryTokens.Count }   # canonical (bare)
                    elseif ($isSuffix)                { $tier = 2; $tiebreak =  $entryTokens.Count }   # canonical (with descriptors)
                    elseif ($isContig)                { $tier = 3; $tiebreak = -$entryTokens.Count }   # firmware variant of bare
                    else                              { $tier = 4; $tiebreak = -$entryTokens.Count }   # firmware variant with descriptors
                }
            }

            if ($tier -eq 99) { continue }
            if ($tier -lt $bestTier -or
                ($tier -eq $bestTier -and $tiebreak -lt $bestTiebreak)) {
                $bestTier     = $tier
                $bestTiebreak = $tiebreak
                $best = @{ Offset = [int]$c.Offset; MatchedName = [string]$c.Name }
            }
        }
        return $best
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
            if ($null -ne $liveHit) {
                $liveHit['Source'] = 'Live'
                return $liveHit
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
    $cacheCandidates = foreach ($entry in $cache.drives) {
        [pscustomobject]@{ Name = [string]$entry.match; Offset = [int]$entry.offset }
    }
    $cacheHit = & $bestMatch -Candidates @($cacheCandidates)
    if ($null -ne $cacheHit) {
        $cacheHit['Source'] = 'Cache'
        return $cacheHit
    }
    return $null
}

function Find-RipperAccurateRipOffset {
<#
.SYNOPSIS
    Return the AccurateRip read offset (in samples) for a drive name, or
    $null if no match in either the live page or the cache.

.DESCRIPTION
    Thin shim over Find-RipperAccurateRipEntry that returns just the
    offset. Preserved for callers (and tests) that only need the int.
    Use Find-RipperAccurateRipEntry directly when you also want the
    matched AR-table name (e.g. for logging).

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
    $entry = Find-RipperAccurateRipEntry `
                -DriveName      $DriveName `
                -CachedListPath $CachedListPath `
                -TimeoutSec     $TimeoutSec `
                -SkipLive:$SkipLive
    if ($null -eq $entry) { return $null }
    return [int]$entry.Offset
}

Export-ModuleMember -Function Get-RipperOpticalDrives, Find-RipperAccurateRipOffset, Find-RipperAccurateRipEntry, ConvertTo-RipperDriveNameKey
