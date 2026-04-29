<#
.SYNOPSIS
    Phase 5 pipeline: quality gate -> tag (library only) ->
    Plex-layout/_ReviewQueue move -> review artifacts.

.DESCRIPTION
    Pure orchestration extracted from Start-Ripper so the same pipeline
    can be driven from:
      - the normal "rip just finished" path in Start-Ripper,
      - the auto-resume path that picks up an orphaned rip on next launch,
      - the manual src/tools/Complete-OrphanedRip.ps1 helper.

    Throws on any pipeline failure — the caller owns user-facing dialog,
    eject, and log shutdown so this function stays UI-free.

.NOTES
    Inputs match what the rip + dependency layers already produce:
      - RipFolder    : Invoke-Rip's $result.OutputDir
      - LogFile      : Invoke-Rip's $result.LogFile
      - CoverArtFile : Invoke-Rip's $result.CoverArtFile (may be missing)
      - Metadata     : the user-confirmed Show-MetadataDialog result
      - DiscId       : disc.DiscId from Get-RipperDiscId
      - LibraryRoot  : cfg.LibraryRoot

    Returns a hashtable:
      @{
        Quality      = <Test-RipQuality result>
        Move         = <Move-RipToLibrary result>
        Target       = $Move.Target
        IsReviewQueue = $Move.IsReviewQueue
      }

    Library-bound rips get tags + cover + ReplayGain via Invoke-RipperWriteTags.
    Review-queue rips stay untagged (so a human in Picard sees raw disc state)
    but DO get REVIEW.txt + a single-file FLAC image for foobar2000 inspection.
#>

function Invoke-RipperPostProcess {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]   $RipFolder,
        [Parameter(Mandatory)] [string]   $LogFile,
        [Parameter(Mandatory)] [object]   $Metadata,
        [Parameter(Mandatory)] [string]   $DiscId,
        [Parameter(Mandatory)] [string]   $LibraryRoot,
        [Parameter()]          [string]   $CoverArtFile,
        [switch]                          $AllowSideBySide,
        [switch]                          $ForceReviewQueue,
        # Phase 6.1: optional config object. When supplied AND the move
        # routes to Library AND cfg.SyncTargets is non-empty, runs the
        # sync orchestrator + LocalRetention disposal. Omitted/null
        # means "skip Phase 6.1" -- preserves the previous behaviour
        # for callers that don't pass it (e.g. older tests).
        [Parameter()]          [object]   $Config,
        # Phase 6.2.C: optional scriptblock invoked with one string arg
        # before each major step ("Tagging FLAC files...", "Moving to
        # library...", "Syncing to <Target>...", etc.). Used by the
        # progress UI to show a live post-process status line. Errors
        # inside the callback are swallowed -- it is purely advisory.
        [Parameter()]          [scriptblock] $StatusCallback,
        # Phase 6.2.D: optional scriptblock fired with a fractional
        # overall progress value [0.0 .. 1.0] using the weighting:
        #   sidecar/quality 5%  +  tagging 50%  +  move 5%
        #   +  sync 35%  +  retention 5%.
        # Signature: param([double]$OverallFraction, [int]$TagCurrent, [int]$TagTotal)
        # TagCurrent/TagTotal are 0/0 outside the tagging phase so the
        # UI can keep a steady tagging-specific readout.
        [Parameter()]          [scriptblock] $ProgressCallback
    )

    # Per-step weights -- see file header. Must sum to 1.0.
    $W_SIDECAR    = 0.02
    $W_QUALITY    = 0.03
    $W_TAG        = 0.50   # split equally per track
    $W_MOVE       = 0.05
    $W_SYNC       = 0.35   # split equally per target
    $W_RETENTION  = 0.05

    $script:ppOverall = 0.0
    $script:ppTagCur  = 0
    $script:ppTagTot  = 0
    $reportOverall = {
        if ($ProgressCallback) {
            try { & $ProgressCallback $script:ppOverall $script:ppTagCur $script:ppTagTot } catch { }
        }
    }.GetNewClosure()
    $bumpOverall = {
        param([double]$delta)
        $script:ppOverall = [Math]::Min(1.0, $script:ppOverall + $delta)
        & $reportOverall
    }.GetNewClosure()

    $reportStatus = {
        param([string]$Msg)
        if ($StatusCallback) { try { & $StatusCallback $Msg } catch { } }
    }.GetNewClosure()

    & $reportStatus 'Checking rip quality...'
    $quality = Test-RipQuality -LogPath $LogFile
    & $bumpOverall ($W_SIDECAR + $W_QUALITY)
    Write-RipperLog INFO 'PostProcess' `
        "Quality gate: $($quality.Status) -> $($quality.Destination) (prefix='$($quality.RoutingPrefix)')"

    # Phase 5.9: user-driven "Send to Review" overrides the quality gate.
    # The rip itself may be Verified, but the user wants to fix metadata
    # in Picard before it lands in the library. Use a distinct routing
    # prefix so it's obvious in _ReviewQueue\ that this was a user choice
    # (vs. SUSPECT/UNKNOWN routed automatically by quality).
    if ($ForceReviewQueue -and $quality.Destination -ne 'ReviewQueue') {
        Write-RipperLog INFO 'PostProcess' `
            "ForceReviewQueue: overriding $($quality.Destination)/'$($quality.RoutingPrefix)' -> ReviewQueue/'USER-REVIEW'."
        $quality.Destination   = 'ReviewQueue'
        $quality.RoutingPrefix = 'USER-REVIEW'
    }

    if ($quality.Destination -eq 'Library') {
        & $reportStatus 'Tagging FLAC files...'
        $tagArgs = @{
            RipFolder = $RipFolder
            Metadata  = $Metadata
            DiscId    = $DiscId
        }
        if ($CoverArtFile -and (Test-Path -LiteralPath $CoverArtFile)) {
            $tagArgs.CoverArtBytes = [System.IO.File]::ReadAllBytes($CoverArtFile)
        }
        # Phase 6.2.D: thread per-track progress through Invoke-RipperWriteTags
        # so the Tagging bar advances live and contributes to overall.
        $tagCb = {
            param([int]$Cur, [int]$Tot, [string]$Phase)
            $script:ppTagCur = $Cur
            $script:ppTagTot = $Tot
            if ($Phase -eq 'ReplayGain') {
                & $reportStatus 'Computing ReplayGain...'
            }
            & $reportOverall
        }.GetNewClosure()
        $tagArgs.ProgressCallback = $tagCb
        # Bump overall up to (sidecar+quality + tagging) by walking it
        # in lockstep with the per-track callback. We track the share
        # already attributed to tagging so the bump is incremental.
        $script:ppTagShareAttributed = 0.0
        $tagCbBump = {
            param([int]$Cur, [int]$Tot, [string]$Phase)
            $script:ppTagCur = $Cur
            $script:ppTagTot = $Tot
            if ($Tot -gt 0) {
                $share = [Math]::Min(1.0, [double]$Cur / [double]$Tot) * $W_TAG
                $delta = [Math]::Max(0.0, $share - $script:ppTagShareAttributed)
                $script:ppTagShareAttributed = $share
                $script:ppOverall = [Math]::Min(1.0, $script:ppOverall + $delta)
            }
            if ($Phase -eq 'ReplayGain') {
                & $reportStatus 'Computing ReplayGain...'
            }
            & $reportOverall
        }.GetNewClosure()
        $tagArgs.ProgressCallback = $tagCbBump
        Invoke-RipperWriteTags @tagArgs | Out-Null
        # Whatever didn't get attributed (e.g. SkipReplayGain wasn't set
        # but loop-end vs final ReplayGain timing) -- top up to the full
        # tagging share before moving on.
        $remaining = $W_TAG - $script:ppTagShareAttributed
        if ($remaining -gt 0) { & $bumpOverall $remaining }
        $script:ppTagCur = 0
        $script:ppTagTot = 0
    } else {
        # Review-queue rips skip tagging entirely; advance the bar by
        # the tagging share so overall still hits 100%.
        & $bumpOverall $W_TAG
    }

    & $reportStatus 'Moving to library...'
    $move = Move-RipToLibrary `
        -RipFolder        $RipFolder `
        -LibraryRoot      $LibraryRoot `
        -Metadata         $Metadata `
        -Quality          $quality `
        -DiscId           $DiscId `
        -AllowSideBySide:$AllowSideBySide
    & $bumpOverall $W_MOVE
    Write-RipperLog INFO 'PostProcess' `
        "Moved to: $($move.Target) (review=$($move.IsReviewQueue), files=$($move.FilesMoved), sideBySide=$($move.IsSideBySide))"

    # Phase 5.8: record Library moves in the cross-session DiscId index.
    # Best-effort -- failure here must not undo the move (we already
    # have the rip on disk; the index is advisory).
    if (-not $move.IsReviewQueue) {
        try {
            $year  = if ($Metadata.PSObject.Properties['Year'] -and $Metadata.Year) { " ($([int]$Metadata.Year))" } else { '' }
            $label = "$($Metadata.AlbumArtist) - $($Metadata.Album)$year"
            Add-RipperLibraryDiscIndexEntry `
                -LibraryRoot $LibraryRoot `
                -DiscId      $DiscId `
                -Path        $move.Target `
                -Label       $label `
                -Source      'library' | Out-Null
        } catch {
            Write-RipperLog WARN 'PostProcess' "DiscId index write failed (advisory): $($_.Exception.Message)"
        }
    }

    if ($move.IsReviewQueue) {
        $logFileName = Split-Path -Leaf $LogFile
        Write-RipperReviewTxt `
            -ReviewFolder $move.Target `
            -Quality      $quality `
            -Metadata     $Metadata `
            -DiscId       $DiscId `
            -LogFileName  $logFileName | Out-Null
        New-RipperReviewImage `
            -ReviewFolder $move.Target `
            -Metadata     $Metadata `
            -DiscId       $DiscId | Out-Null
    }

    # Drop a copy of the structured session log next to the album so
    # whoever rips can inspect what happened without digging through
    # %LOCALAPPDATA%\MusicRipper\logs. Especially valuable for the review
    # queue, where a human will be triaging the rip after the fact.
    # Best-effort — a failed copy must not undo the move.
    $sessionLogCopy = Copy-RipperLog -Destination $move.Target
    if ($sessionLogCopy) {
        Write-RipperLog INFO 'PostProcess' "Snapshot of session log -> $sessionLogCopy"
    }

    # Phase 6.1: optional sync orchestrator + LocalRetention disposal.
    # Library-bound rips only -- review-queue items are drafts and
    # don't get pushed off-machine until a human approves them. The
    # sync layer never throws out of itself; the retention layer is
    # wrapped in try/catch so a partial-sync edge case can't undo the
    # successful move.
    $sync      = $null
    $retention = $null
    if (-not $move.IsReviewQueue -and $Config) {
        # Phase 6.2.D: convert sync's StatusCallback into a hybrid that
        # also bumps the overall bar by W_SYNC / N_targets each time a
        # new target starts. Robocopy has no inner progress so this is
        # the finest grain we can give the user honestly.
        $names = @()
        if ($Config.PSObject.Properties['SyncTargets'] -and $Config.SyncTargets) {
            $names = @($Config.SyncTargets | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
        }
        $perTargetShare = if ($names.Count -gt 0) { $W_SYNC / $names.Count } else { $W_SYNC }
        $script:ppSyncSeen = 0
        $syncStatusCb = {
            param([string]$Msg)
            if ($Msg -like 'Syncing to *') {
                if ($script:ppSyncSeen -gt 0) {
                    # Bump for the *previous* target finishing. The first
                    # target's bump fires at end-of-sync below.
                    $script:ppOverall = [Math]::Min(1.0, $script:ppOverall + $perTargetShare)
                }
                $script:ppSyncSeen++
            }
            if ($StatusCallback) { try { & $StatusCallback $Msg } catch { } }
            & $reportOverall
        }.GetNewClosure()
        try {
            $sync = Invoke-RipperSync `
                -AlbumPath      $move.Target `
                -LibraryRoot    $LibraryRoot `
                -DiscId         $DiscId `
                -Config         $Config `
                -StatusCallback $syncStatusCb
        } catch {
            Write-RipperLog WARN 'PostProcess' "Sync orchestrator threw (non-fatal): $($_.Exception.Message)"
            $sync = @{ AlbumPath=$move.Target; Targets=@(); AllOk=$false; Skipped=$false }
        }
        # Top up the sync share -- the per-target bumps fired N-1 times
        # (each new target marks the previous as done); credit the last
        # target plus any rounding remainder.
        if ($names.Count -gt 0) {
            $alreadyAttributed = ($script:ppSyncSeen - 1) * $perTargetShare
            if ($alreadyAttributed -lt 0) { $alreadyAttributed = 0.0 }
            $remaining = $W_SYNC - $alreadyAttributed
            if ($remaining -gt 0) { & $bumpOverall $remaining }
        } else {
            & $bumpOverall $W_SYNC
        }

        if ($sync -and -not $sync.Skipped) {
            & $reportStatus 'Applying retention policy...'
            try {
                $retention = Invoke-RipperLibraryRetention `
                    -AlbumPath   $move.Target `
                    -LibraryRoot $LibraryRoot `
                    -Config      $Config `
                    -SyncResult  $sync `
                    -DiscId      $DiscId
            } catch {
                Write-RipperLog WARN 'PostProcess' "Retention threw (non-fatal): $($_.Exception.Message)"
                $retention = @{ Action='None'; Reason="Retention threw: $($_.Exception.Message)"; NewPath=$null }
            }
        }
        & $bumpOverall $W_RETENTION
    } else {
        # No sync configured / review-queue rip -- credit the remainder
        # so overall reaches 1.0 cleanly.
        & $bumpOverall ($W_SYNC + $W_RETENTION)
    }
    & $reportStatus 'Done.'

    return @{
        Quality        = $quality
        Move           = $move
        Target         = if ($retention -and $retention.Action -eq 'MovedToSent' -and $retention.NewPath) { $retention.NewPath } else { $move.Target }
        IsReviewQueue  = $move.IsReviewQueue
        SessionLogCopy = $sessionLogCopy
        Sync           = $sync
        Retention      = $retention
    }
}
