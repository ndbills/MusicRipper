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
        [Parameter()]          [scriptblock] $StatusCallback
    )

    $reportStatus = {
        param([string]$Msg)
        if ($StatusCallback) { try { & $StatusCallback $Msg } catch { } }
    }.GetNewClosure()

    & $reportStatus 'Checking rip quality...'
    $quality = Test-RipQuality -LogPath $LogFile
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
        Invoke-RipperWriteTags @tagArgs | Out-Null
    }

    & $reportStatus 'Moving to library...'
    $move = Move-RipToLibrary `
        -RipFolder        $RipFolder `
        -LibraryRoot      $LibraryRoot `
        -Metadata         $Metadata `
        -Quality          $quality `
        -DiscId           $DiscId `
        -AllowSideBySide:$AllowSideBySide
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
        try {
            $sync = Invoke-RipperSync `
                -AlbumPath      $move.Target `
                -LibraryRoot    $LibraryRoot `
                -DiscId         $DiscId `
                -Config         $Config `
                -StatusCallback $StatusCallback
        } catch {
            Write-RipperLog WARN 'PostProcess' "Sync orchestrator threw (non-fatal): $($_.Exception.Message)"
            $sync = @{ AlbumPath=$move.Target; Targets=@(); AllOk=$false; Skipped=$false }
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
    }

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
