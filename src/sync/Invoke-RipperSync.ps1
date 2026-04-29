<#
.SYNOPSIS
    Phase 6.1: per-album sync orchestrator + the built-in "Stub" target.

.DESCRIPTION
    Iterates `Config.SyncTargets` (an ordered list of names like
    'Stub', 'OneDrive', 'SynologyNAS') and dispatches each to its
    matching `Invoke-RipperSyncTo<Name>` function. Each target returns
    a fixed-shape hashtable:

        @{
            Target      = '<Name>'
            Status      = 'OK' | 'Failed' | 'Skipped'
            BytesCopied = <int64>
            Diagnostic  = <string|null>
        }

    Failures NEVER throw out of the orchestrator -- every target is
    wrapped in try/catch so one broken target can't block another.
    The album stays in the local library; the sync-state index records
    the failure; `src/tools/Sync-PendingAlbums.ps1` (Phase 6.2) will
    let the user retry.

    The orchestrator is a no-op (returns AllOk=$true, Targets=@()) when
    `Config.SyncTargets` is empty or missing -- which is the default.
    Existing installs without the field see exactly today's behaviour.

    Adding a real target (Phase 6.2 OneDrive, 6.3 SynologyNAS):
      1. Create `src/sync/Sync-To<Name>.ps1` with one function
         `Invoke-RipperSyncTo<Name> -AlbumPath -LibraryRoot -Config`.
      2. Dot-source it next to this file in `Start-Ripper.ps1`.
      3. Document it in `docs/SYNC-TARGETS.md` and the
         `cfg.SyncTargets` comment in `config/config.template.json`.
      4. Add a top-up entry in `setup/New-RipperConfig.ps1` so users
         can opt in.

.NOTES
    Per-target invocations are sequential (not parallel). For Phase
    6.1's Stub target this is trivial; Phase 6.2+ may revisit if
    multi-target sync feels slow in practice. Keep It Simple wins.
#>

Set-StrictMode -Version 3.0


function Invoke-RipperSyncToStub {
<#
.SYNOPSIS
    Built-in test sync target. Writes a marker file under
    `<LibraryRoot>\.musicripper\stub-sync\<RelKey>\.synced` and reports
    OK. Used by Pester to exercise the orchestrator end-to-end without
    touching OneDrive / SMB / VPN. Documented (not hidden) so users can
    use it themselves to dry-run the framework before configuring a
    real target.

    Honours `cfg.StubSyncFail` (boolean, default false) -- when true,
    returns Failed instead, for testing the failure path.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$AlbumPath,
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [object]$Config
    )

    if ($Config.PSObject.Properties['StubSyncFail'] -and [bool]$Config.StubSyncFail) {
        return @{
            Target      = 'Stub'
            Status      = 'Failed'
            BytesCopied = 0
            Diagnostic  = 'StubSyncFail=true (requested failure for testing)'
        }
    }

    $key  = ConvertTo-RipperLibraryRelativeKey -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
    $base = Join-Path (Join-Path $LibraryRoot '.musicripper') 'stub-sync'
    $dest = Join-Path $base $key.Replace('/','\')
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }

    $marker = Join-Path $dest '.synced'
    $stamp  = [DateTime]::UtcNow.ToString('o')
    Set-Content -LiteralPath $marker -Value "Stub sync marker for $key at $stamp" -Encoding UTF8

    # Best-effort byte count of the source album for reporting parity
    # with future real targets.
    $bytes = 0L
    try {
        $bytes = (Get-ChildItem -LiteralPath $AlbumPath -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { $bytes = 0L }
    } catch { $bytes = 0L }

    @{
        Target      = 'Stub'
        Status      = 'OK'
        BytesCopied = [int64]$bytes
        Diagnostic  = $null
    }
}


function Invoke-RipperSync {
<#
.SYNOPSIS
    Run every configured sync target against one album folder.

.DESCRIPTION
    Returns:
        @{
            AlbumPath = <abs>
            Targets   = @( <one per-target result hashtable> )
            AllOk     = <bool, true iff every configured target said OK>
            Skipped   = <bool, true iff no targets were configured>
        }

    `Skipped=true` distinguishes "no sync was attempted" from
    "every sync succeeded" so the retention layer doesn't move/recycle
    a folder that hasn't actually been pushed anywhere.

    Per-target result is also persisted to `sync-state.json` via
    `Set-RipperLibrarySyncTargetResult`. Persist failures are logged
    WARN (do not throw) -- the in-memory result is the source of truth
    for what the caller sees.

.PARAMETER AlbumPath
    Absolute path to the album folder that just landed in the library.

.PARAMETER LibraryRoot
    Absolute path to the library root (used to compute the relative
    key + locate the sync-state index).

.PARAMETER DiscId
    DiscId of the rip; recorded on the sync-state entry the first time
    we see this album so a future cross-reference (e.g. recovering
    after a wipe) can map back to the disc.

.PARAMETER Config
    The loaded MusicRipper config object. The orchestrator reads
    `Config.SyncTargets` and forwards `Config` whole-cloth to each
    target so per-target settings live alongside the rest.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$AlbumPath,
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [object]$Config
    )

    $names = @()
    if ($Config.PSObject.Properties['SyncTargets'] -and $Config.SyncTargets) {
        $names = @($Config.SyncTargets | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($names.Count -eq 0) {
        Write-RipperLog INFO 'Sync' 'No sync targets configured -- skipping.'
        return @{
            AlbumPath = $AlbumPath
            Targets   = @()
            AllOk     = $true
            Skipped   = $true
        }
    }

    Write-RipperLog INFO 'Sync' "Syncing '$AlbumPath' to: $($names -join ', ')"

    $results = @()
    foreach ($name in $names) {
        $fnName = "Invoke-RipperSyncTo$name"
        $cmd    = Get-Command -Name $fnName -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Write-RipperLog WARN 'Sync' "Unknown sync target '$name' (no function $fnName); marking Failed."
            $r = @{
                Target      = $name
                Status      = 'Failed'
                BytesCopied = 0
                Diagnostic  = "Unknown sync target '$name' (no function $fnName loaded)."
            }
        } else {
            try {
                $r = & $cmd -AlbumPath $AlbumPath -LibraryRoot $LibraryRoot -Config $Config
                if (-not $r) { throw "Target '$name' returned `$null." }
                # Normalize pscustomobject -> hashtable so the rest of
                # the pipeline (and the persisted JSON) has a single
                # uniform shape.
                if ($r -isnot [System.Collections.IDictionary]) {
                    $norm = @{}
                    foreach ($p in $r.PSObject.Properties) { $norm[$p.Name] = $p.Value }
                    $r = $norm
                }
                if (-not $r.Contains('Status')) {
                    throw "Target '$name' returned no Status field."
                }
                # Force the Target field to match the configured name
                # so a sloppy target can't claim to be something else.
                $r['Target'] = $name
            } catch {
                Write-RipperLog ERROR 'Sync' "Target '$name' threw: $($_.Exception.Message)"
                $r = @{
                    Target      = $name
                    Status      = 'Failed'
                    BytesCopied = 0
                    Diagnostic  = $_.Exception.Message
                }
            }
        }

        # WARN when a target failed so the parent-user sees yellow
        # output even with the host window minimized. INFO otherwise.
        $level = if ($r.Status -eq 'Failed') { 'WARN' } else { 'INFO' }
        Write-RipperLog $level 'Sync' "Target '$name': Status=$($r.Status) Bytes=$($r.BytesCopied)$(if ($r.Diagnostic) { " Diag=$($r.Diagnostic)" })"

        # Persist best-effort. A flaky NAS write must not derail a
        # successful sync return.
        try {
            Set-RipperLibrarySyncTargetResult `
                -LibraryRoot $LibraryRoot `
                -AlbumPath   $AlbumPath `
                -DiscId      $DiscId `
                -Result      $r | Out-Null
        } catch {
            Write-RipperLog WARN 'Sync' "Failed to persist sync-state for '$name': $($_.Exception.Message)"
        }

        $results += ,$r
    }

    # Wrap the Where-Object pipe in @(...) so an empty result still
    # exposes .Count (StrictMode 3.0 throws on $null.Count otherwise).
    $allOk = @($results | Where-Object { $_.Status -ne 'OK' }).Count -eq 0
    @{
        AlbumPath = $AlbumPath
        Targets   = $results
        AllOk     = $allOk
        Skipped   = $false
    }
}
