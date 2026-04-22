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
        [Parameter()]          [string]   $CoverArtFile
    )

    $quality = Test-RipQuality -LogPath $LogFile
    Write-RipperLog INFO 'PostProcess' `
        "Quality gate: $($quality.Status) -> $($quality.Destination) (prefix='$($quality.RoutingPrefix)')"

    if ($quality.Destination -eq 'Library') {
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

    $move = Move-RipToLibrary `
        -RipFolder   $RipFolder `
        -LibraryRoot $LibraryRoot `
        -Metadata    $Metadata `
        -Quality     $quality `
        -DiscId      $DiscId
    Write-RipperLog INFO 'PostProcess' `
        "Moved to: $($move.Target) (review=$($move.IsReviewQueue), files=$($move.FilesMoved))"

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

    return @{
        Quality        = $quality
        Move           = $move
        Target         = $move.Target
        IsReviewQueue  = $move.IsReviewQueue
        SessionLogCopy = $sessionLogCopy
    }
}
