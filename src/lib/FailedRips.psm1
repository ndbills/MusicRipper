<#
.SYNOPSIS
    Preserves incomplete extraction attempts outside the active inbox.

.DESCRIPTION
    A hard drive/read failure can happen after several FLAC encoders have
    already closed successfully. This module keeps those completed tracks as
    forensic/recovery artifacts under <LibraryRoot>\_FailedRips, while keeping
    them outside every automatic post-processing and sync path.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function ConvertTo-RipperFailedRipPathSegment {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Value)

    $safe = ($Value -replace '[<>:"/\\|?*\x00-\x1F]', ' ' -replace '\s+', ' ').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'unknown' }
    return $safe
}

function Remove-RipperUnfinishedFlacFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RipFolder,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$CompletedTracks
    )

    $completedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($track in $CompletedTracks) {
        if ($track.FileName) { [void]$completedNames.Add([string]$track.FileName) }
    }
    foreach ($flac in Get-ChildItem -LiteralPath $RipFolder -Filter '*.flac' -File -ErrorAction SilentlyContinue) {
        if (-not $completedNames.Contains($flac.Name)) {
            Remove-Item -LiteralPath $flac.FullName -Force
        }
    }
}

function Get-RipperFailedRipAttempts {
<#
.SYNOPSIS
    Return valid failed-rip attempts, optionally filtered by exact disc id.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [string]$DiscId
    )

    $root = Join-Path $LibraryRoot '_FailedRips'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $attempts = foreach ($marker in Get-ChildItem -LiteralPath $root -Filter 'failed-rip.json' -File -Recurse -ErrorAction SilentlyContinue) {
        try {
            $state = Get-Content -LiteralPath $marker.FullName -Raw | ConvertFrom-Json
            if (-not $state.DiscId) { continue }
            if ($DiscId -and [string]$state.DiscId -cne $DiscId) { continue }
            [pscustomobject]@{
                Path     = $marker.Directory.FullName
                DiscId   = [string]$state.DiscId
                State    = $state
                Manifest = $marker.FullName
            }
        } catch {
            # A malformed marker cannot safely identify an attempt. Leave it
            # untouched for manual inspection.
        }
    }
    return @($attempts)
}

function Move-RipperMarkedFailedRip {
<#
.SYNOPSIS
    Move an in-place marked failed attempt from the inbox to _FailedRips.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$RipFolder,
        [Parameter(Mandatory)] [string]$LibraryRoot
    )

    $markerPath = Join-Path $RipFolder 'failed-rip.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Failed-rip marker is missing: $markerPath"
    }
    $state = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if (-not $state.DiscId -or -not $state.AttemptId) {
        throw "Failed-rip marker is incomplete: $markerPath"
    }
    if (-not $state.PSObject.Properties['CompletedTracks']) {
        throw "Failed-rip marker has no completed-track allowlist: $markerPath"
    }

    Remove-RipperUnfinishedFlacFiles -RipFolder $RipFolder -CompletedTracks @($state.CompletedTracks)

    $discDir = Join-Path (Join-Path $LibraryRoot '_FailedRips') (ConvertTo-RipperFailedRipPathSegment ([string]$state.DiscId))
    if (-not (Test-Path -LiteralPath $discDir)) {
        New-Item -ItemType Directory -Path $discDir -Force | Out-Null
    }
    $destination = Join-Path $discDir (ConvertTo-RipperFailedRipPathSegment ([string]$state.AttemptId))
    if (Test-Path -LiteralPath $destination) {
        throw "Failed-rip destination already exists: $destination"
    }

    Move-Item -LiteralPath $RipFolder -Destination $destination
    return $destination
}

function Save-RipperFailedRip {
<#
.SYNOPSIS
    Mark and archive a hard-failed extraction without deleting completed tracks.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$RipFolder,
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [object]$Metadata,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$CompletedTracks,
        [Parameter(Mandatory)] [int]$FailedTrackNumber,
        [AllowEmptyString()] [string]$FailedTrackTitle,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ErrorMessage,
        [AllowEmptyString()] [string]$DriveLetter,
        [AllowEmptyString()] [string]$DriveName,
        [AllowEmptyString()] [string]$FirmwareRevision,
        [int]$DriveOffset,
        [string]$SessionLogPath
    )

    if (-not (Test-Path -LiteralPath $RipFolder -PathType Container)) {
        throw "Failed rip folder does not exist: $RipFolder"
    }

    $failedAt = [DateTime]::UtcNow
    $driveSegment = ConvertTo-RipperFailedRipPathSegment "$DriveName $DriveLetter"
    $attemptId = '{0} - {1} - {2}' -f $failedAt.ToString('yyyyMMdd-HHmmssfff'), $driveSegment, ([guid]::NewGuid().ToString('N').Substring(0,8))
    $sessionLogFile = if ($SessionLogPath -and (Test-Path -LiteralPath $SessionLogPath -PathType Leaf)) { 'ripper-session.log' } else { $null }

    $state = [ordered]@{
        SchemaVersion      = 1
        AttemptId         = $attemptId
        DiscId             = $DiscId
        AlbumArtist        = [string]$Metadata.AlbumArtist
        Album              = [string]$Metadata.Album
        FailedAtUtc        = $failedAt.ToString('o')
        DriveLetter        = $DriveLetter
        DriveName          = $DriveName
        FirmwareRevision   = $FirmwareRevision
        DriveOffset        = $DriveOffset
        CompletedTracks    = @($CompletedTracks)
        FailedTrackNumber  = $FailedTrackNumber
        FailedTrackTitle   = $FailedTrackTitle
        Error              = $ErrorMessage
        SessionLogFile     = $sessionLogFile
    }
    $markerPath = Join-Path $RipFolder 'failed-rip.json'
    # Transaction boundary: a later retry recognizes this marker even if log
    # copying, pruning, text generation, or the archive move fails.
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $markerPath -Encoding UTF8

    if ($sessionLogFile) {
        Copy-Item -LiteralPath $SessionLogPath -Destination (Join-Path $RipFolder $sessionLogFile) -Force
    }
    Remove-RipperUnfinishedFlacFiles -RipFolder $RipFolder -CompletedTracks $CompletedTracks

    $completedText = if ($CompletedTracks.Count -gt 0) {
        ($CompletedTracks | ForEach-Object { "  $($_.Number). $($_.Title) [$($_.FileName)]" }) -join [Environment]::NewLine
    } else {
        '  (none)'
    }
    $text = @"
MusicRipper failed extraction

Album: $($state.AlbumArtist) - $($state.Album)
Disc ID: $DiscId
Failed: $($failedAt.ToString('o'))
Drive: $DriveName $DriveLetter (firmware $FirmwareRevision, offset $DriveOffset)
Failed track: $FailedTrackNumber - $FailedTrackTitle

Completed tracks preserved:
$completedText

Error:
$ErrorMessage

This is an incomplete, unverified extraction. MusicRipper will start the next
attempt from track 1. Do not move this folder into the music library manually.
"@
    Set-Content -LiteralPath (Join-Path $RipFolder 'FAILED-RIP.txt') -Value $text -Encoding UTF8

    return Move-RipperMarkedFailedRip -RipFolder $RipFolder -LibraryRoot $LibraryRoot
}

function Move-RipperFolderToRecycleBin {
<#
.SYNOPSIS
    Send a folder to the Windows Recycle Bin.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Move-RipperFolderToRecycleBin: not a directory: $Path"
    }
    Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
    if ($PSCmdlet.ShouldProcess($Path, 'Send to Recycle Bin')) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
}

function Remove-RipperFailedRipAttempts {
<#
.SYNOPSIS
    Recycle archived failed attempts matching an exact disc id.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$DiscId
    )

    $results = foreach ($attempt in @(Get-RipperFailedRipAttempts -LibraryRoot $LibraryRoot -DiscId $DiscId)) {
        try {
            if ($PSCmdlet.ShouldProcess($attempt.Path, 'Recycle superseded failed-rip attempt')) {
                Move-RipperFolderToRecycleBin -Path $attempt.Path
            }
            [pscustomobject]@{ Path=$attempt.Path; Recycled=$true; Error=$null; State=$attempt.State }
        } catch {
            [pscustomobject]@{ Path=$attempt.Path; Recycled=$false; Error=$_.Exception.Message; State=$attempt.State }
        }
    }
    return @($results)
}

Export-ModuleMember -Function Get-RipperFailedRipAttempts, Move-RipperFolderToRecycleBin, Move-RipperMarkedFailedRip, Save-RipperFailedRip, Remove-RipperFailedRipAttempts