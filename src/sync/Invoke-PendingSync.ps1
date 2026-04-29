<#
.SYNOPSIS
    Phase 6.5: pure-logic core of the "retry pending syncs" loop --
    callable both from the headless `tools/Sync-PendingAlbums.ps1`
    CLI and from the WPF startup-resync UI.

.DESCRIPTION
    Walks `<LibraryRoot>\.musicripper\sync-state.json`, finds entries
    where any configured target is not 'OK' (or every entry when
    -Force), and re-invokes `Invoke-RipperSync` against each album
    folder. Successful retries trigger `Invoke-RipperLibraryRetention`
    so a `MoveToSentAfterAllSynced` / `RecycleAfterAllSynced` policy
    finally fires.

    Behavioural contract carried over verbatim from the long-standing
    `Sync-PendingAlbums.ps1`:
      - Skip albums whose folder is gone (warn).
      - Skip _Sent\ rows (Source='sent').
      - Prune Targets.<name> entries no longer in cfg.SyncTargets.

    Adds two things on top of that contract that the CLI never needed
    but the WPF UI does:

      -ProgressCallback   scriptblock invoked at the boundaries of
                          every album so the UI can advance two
                          progress bars (per-album + overall) and a
                          status line. Signature:
                            param(
                              [string]$Phase,           # 'plan' | 'album-start' |
                                                        # 'album-end'   | 'done'
                              [int]$AlbumIdx,           # 1-based, 0 outside loop
                              [int]$AlbumTotal,         # total in plan
                              [string]$AlbumKey,        # rel-key
                              [string]$AlbumLabel,      # human label
                              [string]$ResultStatus,    # 'OK'|'PartiallyFailed'|
                                                        # 'Cancelled'|''
                              [object]$ResultDetail     # for the detail panel
                            )
                          Errors swallowed.

      -CancelRequested    scriptblock returning [bool]. Polled
                          before each album. If it ever returns
                          $true we stop ASAP, do NOT start any
                          further albums, and return with
                          PartiallyFailed status. The CURRENTLY
                          IN-FLIGHT album is allowed to finish so
                          we don't strand a half-copied robocopy.
                          (Killing robocopy mid-flight would just
                          leave a partial file that the next sync
                          would re-copy; the right place for that
                          is inside the sync target itself, not
                          here.)

    Returns a hashtable summary suitable for both the CLI's exit-code
    branching and the UI's summary panel:

      @{
        Total      = int   # entries in plan
        Synced     = int   # AllOk after retry
        StillFailing = int
        Skipped    = int   # folder gone / no targets
        Cancelled  = bool
        Albums     = [object[]] @(@{Key;Label;Status;FailedTargets;Diagnostic};...)
      }

    `Status` per album is one of: 'OK', 'StillFailing', 'Skipped'.

.NOTES
    The tool script `src/tools/Sync-PendingAlbums.ps1` becomes a thin
    Console-based wrapper around this function that prints to stdout
    via -ProgressCallback. Tests in
    `tests/Invoke-PendingSync.Tests.ps1` exercise the function
    directly with mocked Invoke-RipperSync / Invoke-RipperLibraryRetention.
#>

Set-StrictMode -Version 3.0


function Get-RipperPendingSyncPlan {
<#
.SYNOPSIS
    Pure-logic helper: given a sync-state hashtable + the configured
    targets, return the ordered list of (Key, Entry) pairs that need
    a retry. Also strips Targets.<name> entries that are no longer
    configured (caller persists if any pruning happened).

.OUTPUTS
    Hashtable @{ Plan = [object[]] @({Key;Entry};...); Pruned = [bool] }
    Pruned indicates whether the caller should Save-RipperLibrarySyncState
    to persist the cleanup.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$State,
        [Parameter(Mandatory)] [string[]]$ConfiguredTargets,
        [switch]$Force
    )

    $pruned = $false
    foreach ($key in @($State.Keys)) {
        $entry = $State[$key]
        if (-not $entry.PSObject.Properties['Targets'] -or -not $entry.Targets) { continue }
        $stale = @()
        foreach ($p in $entry.Targets.PSObject.Properties) {
            if ($ConfiguredTargets -notcontains $p.Name) { $stale += $p.Name }
        }
        foreach ($n in $stale) {
            $entry.Targets.PSObject.Properties.Remove($n)
            $pruned = $true
        }
    }

    $plan = @()
    foreach ($key in $State.Keys) {
        $entry = $State[$key]
        $needs = $false
        if ($Force) {
            $needs = $true
        } else {
            foreach ($name in $ConfiguredTargets) {
                if (-not $entry.Targets.PSObject.Properties[$name]) { $needs = $true; break }
                if ([string]$entry.Targets.$name.Status -ne 'OK')   { $needs = $true; break }
            }
        }
        if ($needs) {
            $plan += [pscustomobject]@{ Key = $key; Entry = $entry }
        }
    }

    return @{ Plan = $plan; Pruned = $pruned }
}


function Invoke-RipperPendingSync {
<#
.SYNOPSIS
    Retry every album whose sync-state record is not "all targets OK"
    against the currently configured `cfg.SyncTargets`.

.PARAMETER LibraryRoot
    Library root containing `.musicripper\sync-state.json`.

.PARAMETER Config
    Loaded ripper config object (`Import-RipperConfig`). Reads
    `cfg.SyncTargets`.

.PARAMETER Force
    Retry every entry, not just the ones with a non-OK target.

.PARAMETER ProgressCallback
    Optional scriptblock; see file header for signature.

.PARAMETER CancelRequested
    Optional scriptblock; see file header.

.PARAMETER DiscIndex
    Optional pre-loaded discids.json hashtable. Used as fallback for
    sync-state entries missing their own DiscId. Tests pass this
    explicitly to avoid touching disk.

.OUTPUTS
    See file header.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [object]$Config,
        [switch]$Force,
        [scriptblock]$ProgressCallback,
        [scriptblock]$CancelRequested,
        [hashtable]$DiscIndex
    )

    $emit = {
        param($Phase, $AlbumIdx, $AlbumTotal, $AlbumKey, $AlbumLabel, $ResultStatus, $ResultDetail)
        if ($ProgressCallback) {
            try { & $ProgressCallback $Phase $AlbumIdx $AlbumTotal $AlbumKey $AlbumLabel $ResultStatus $ResultDetail } catch { }
        }
    }.GetNewClosure()
    $cancelled = {
        if (-not $CancelRequested) { return $false }
        try { return [bool](& $CancelRequested) } catch { return $false }
    }.GetNewClosure()

    $configuredTargets = @()
    if ($Config.PSObject.Properties['SyncTargets'] -and $Config.SyncTargets) {
        $configuredTargets = @($Config.SyncTargets | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($configuredTargets.Count -eq 0) {
        & $emit 'done' 0 0 '' '' '' $null
        return @{ Total=0; Synced=0; StillFailing=0; Skipped=0; Cancelled=$false; Albums=@() }
    }

    $state = Get-RipperLibrarySyncState -LibraryRoot $LibraryRoot
    if ($state.Count -eq 0) {
        & $emit 'done' 0 0 '' '' '' $null
        return @{ Total=0; Synced=0; StillFailing=0; Skipped=0; Cancelled=$false; Albums=@() }
    }

    $planResult = Get-RipperPendingSyncPlan -State $state -ConfiguredTargets $configuredTargets -Force:$Force
    $plan       = @($planResult.Plan)

    if ($planResult.Pruned) {
        try {
            Save-RipperLibrarySyncState -LibraryRoot $LibraryRoot -Index $state
        } catch {
            Write-RipperLog WARN 'PendingSync' "Failed to persist sync-state after prune: $($_.Exception.Message)"
        }
    }

    & $emit 'plan' 0 $plan.Count '' '' '' $plan

    if ($plan.Count -eq 0) {
        & $emit 'done' 0 0 '' '' '' $null
        return @{ Total=0; Synced=0; StillFailing=0; Skipped=0; Cancelled=$false; Albums=@() }
    }

    # Best-effort pre-load of discids.json for the DiscId fallback.
    if (-not $DiscIndex) {
        try {
            $DiscIndex = Get-RipperLibraryDiscIndex -LibraryRoot $LibraryRoot
        } catch {
            Write-RipperLog WARN 'PendingSync' "Could not load discids.json: $($_.Exception.Message). Will rely on sync-state DiscId."
            $DiscIndex = $null
        }
    }

    $results      = @()
    $synced       = 0
    $stillFailing = 0
    $skipped      = 0
    $wasCancelled = $false
    $idx          = 0

    foreach ($p in $plan) {
        $idx++
        $key   = $p.Key
        $entry = $p.Entry
        $abs   = Join-Path $LibraryRoot ($key -replace '/','\')

        # Best human label: discids.json Label if present, else key.
        $label = $key
        if ($entry.PSObject.Properties['DiscId'] -and $entry.DiscId -and $DiscIndex -and $DiscIndex.ContainsKey([string]$entry.DiscId)) {
            $idxRow = $DiscIndex[[string]$entry.DiscId]
            if ($idxRow.PSObject.Properties['Label'] -and $idxRow.Label) {
                $label = [string]$idxRow.Label
            }
        }

        if (& $cancelled) {
            $wasCancelled = $true
            & $emit 'done' $idx $plan.Count $key $label 'Cancelled' $null
            break
        }

        if (-not (Test-Path -LiteralPath $abs -PathType Container)) {
            Write-RipperLog WARN 'PendingSync' "Skipping '$key' -- folder is gone (moved/recycled by user). Nothing to sync."
            $skipped++
            $results += [pscustomobject]@{
                Key=$key; Label=$label; Status='Skipped'
                FailedTargets=@(); Diagnostic='Folder no longer on disk.'
            }
            & $emit 'album-end' $idx $plan.Count $key $label 'Skipped' $null
            continue
        }

        & $emit 'album-start' $idx $plan.Count $key $label '' $null

        $discId = ''
        if ($entry.PSObject.Properties['DiscId'] -and $entry.DiscId) {
            $discId = [string]$entry.DiscId
        }
        if (-not $discId -and $DiscIndex) {
            foreach ($d in $DiscIndex.Keys) {
                if ([string]$DiscIndex[$d].Path -eq $abs) { $discId = $d; break }
            }
        }

        if (-not $PSCmdlet.ShouldProcess($abs, "Retry sync to [$($configuredTargets -join ', ')]")) {
            $skipped++
            & $emit 'album-end' $idx $plan.Count $key $label 'Skipped' $null
            continue
        }

        $sync = $null
        try {
            $sync = Invoke-RipperSync -AlbumPath $abs -LibraryRoot $LibraryRoot -DiscId $discId -Config $Config
        } catch {
            Write-RipperLog WARN 'PendingSync' "Sync orchestrator threw for '$key' (non-fatal): $($_.Exception.Message)"
            $stillFailing++
            $row = [pscustomobject]@{
                Key=$key; Label=$label; Status='StillFailing'
                FailedTargets=@($configuredTargets); Diagnostic=$_.Exception.Message
            }
            $results += $row
            & $emit 'album-end' $idx $plan.Count $key $label 'PartiallyFailed' $row
            continue
        }

        if (-not $sync -or $sync.Skipped) {
            $skipped++
            & $emit 'album-end' $idx $plan.Count $key $label 'Skipped' $null
            continue
        }

        if ($sync.AllOk) {
            $synced++
            try {
                Invoke-RipperLibraryRetention `
                    -AlbumPath   $abs `
                    -LibraryRoot $LibraryRoot `
                    -Config      $Config `
                    -SyncResult  $sync `
                    -DiscId      $discId | Out-Null
            } catch {
                Write-RipperLog WARN 'PendingSync' "Retention threw for '$key' (non-fatal): $($_.Exception.Message)"
            }
            $row = [pscustomobject]@{
                Key=$key; Label=$label; Status='OK'
                FailedTargets=@(); Diagnostic=''
            }
            $results += $row
            & $emit 'album-end' $idx $plan.Count $key $label 'OK' $row
        } else {
            $stillFailing++
            $bad = @($sync.Targets | Where-Object { $_.Status -ne 'OK' })
            $diag = ($bad | ForEach-Object { "$($_.Target)=$($_.Status): $($_.Diagnostic)" }) -join '; '
            $row = [pscustomobject]@{
                Key=$key; Label=$label; Status='StillFailing'
                FailedTargets=@($bad | ForEach-Object { $_.Target })
                Diagnostic=$diag
            }
            $results += $row
            & $emit 'album-end' $idx $plan.Count $key $label 'PartiallyFailed' $row
        }
    }

    & $emit 'done' $plan.Count $plan.Count '' '' '' $null

    return @{
        Total        = $plan.Count
        Synced       = $synced
        StillFailing = $stillFailing
        Skipped      = $skipped
        Cancelled    = $wasCancelled
        Albums       = $results
    }
}
