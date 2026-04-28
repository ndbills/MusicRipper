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
. (Join-Path $repoRoot 'src\sync\Invoke-LibraryRetention.ps1')
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

$state = Get-RipperLibrarySyncState -LibraryRoot $LibraryRoot
if ($state.Count -eq 0) {
    Write-Host "sync-state.json is empty -- nothing to retry." -ForegroundColor Yellow
    Stop-RipperLog
    return
}

# Pre-load discids.json once for the DiscId lookup. Each entry on
# sync-state.json carries its own DiscId so this is best-effort fallback.
$discIndex = $null
try {
    $discIndex = Get-RipperLibraryDiscIndex -LibraryRoot $LibraryRoot
} catch {
    Write-RipperLog WARN 'SyncPending' "Could not load discids.json: $($_.Exception.Message). Will rely on sync-state DiscId."
}

function Test-RipperEntryNeedsRetry {
    param([object]$Entry, [string[]]$Targets)
    foreach ($name in $Targets) {
        if (-not $Entry.Targets.PSObject.Properties[$name]) { return $true }
        if ([string]$Entry.Targets.$name.Status -ne 'OK')   { return $true }
    }
    $false
}

$plan = @()
foreach ($key in $state.Keys) {
    $entry = $state[$key]
    if ($Force) {
        $plan += [pscustomobject]@{ Key=$key; Entry=$entry }
        continue
    }
    if (Test-RipperEntryNeedsRetry -Entry $entry -Targets $configuredTargets) {
        $plan += [pscustomobject]@{ Key=$key; Entry=$entry }
    }
}

if ($plan.Count -eq 0) {
    Write-Host "All sync-state entries are already OK against [$($configuredTargets -join ', ')]." -ForegroundColor Green
    Stop-RipperLog
    return
}

Write-Host ''
Write-Host "Pending albums:" -ForegroundColor Cyan
foreach ($p in $plan) {
    $names = @()
    foreach ($n in $configuredTargets) {
        $st = if ($p.Entry.Targets.PSObject.Properties[$n]) { [string]$p.Entry.Targets.$n.Status } else { 'missing' }
        $names += "$n=$st"
    }
    Write-Host "  $($p.Key)   [$($names -join ', ')]"
}
Write-Host ''

$failedAny = $false
$successCount = 0
foreach ($p in $plan) {
    $key   = $p.Key
    $entry = $p.Entry
    $abs   = Join-Path $LibraryRoot ($key -replace '/','\')

    if (-not (Test-Path -LiteralPath $abs -PathType Container)) {
        Write-RipperLog WARN 'SyncPending' "Skipping '$key' -- folder is gone (moved/recycled by user). Nothing to sync."
        continue
    }

    $discId = ''
    if ($entry.PSObject.Properties['DiscId'] -and $entry.DiscId) {
        $discId = [string]$entry.DiscId
    }
    if (-not $discId -and $discIndex) {
        # Best-effort: scan discids.json for a matching path.
        foreach ($d in $discIndex.Keys) {
            if ([string]$discIndex[$d].Path -eq $abs) { $discId = $d; break }
        }
    }
    if (-not $discId) {
        # Synthesize a placeholder so Invoke-RipperSync's Mandatory
        # parameter is satisfied. Sync-state will keep the empty string;
        # this only happens for entries that were already missing one.
        $discId = ''
    }

    if (-not $PSCmdlet.ShouldProcess($abs, "Re-run sync to [$($configuredTargets -join ', ')]")) {
        continue
    }

    Write-Host ("Syncing: {0}" -f $key) -ForegroundColor White
    $sync = $null
    try {
        $sync = Invoke-RipperSync -AlbumPath $abs -LibraryRoot $LibraryRoot -DiscId $discId -Config $cfg
    } catch {
        Write-RipperLog WARN 'SyncPending' "Sync orchestrator threw for '$key' (non-fatal): $($_.Exception.Message)"
        $failedAny = $true
        continue
    }

    if (-not $sync -or $sync.Skipped) {
        # Skipped here means SyncTargets emptied between the early check
        # and now -- shouldn't happen in practice.
        continue
    }

    if ($sync.AllOk) {
        $successCount++
        Write-Host "  -> OK" -ForegroundColor Green
        # Apply retention policy now that the album is fully synced.
        try {
            Invoke-RipperLibraryRetention `
                -AlbumPath   $abs `
                -LibraryRoot $LibraryRoot `
                -Config      $cfg `
                -SyncResult  $sync `
                -DiscId      $discId | Out-Null
        } catch {
            Write-RipperLog WARN 'SyncPending' "Retention threw for '$key' (non-fatal): $($_.Exception.Message)"
        }
    } else {
        $failedAny = $true
        $bad = ($sync.Targets | Where-Object { $_.Status -ne 'OK' } | ForEach-Object { "$($_.Target)=$($_.Status)" }) -join ', '
        Write-Host "  -> still failing: $bad" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host ("Done. Restored to OK: {0}. See {1} for details." -f $successCount, (Get-RipperLogPath)) -ForegroundColor Cyan
Stop-RipperLog

if ($failedAny) { exit 1 } else { exit 0 }
