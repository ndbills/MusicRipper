<#
.SYNOPSIS
    Crash/exit-resilient sidecar for the Phase-5 post-process pipeline.

.DESCRIPTION
    Why this exists: a rip can take 10+ minutes. If MusicRipper (or the
    machine, or the user) dies between Invoke-Rip and Invoke-RipperPostProcess,
    the FLACs+log are stranded under <LibraryRoot>\_inbox\ with nothing
    pointing the next launch at them. Manually re-running tag/move requires
    knowing the disc-id and reconstructing metadata — work the user did
    once already in the Phase-3 dialog.

    The contract:
      - Write-RipperRipState writes _ripper-state.json into the rip folder
        right after Invoke-Rip succeeds. It captures everything
        Invoke-RipperPostProcess needs.
      - Find-RipperOrphanedRips scans <LibraryRoot>\_inbox\ for any folder
        that still has _ripper-state.json (i.e. post-process never finished).
      - Resume-RipperOrphan replays the pipeline against one such folder
        and removes the sidecar on success.
      - Remove-RipperRipState deletes the sidecar after a normal happy-path
        finish, so we don't keep "resuming" rips that are already in the
        Library / _ReviewQueue.

    The sidecar moves with the folder during Move-RipToLibrary (it's just
    another file in OutputDir). Removal targets the *post-move* folder.

.NOTES
    Sidecar file name: _ripper-state.json (leading underscore so it sorts
    above audio in Explorer and is easy to .gitignore should it ever leak).
    Schema is versioned ('Version' = 1) so future changes can be detected.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:RipperStateFileName = '_ripper-state.json'
$script:RipperStateVersion  = 1

function Write-RipperRipState {
<#
.SYNOPSIS
    Persist enough state in the rip folder to resume post-processing later.

.PARAMETER RipFolder
    The just-finished rip output folder (Invoke-Rip's $result.OutputDir).

.PARAMETER DiscId
    Disc.DiscId from Get-RipperDiscId — the post-process pipeline forwards
    this to the tagger.

.PARAMETER Metadata
    The user-confirmed metadata object from Show-RipperMetadataDialog.
    Serialized to JSON; pscustomobject -> nested objects round-trip fine.

.PARAMETER LogFileName
    The leaf name of the rip log inside RipFolder. Stored as a name
    (not a full path) because the folder gets renamed by Move-RipToLibrary;
    on resume we rebuild Join-Path $RipFolder $LogFileName.

.PARAMETER CoverArtFileName
    Optional leaf name of the cover-art file inside RipFolder
    (typically 'cover.jpg'). Same rationale as LogFileName.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RipFolder,
        [Parameter(Mandatory)] [string] $DiscId,
        [Parameter(Mandatory)] [object] $Metadata,
        [Parameter(Mandatory)] [string] $LogFileName,
        [Parameter()]          [string] $CoverArtFileName
    )
    if (-not (Test-Path -LiteralPath $RipFolder -PathType Container)) {
        throw "Write-RipperRipState: RipFolder not found: $RipFolder"
    }
    $payload = [ordered]@{
        Version          = $script:RipperStateVersion
        DiscId           = $DiscId
        Metadata         = $Metadata
        LogFileName      = $LogFileName
        CoverArtFileName = $CoverArtFileName
        RipFinishedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
    $path = Join-Path $RipFolder $script:RipperStateFileName
    # Depth 8 is enough for our nested Tracks[] -> per-track props.
    $json = $payload | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    Write-RipperLog INFO 'Resume' "Wrote sidecar: $path"
    $path
}

function Read-RipperRipState {
<#
.SYNOPSIS
    Load and validate the sidecar in a rip folder. Returns $null if absent.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)] [string] $RipFolder)

    $path = Join-Path $RipFolder $script:RipperStateFileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Read-RipperRipState: $path is not valid JSON: $($_.Exception.Message)"
    }

    foreach ($prop in 'Version','DiscId','Metadata','LogFileName') {
        if (-not $state.PSObject.Properties[$prop]) {
            throw "Read-RipperRipState: $path is missing required property '$prop'."
        }
    }
    if ([int]$state.Version -ne $script:RipperStateVersion) {
        throw "Read-RipperRipState: $path schema version $($state.Version) is not supported (expected $script:RipperStateVersion)."
    }
    $state
}

function Remove-RipperRipState {
<#
.SYNOPSIS
    Delete the sidecar from a folder. Idempotent — silent if already gone.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RipFolder)
    $path = Join-Path $RipFolder $script:RipperStateFileName
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
        Write-RipperLog INFO 'Resume' "Removed sidecar: $path"
    }
}

function Find-RipperOrphanedRips {
<#
.SYNOPSIS
    Scan <LibraryRoot>\_inbox\ for folders with a sidecar (= unfinished rips).

.DESCRIPTION
    Returns one object per orphan:
      @{ Folder = <full path>; State = <Read-RipperRipState result> }

    Folders without a sidecar are ignored — they're either in-progress
    rips or pre-Resume artifacts the user can clean up by hand
    (or via tools/Complete-OrphanedRip.ps1 in commit D).
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $LibraryRoot)

    $inbox = Join-Path $LibraryRoot '_inbox'
    if (-not (Test-Path -LiteralPath $inbox -PathType Container)) { return @() }

    $found = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $inbox -Directory -ErrorAction SilentlyContinue)) {
        $sidecar = Join-Path $dir.FullName $script:RipperStateFileName
        if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { continue }
        try {
            $state = Read-RipperRipState -RipFolder $dir.FullName
        } catch {
            Write-RipperLog WARN 'Resume' "Skipping unreadable orphan $($dir.FullName): $($_.Exception.Message)"
            continue
        }
        $found += [pscustomobject]@{
            Folder = $dir.FullName
            State  = $state
        }
    }
    # Caller is expected to wrap in @() — keeps a single result usable as
    # an array. Don't unary-comma here or @() will double-wrap.
    $found
}

function Resume-RipperOrphan {
<#
.SYNOPSIS
    Re-run Invoke-RipperPostProcess against a single orphaned rip folder.

.DESCRIPTION
    Reconstructs the args from the sidecar (LogFile + CoverArtFile rebuilt
    relative to the current RipFolder so this is robust to the user
    renaming the folder before resume). Removes the sidecar from the
    *post-move* destination on success.

    Returns the same hashtable as Invoke-RipperPostProcess. Throws on any
    pipeline failure (sidecar is left in place so the user can retry).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $RipFolder,
        [Parameter(Mandatory)] [string] $LibraryRoot,

        # Phase 5.11 recovery: passed through when the user picks
        # "Keep both" / "Send to Review" on Show-RipperTargetExistsDialog
        # for an orphan that collides with an existing library album.
        [switch] $AllowSideBySide,
        [switch] $ForceReviewQueue
    )

    $state = Read-RipperRipState -RipFolder $RipFolder
    if (-not $state) {
        throw "Resume-RipperOrphan: no sidecar in $RipFolder"
    }

    $logFile = Join-Path $RipFolder $state.LogFileName
    if (-not (Test-Path -LiteralPath $logFile -PathType Leaf)) {
        throw "Resume-RipperOrphan: log file '$($state.LogFileName)' not found in $RipFolder"
    }

    $coverFile = $null
    if ($state.PSObject.Properties['CoverArtFileName'] -and $state.CoverArtFileName) {
        $candidate = Join-Path $RipFolder $state.CoverArtFileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $coverFile = $candidate }
    }

    Write-RipperLog INFO 'Resume' "Resuming orphan: $RipFolder (DiscId=$($state.DiscId))"

    $pp = Invoke-RipperPostProcess `
        -RipFolder    $RipFolder `
        -LogFile      $logFile `
        -Metadata     $state.Metadata `
        -DiscId       $state.DiscId `
        -LibraryRoot  $LibraryRoot `
        -CoverArtFile $coverFile `
        -AllowSideBySide:$AllowSideBySide `
        -ForceReviewQueue:$ForceReviewQueue

    # Sidecar moved with the folder; clean it up from the new location.
    Remove-RipperRipState -RipFolder $pp.Target
    $pp
}
