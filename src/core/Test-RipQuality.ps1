<#
.SYNOPSIS
    Phase 5 quality gate: read a rip log written by Invoke-Rip.ps1 and
    return a routing decision (main library vs. _ReviewQueue).

.DESCRIPTION
    Pipeline position:
        Step 5 of the daily flow. Called from Start-Ripper.ps1 after
        Invoke-Rip returns successfully. Its output decides whether the
        rip continues into Write-Tags + Move-ToLibrary or gets diverted
        to the _ReviewQueue.

    Implementation:
        Most of the parse work already lives in
        `RipHelpers\Get-RipperLogSummary` (Phase 4), which produces the
        canonical Status enum (Verified | ProbablyGood | Suspect |
        NotInDatabase | Unknown). Test-RipQuality wraps that with:

          1. File I/O (read the log from disk).
          2. Defense-in-depth scan for explicit read-error keywords
             ("re-read", "abort", "skipped", "bad sector", "C2 error",
             "unrecoverable") that the rollup logic might otherwise miss
             on log-shape changes between CUETools versions. Any hit
             escalates the verdict to Suspect.
          3. A routing helper that maps the (possibly-escalated) Status
             to a destination tag and a human-readable reason for
             REVIEW.txt.

        Per plan.md "Phase 5 Quality gate", three buckets matter:
          - Verified            -> main library
          - ProbablyGood        -> main library (rip OK, just no AR/CTDB hit)
          - Suspect / Unknown   -> _ReviewQueue with reason
          - NotInDatabase       -> main library (treated as ProbablyGood)

        We deliberately do NOT downgrade NotInDatabase to ReviewQueue:
        plenty of the family's discs (private-press classical, regional
        compilations, kids' albums) will never be in AR/CTDB but rip
        cleanly. Sending those to review would defeat the point.

.NOTES
    Pure-logic helpers (Test-RipperLogContainsReadErrors,
    Get-RipperQualityRouting) are exported from this script so the
    Pester suite can test them without needing a real rip on disk.

    See:
      - src/core/Invoke-Rip.ps1 (writes the log this script reads)
      - src/lib/RipHelpers.psm1 :: Get-RipperLogSummary
      - docs/PHASE-4-SPIKE.md §7 (log contract)
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')     -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1')    -Force
Import-Module (Join-Path $repoRoot 'src\lib\RipHelpers.psd1') -Force


function Test-RipperLogContainsReadErrors {
<#
.SYNOPSIS
    Scan rip-log text for explicit drive-read failure keywords.

.DESCRIPTION
    A safety net for cases where the per-track AR/CTDB rollup might
    classify a rip as Verified (because the final pass eventually
    matched) but the log shows the drive struggled. Any of these
    indicators forces a Suspect verdict:

        re-read, reread, retry, retried, abort, aborted, skipped,
        bad sector, c2 error, c2 errors, unrecoverable, read error,
        read errors

    Match is case-insensitive and word-boundary aware where it matters
    (so "abort" matches "Aborted" but not "Aborigines"). Phase 4's own
    log writer never emits these strings on a clean rip, so a hit is a
    real signal, not boilerplate noise.

.PARAMETER LogText
    Full text of the rip log.

.OUTPUTS
    [bool] — $true if any indicator matched, else $false.

.EXAMPLE
    PS> Test-RipperLogContainsReadErrors -LogText $log
    False
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$LogText
    )

    if ([string]::IsNullOrWhiteSpace($LogText)) { return $false }

    # Word-boundary anchors keep us from flagging unrelated words. "C2"
    # only counts when followed by "error(s)" — bare "C2" appears in
    # offset notation. "Re-read" / "reread" both tolerated.
    $patterns = @(
        '\bre-?read(s|ing)?\b',
        '\bretr(y|ied|ies|ying)\b',
        '\babort(ed|ing)?\b',
        '\bskipped\b',
        '\bbad\s+sector(s)?\b',
        '\bC2\s+error(s)?\b',
        '\bunrecoverable\b',
        '\bread\s+error(s)?\b'
    )
    foreach ($p in $patterns) {
        if ($LogText -imatch $p) { return $true }
    }
    $false
}


function Get-RipperQualityRouting {
<#
.SYNOPSIS
    Translate a quality Status into a library-vs-review routing decision.

.DESCRIPTION
    Pure mapping. Inputs:
      - Status: one of Verified | ProbablyGood | Suspect | NotInDatabase | Unknown
        (the values produced by Get-RipperLogSummary).

    Output object:
        @{
          Destination = 'Library' | 'ReviewQueue'
          QueuePrefix = $null | 'SUSPECT' | 'UNKNOWN'
          Reason      = human-readable string for REVIEW.txt
        }

    Mapping rules (derived from plan.md "Phase 5 Quality gate" + D-006):
      Verified       -> Library
      ProbablyGood   -> Library  (rip OK, just no AR hit at conf >= 2)
      NotInDatabase  -> Library  (deliberate; see Test-RipQuality.ps1
                                  header note about family's obscure discs)
      Suspect        -> ReviewQueue, prefix=SUSPECT
      Unknown        -> ReviewQueue, prefix=UNKNOWN
      anything else  -> ReviewQueue, prefix=UNKNOWN  (safe default)

.PARAMETER Status
    The Status string from Get-RipperLogSummary.

.OUTPUTS
    [pscustomobject] with Destination, QueuePrefix, Reason.

.EXAMPLE
    PS> Get-RipperQualityRouting -Status 'Verified'

    Destination QueuePrefix Reason
    ----------- ----------- ------
    Library                 AccurateRip-verified
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Status
    )

    switch ($Status) {
        'Verified' {
            [pscustomobject]@{
                Destination = 'Library'
                QueuePrefix = $null
                Reason      = 'AccurateRip-verified'
            }
        }
        'ProbablyGood' {
            [pscustomobject]@{
                Destination = 'Library'
                QueuePrefix = $null
                Reason      = 'Rip completed cleanly; AR/CTDB confidence below high-confidence threshold'
            }
        }
        'NotInDatabase' {
            [pscustomobject]@{
                Destination = 'Library'
                QueuePrefix = $null
                Reason      = 'Rip completed cleanly; disc not present in AccurateRip or CTDB'
            }
        }
        'Suspect' {
            [pscustomobject]@{
                Destination = 'ReviewQueue'
                QueuePrefix = 'SUSPECT'
                Reason      = 'Rip-quality issue: AR mismatch, read error, or escalated by log scan'
            }
        }
        'Unknown' {
            [pscustomobject]@{
                Destination = 'ReviewQueue'
                QueuePrefix = 'UNKNOWN'
                Reason      = 'Rip log could not be classified (unrecognized format or empty)'
            }
        }
        default {
            [pscustomobject]@{
                Destination = 'ReviewQueue'
                QueuePrefix = 'UNKNOWN'
                Reason      = "Unexpected status '$Status'"
            }
        }
    }
}


function Test-RipQuality {
<#
.SYNOPSIS
    Read a rip log from disk and produce a routing decision.

.DESCRIPTION
    The integration entry point Start-Ripper calls between Invoke-Rip
    and Move-ToLibrary. Combines Get-RipperLogSummary (parse),
    Test-RipperLogContainsReadErrors (escalation), and
    Get-RipperQualityRouting (mapping) into a single decision object.

.PARAMETER LogPath
    Absolute path to the rip log file written by Invoke-Rip.

.OUTPUTS
    [pscustomobject] with:
        Status        : final Status after read-error escalation
        OriginalStatus: Status before escalation (for diagnostic logging)
        Destination   : 'Library' | 'ReviewQueue'
        QueuePrefix   : $null | 'SUSPECT' | 'UNKNOWN'
        Reason        : human-readable reason string
        Summary       : the full Get-RipperLogSummary object
        LogPath       : echoed back

.EXAMPLE
    PS> $q = Test-RipQuality -LogPath 'C:\...\Spirit of the Season.log'
    PS> if ($q.Destination -eq 'ReviewQueue') { ... }

.NOTES
    On a missing log file we return Status=Unknown and route to
    ReviewQueue rather than throwing — Start-Ripper should still be
    able to move the rip somewhere safe even if the log was lost.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        Write-RipperLog WARN 'Test-RipQuality' "Log file not found: $LogPath"
        $routing = Get-RipperQualityRouting -Status 'Unknown'
        return [pscustomobject]@{
            Status         = 'Unknown'
            OriginalStatus = 'Unknown'
            Destination    = $routing.Destination
            QueuePrefix    = $routing.QueuePrefix
            RoutingPrefix  = if ($routing.QueuePrefix) { [string]$routing.QueuePrefix } else { '' }
            Reason         = 'Rip log file not found on disk'
            Summary        = $null
            LogPath        = $LogPath
        }
    }

    $logText = Get-Content -LiteralPath $LogPath -Raw
    $summary = Get-RipperLogSummary -LogText $logText
    $original = $summary.Status

    # Defense in depth: even if the rollup says Verified, an explicit
    # read-error keyword anywhere in the log forces Suspect.
    $finalStatus = $original
    if ((Test-RipperLogContainsReadErrors -LogText $logText) -and
        $finalStatus -ne 'Suspect') {
        Write-RipperLog WARN 'Test-RipQuality' `
            "Escalating $original -> Suspect due to read-error keyword in $LogPath"
        $finalStatus = 'Suspect'
    }

    $routing = Get-RipperQualityRouting -Status $finalStatus
    $routingPrefix = if ($routing.QueuePrefix) { [string]$routing.QueuePrefix } else { '' }
    [pscustomobject]@{
        Status         = $finalStatus
        OriginalStatus = $original
        Destination    = $routing.Destination
        QueuePrefix    = $routing.QueuePrefix
        RoutingPrefix  = $routingPrefix
        Reason         = $routing.Reason
        Summary        = $summary
        LogPath        = $LogPath
    }
}
