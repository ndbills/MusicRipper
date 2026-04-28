<#
.SYNOPSIS
    Manually finish post-processing for an orphaned rip folder.

.DESCRIPTION
    Companion to the auto-resume flow in Start-Ripper. Use this when:
      - The orphan predates the _ripper-state.json sidecar (rip from
        before commit C, or sidecar manually deleted), so auto-resume
        can't see it.
      - You want to re-run post-processing against a folder that was
        already moved to the library (e.g. tags need a redo) — pass an
        explicit -DiscId and the tool will rebuild metadata from MB.
      - You want to recover a rip from a different machine: copy the
        whole folder under <LibraryRoot>\_inbox\ and run this script.

    Two modes:
      A) Sidecar present  -> identical to auto-resume: read state, replay
         Invoke-RipperPostProcess, remove sidecar. No prompts.
      B) Sidecar missing  -> -DiscId is required. Tool queries MusicBrainz,
         pops Show-RipperMetadataDialog so you can pick/edit metadata,
         then runs Invoke-RipperPostProcess against your selection. The
         pipeline writes its own sidecar implicitly via tags + move.

    Exits without touching the folder if the user cancels the dialog
    in mode B.

.PARAMETER RipFolder
    Full path to the orphaned rip folder (must contain at least the .log
    file Test-RipQuality wants to inspect).

.PARAMETER DiscId
    Required only in mode B (no sidecar). The MusicBrainz disc id you
    captured at rip time (look at the rip log header — Invoke-Rip writes
    it in the first lines, and the folder name often hints at the album).

.PARAMETER LibraryRoot
    Override the library root from config.json. Useful when recovering
    a rip into a non-default library for testing.

.EXAMPLE
    PS> ./src/tools/Complete-OrphanedRip.ps1 `
            -RipFolder 'E:\digitize\MusicRipper\_inbox\Mormon Tabernacle Choir - Spirit of the Season' `
            -DiscId    'znRMzBsSLNg63EFUWMJt2JVU.bg-'
    Pops the metadata dialog, then tags + moves the folder into the Plex
    layout under <LibraryRoot>.

.EXAMPLE
    PS> ./src/tools/Complete-OrphanedRip.ps1 -RipFolder 'D:\Inbox\X'
    Sidecar-driven resume — no prompts.

.NOTES
    This script intentionally does NOT touch the optical drive or eject
    anything. It's a pure post-process replay over files already on disk.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RipFolder,

    [Parameter()]
    [string] $DiscId,

    [Parameter()]
    [string] $LibraryRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force

. (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
. (Join-Path $repoRoot 'src\core\Test-RipQuality.ps1')
. (Join-Path $repoRoot 'src\core\Write-Tags.ps1')
. (Join-Path $repoRoot 'src\core\Move-ToLibrary.ps1')
. (Join-Path $repoRoot 'src\core\New-ReviewQueueArtifacts.ps1')
. (Join-Path $repoRoot 'src\core\Invoke-PostProcess.ps1')
. (Join-Path $repoRoot 'src\core\Resume.ps1')
. (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')
. (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
. (Join-Path $repoRoot 'src\sync\Invoke-RipperSync.ps1')
. (Join-Path $repoRoot 'src\sync\Invoke-LibraryRetention.ps1')
. (Join-Path $repoRoot 'src\ui\Show-MetadataDialog.ps1')

$logPath = Start-RipperLog -Context 'complete-orphaned-rip'
Write-RipperLog INFO 'Complete-Orphan' "Tool start. RipFolder=$RipFolder DiscId=$DiscId"

if (-not (Test-Path -LiteralPath $RipFolder -PathType Container)) {
    throw "RipFolder not found: $RipFolder"
}

# Resolve LibraryRoot from config if not overridden. Always load $cfg
# (even when -LibraryRoot is supplied) so the Phase 6.1 sync orchestrator
# downstream sees the configured SyncTargets / LocalRetention.
if (-not $LibraryRoot) {
    $cfg = Import-RipperConfig
    $LibraryRoot = $cfg.LibraryRoot
} else {
    try { $cfg = Import-RipperConfig } catch { $cfg = $null }
}
Write-RipperLog INFO 'Complete-Orphan' "LibraryRoot=$LibraryRoot"

# --- Mode A: sidecar-driven resume (no prompts) ---------------------------
$state = Read-RipperRipState -RipFolder $RipFolder
if ($state) {
    Write-RipperLog INFO 'Complete-Orphan' "Sidecar found (Version=$($state.Version), DiscId=$($state.DiscId)) — running silent resume."
    $pp = Resume-RipperOrphan -RipFolder $RipFolder -LibraryRoot $LibraryRoot -Config $cfg
    Write-RipperLog INFO 'Complete-Orphan' "Done. Target=$($pp.Target) Quality=$($pp.Quality.Status)"
    Stop-RipperLog
    return $pp
}

# --- Mode B: no sidecar — need explicit DiscId + dialog -------------------
if (-not $DiscId) {
    throw @"
No sidecar at $RipFolder\_ripper-state.json — this orphan predates auto-resume.

Re-run with -DiscId <musicbrainz-disc-id>. You can find the disc id in the
first few lines of the rip log inside the folder, or at MusicBrainz.org.
"@
}

# Locate the rip log so Test-RipQuality has something to read.
$logFile = Get-ChildItem -LiteralPath $RipFolder -Filter '*.log' -File `
              -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTimeUtc -Descending |
           Select-Object -First 1
if (-not $logFile) {
    throw "No .log file under $RipFolder — Test-RipQuality has nothing to assess."
}
Write-RipperLog INFO 'Complete-Orphan' "Using log: $($logFile.FullName)"

# Optional cover art from the rip folder (Invoke-Rip writes cover.jpg).
$coverPath = Join-Path $RipFolder 'cover.jpg'
if (-not (Test-Path -LiteralPath $coverPath -PathType Leaf)) { $coverPath = $null }

# Wrap the bare DiscId in the shape Get-RipperDiscMetadata expects.
$discInfo = [pscustomobject]@{ DiscId = $DiscId }

Write-RipperLog INFO 'Complete-Orphan' "Querying MusicBrainz for $DiscId"
try {
    $meta = Get-RipperDiscMetadata -DiscIdInfo $discInfo
} catch {
    Write-RipperLog WARN 'Complete-Orphan' "MusicBrainz lookup failed: $($_.Exception.Message)"
    # Fall back to an Offline-style result so the dialog still comes up
    # and the user can hand-edit the metadata or send to review.
    $meta = [pscustomobject]@{
        DiscId     = $DiscId
        Status     = 'Offline'
        BestMatch  = $null
        Candidates = @()
    }
}

$onResearch = {
    Write-RipperLog INFO 'Complete-Orphan' "Re-search MusicBrainz requested for $DiscId."
    Get-RipperDiscMetadata -DiscIdInfo $discInfo
}

$choice = Show-RipperMetadataDialog -Metadata $meta -OnResearch $onResearch
Write-RipperLog INFO 'Complete-Orphan' "Dialog choice: $($choice.Action)"

if ($choice.Action -eq 'Cancel') {
    Write-RipperLog INFO 'Complete-Orphan' 'User cancelled — leaving orphan untouched.'
    Stop-RipperLog
    return
}

# 'Rip' and 'Review' both feed Invoke-RipperPostProcess; the quality gate
# (re-evaluated from the existing log) is what actually decides routing.
$pp = Invoke-RipperPostProcess `
    -RipFolder    $RipFolder `
    -LogFile      $logFile.FullName `
    -Metadata     $choice.Metadata `
    -DiscId       $DiscId `
    -LibraryRoot  $LibraryRoot `
    -CoverArtFile $coverPath `
    -Config       $cfg

Write-RipperLog INFO 'Complete-Orphan' "Done. Target=$($pp.Target) Quality=$($pp.Quality.Status) Review=$($pp.IsReviewQueue)"
Stop-RipperLog
$pp
