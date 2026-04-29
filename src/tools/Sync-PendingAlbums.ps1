<#
.SYNOPSIS
    Phase 6.1 follow-up: re-run sync against every album whose
    sync-state record is not "all targets OK".

.DESCRIPTION
    Recovery tool for the misconfigured-target / transient-failure
    scenarios documented in docs/SYNC-TARGETS.md and
    docs/TROUBLESHOOTING.md. Reads sync-state.json under the library
    root, finds every entry where any configured target is missing or
    not 'OK', re-invokes `Invoke-RipperSync` against the album folder,
    and (if the retry restores AllOk) runs `Invoke-RipperLibraryRetention`
    so a `MoveToSentAfterAllSynced` / `RecycleAfterAllSynced` policy
    finally gets to fire.

    Albums whose folder no longer exists on disk are skipped with a
    WARN -- the user has either moved the album by hand (D-022 vouch
    behaviour applies on re-insert) or recycled it. Either way there
    is nothing to push.

    Albums recorded under `_Sent\` (Source='sent') are skipped: they
    were already AllOk at the time retention moved them.

    By default the tool only retries entries that have a configured
    target whose Status is not 'OK'. `-Force` retries every entry,
    including ones that are already AllOk -- useful after rotating
    credentials or wiping a target's destination.

.PARAMETER LibraryRoot
    Library root. Defaults to `cfg.LibraryRoot`.

.PARAMETER WhatIf
    Standard `ShouldProcess` -- list what would be retried, do nothing.

.PARAMETER Force
    Retry every entry, not just the not-OK ones.

.EXAMPLE
    PS> ./src/tools/Sync-PendingAlbums.ps1
    Walks sync-state.json, retries every album with a non-OK target.

.EXAMPLE
    PS> ./src/tools/Sync-PendingAlbums.ps1 -WhatIf
    Lists pending albums + the targets that would be retried.

.NOTES
    Safe to re-run. Failures stay recorded; one bad target does not
    block another. Exit code is 0 on success, 1 if any target finished
    in a non-OK state.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$LibraryRoot,
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
. (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')
. (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
. (Join-Path $repoRoot 'src\sync\Invoke-RipperSync.ps1')
. (Join-Path $repoRoot 'src\sync\Sync-ToOneDrive.ps1')
. (Join-Path $repoRoot 'src\sync\Sync-ToSynologyNAS.ps1')
. (Join-Path $repoRoot 'src\sync\Invoke-LibraryRetention.ps1')
. (Join-Path $repoRoot 'src\sync\Invoke-PendingSync.ps1')
# Recycle helper lives here -- needed if any retried entry trips
# RecycleAfterAllSynced now that all targets are OK.
. (Join-Path $repoRoot 'src\ui\Show-TargetExistsDialog.ps1')

$cfg = Import-RipperConfig
if (-not $LibraryRoot) { $LibraryRoot = $cfg.LibraryRoot }
if (-not (Test-Path -LiteralPath $LibraryRoot -PathType Container)) {
    throw "LibraryRoot not found: $LibraryRoot"
}

$configuredTargets = @()
if ($cfg.PSObject.Properties['SyncTargets'] -and $cfg.SyncTargets) {
    $configuredTargets = @($cfg.SyncTargets | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
}
if ($configuredTargets.Count -eq 0) {
    Write-Host "No SyncTargets configured in cfg -- nothing to do." -ForegroundColor Yellow
    return
}

Start-RipperLog -Context 'sync-pending-albums' | Out-Null
Write-RipperLog INFO 'SyncPending' "LibraryRoot='$LibraryRoot'; targets=[$($configuredTargets -join ', ')]; Force=$Force"

# Console adapter: print plan up-front, status as albums process, summary at end.
$cliCb = {
    param($Phase, $AlbumIdx, $AlbumTotal, $AlbumKey, $AlbumLabel, $ResultStatus, $ResultDetail)
    switch ($Phase) {
        'plan' {
            if ($AlbumTotal -eq 0) { return }
            Write-Host ''
            Write-Host "Pending albums:" -ForegroundColor Cyan
            foreach ($p in $ResultDetail) {
                $names = @()
                foreach ($n in $configuredTargets) {
                    $st = if ($p.Entry.Targets.PSObject.Properties[$n]) { [string]$p.Entry.Targets.$n.Status } else { 'missing' }
                    $names += "$n=$st"
                }
                Write-Host "  $($p.Key)   [$($names -join ', ')]"
            }
            Write-Host ''
        }
        'album-start' {
            Write-Host ("[{0}/{1}] Syncing: {2}" -f $AlbumIdx, $AlbumTotal, $AlbumKey) -ForegroundColor White
        }
        'album-end' {
            switch ($ResultStatus) {
                'OK'              { Write-Host '  -> OK' -ForegroundColor Green }
                'PartiallyFailed' { Write-Host ("  -> still failing: {0}" -f $ResultDetail.Diagnostic) -ForegroundColor Yellow }
                'Skipped'         { Write-Host '  -> skipped' -ForegroundColor DarkGray }
            }
        }
    }
}.GetNewClosure()

$summary = Invoke-RipperPendingSync `
    -LibraryRoot      $LibraryRoot `
    -Config           $cfg `
    -Force:$Force `
    -ProgressCallback $cliCb `
    -WhatIf:$WhatIfPreference

Write-Host ''
Write-Host ("Done. Restored to OK: {0}/{1}. Still failing: {2}. Skipped: {3}. See {4} for details." -f `
    $summary.Synced, $summary.Total, $summary.StillFailing, $summary.Skipped, (Get-RipperLogPath)) -ForegroundColor Cyan
Stop-RipperLog

if ($summary.StillFailing -gt 0) { exit 1 } else { exit 0 }
