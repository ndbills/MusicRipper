<#
.SYNOPSIS
    Phase 6.1: apply the LocalRetention policy to a freshly-synced album.

.DESCRIPTION
    Called from Invoke-RipperPostProcess AFTER Invoke-RipperSync, only
    on Library-bound rips (review-queue items are drafts and never
    eligible for retention).

    `cfg.LocalRetention` modes:
      - 'Keep'                       : do nothing. Default for safety
                                       on existing installs.
      - 'MoveToSentAfterAllSynced'   : when every configured target
                                       returned OK, move the album
                                       folder to <LibraryRoot>\_Sent\
                                       preserving the artist subdir.
      - 'RecycleAfterAllSynced'      : when every configured target
                                       returned OK, send the album
                                       folder to the Windows Recycle
                                       Bin (recoverable via
                                       Move-RipperFolderToRecycleBin
                                       -- the same primitive D-021's
                                       "Discard" button uses).

    Behaviour when no targets are configured (`SyncResult.Skipped`):
      retention is a no-op regardless of mode. We must never move /
      recycle a local album that has not actually been pushed
      somewhere.

    Behaviour when one or more targets failed:
      retention is a no-op (we wait for `Sync-PendingAlbums.ps1` to
      retry, then a future cycle will retry retention).

    On success, side-effects:
      - For MoveToSentAfterAllSynced: also rewrites the discids.json
        entry's Path to the new _Sent location so the duplicate-disc
        dialog still finds it on re-insert (Phase 5.8 contract).
      - For RecycleAfterAllSynced: removes the discids.json entry so
        a later disc re-insert isn't flagged as a duplicate against a
        path that no longer exists. Sync-state.json keeps the history
        record indefinitely.

    Returns a hashtable describing what happened:
        @{
            Action      = 'None' | 'MovedToSent' | 'Recycled'
            Reason      = <string>           # why None, when None
            NewPath     = <string|null>      # set for MovedToSent
        }
#>

Set-StrictMode -Version 3.0


function Invoke-RipperLibraryRetention {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$AlbumPath,
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [object]$Config,
        [Parameter(Mandatory)] [object]$SyncResult,
        [Parameter()]          [string]$DiscId
    )

    $mode = if ($Config.PSObject.Properties['LocalRetention']) { [string]$Config.LocalRetention } else { 'Keep' }
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'Keep' }

    if ($mode -eq 'Keep') {
        return @{ Action='None'; Reason='LocalRetention=Keep'; NewPath=$null }
    }
    if ($SyncResult.Skipped) {
        Write-RipperLog INFO 'Retention' "LocalRetention=$mode but no targets configured; keeping local copy."
        return @{ Action='None'; Reason='No sync targets configured'; NewPath=$null }
    }
    if (-not $SyncResult.AllOk) {
        $failed = ($SyncResult.Targets | Where-Object { $_.Status -ne 'OK' } | ForEach-Object { $_.Target }) -join ', '
        Write-RipperLog INFO 'Retention' "LocalRetention=$mode but target(s) [$failed] not OK; keeping local copy for retry."
        return @{ Action='None'; Reason="Targets not OK: $failed"; NewPath=$null }
    }

    switch ($mode) {
        'MoveToSentAfterAllSynced' {
            $rel       = ConvertTo-RipperLibraryRelativeKey -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
            $sentRoot  = Join-Path $LibraryRoot '_Sent'
            $newPath   = Join-Path $sentRoot ($rel.Replace('/','\'))
            $newParent = Split-Path -Parent $newPath

            if (Test-Path -LiteralPath $newPath) {
                # Side-by-side land in _Sent the same way they live in
                # the active library: append a [moved N] discriminator.
                $i = 2
                do {
                    $candidate = "$newPath [moved $i]"
                    $i++
                } while (Test-Path -LiteralPath $candidate)
                $newPath = $candidate
                $newParent = Split-Path -Parent $newPath
                Write-RipperLog INFO 'Retention' "_Sent collision; using '$newPath'."
            }
            if (-not (Test-Path -LiteralPath $newParent)) {
                New-Item -ItemType Directory -Path $newParent -Force | Out-Null
            }
            Move-Item -LiteralPath $AlbumPath -Destination $newPath -Force
            Write-RipperLog INFO 'Retention' "Moved '$AlbumPath' to '_Sent\' at '$newPath'."

            Set-RipperLibraryRetentionApplied `
                -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath `
                -Action 'MoveToSentAfterAllSynced' -NewPath $newPath

            # Best-effort: rewrite the discids.json entry's Path so the
            # cross-session duplicate-disc dialog still resolves on
            # re-insert. If it fails (concurrent NAS hiccup, missing
            # entry), the album's still safely in _Sent.
            if ($DiscId) {
                try {
                    $libIdxFn = Get-Command -Name Add-RipperLibraryDiscIndexEntry -ErrorAction SilentlyContinue
                    if ($libIdxFn) {
                        $existing = Find-RipperLibraryDiscIndexEntry -LibraryRoot $LibraryRoot -DiscId $DiscId
                        $label    = if ($existing -and $existing.PSObject.Properties['Label']) { [string]$existing.Label } else { '' }
                        Add-RipperLibraryDiscIndexEntry `
                            -LibraryRoot $LibraryRoot -DiscId $DiscId `
                            -Path $newPath -Label $label -Source 'sent' | Out-Null
                    }
                } catch {
                    Write-RipperLog WARN 'Retention' "Failed to rewrite discids.json after _Sent move: $($_.Exception.Message)"
                }
            }

            return @{ Action='MovedToSent'; Reason='All targets OK'; NewPath=$newPath }
        }
        'RecycleAfterAllSynced' {
            # Move-RipperFolderToRecycleBin is defined in
            # src/ui/Show-TargetExistsDialog.ps1 (Phase 5.11). Both
            # files are dot-sourced by Start-Ripper.ps1 before this
            # function runs.
            $cmd = Get-Command -Name Move-RipperFolderToRecycleBin -ErrorAction SilentlyContinue
            if (-not $cmd) {
                Write-RipperLog WARN 'Retention' 'Move-RipperFolderToRecycleBin not loaded; falling back to Keep.'
                return @{ Action='None'; Reason='Recycle helper not loaded'; NewPath=$null }
            }
            & $cmd -Path $AlbumPath
            Write-RipperLog INFO 'Retention' "Recycled '$AlbumPath'."

            Set-RipperLibraryRetentionApplied `
                -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath `
                -Action 'RecycleAfterAllSynced'

            # Discard the discids.json entry: the path no longer exists.
            # Sync-state.json keeps the durable record (DiscId field +
            # RetentionApplied marker).
            if ($DiscId) {
                try {
                    $idxPath = Get-RipperLibraryDiscIndexPath -LibraryRoot $LibraryRoot
                    if (Test-Path -LiteralPath $idxPath) {
                        $idx = Get-RipperLibraryDiscIndex -LibraryRoot $LibraryRoot
                        if ($idx.ContainsKey($DiscId)) {
                            $idx.Remove($DiscId) | Out-Null
                            $payload = [ordered]@{}
                            foreach ($k in ($idx.Keys | Sort-Object)) { $payload[$k] = $idx[$k] }
                            $json = ($payload | ConvertTo-Json -Depth 5)
                            $tmp  = "$idxPath.tmp"
                            Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -NoNewline
                            Move-Item -LiteralPath $tmp -Destination $idxPath -Force
                        }
                    }
                } catch {
                    Write-RipperLog WARN 'Retention' "Failed to prune discids.json after Recycle: $($_.Exception.Message)"
                }
            }

            return @{ Action='Recycled'; Reason='All targets OK'; NewPath=$null }
        }
        default {
            Write-RipperLog WARN 'Retention' "Unknown LocalRetention mode '$mode'; treating as Keep."
            return @{ Action='None'; Reason="Unknown mode '$mode'"; NewPath=$null }
        }
    }
}
