# Sync targets

> **Status:** Phase 6.1 framework + 6.2 OneDrive target + 6.3 Synology NAS target shipped.
> Phase 6.4 ships the same SynologyNAS target accessed over WireGuard
> (no code change — just a setup-doc addition).
> Background: [DECISIONS.md D-022](DECISIONS.md), [D-023](DECISIONS.md), [D-024](DECISIONS.md).

## What sync does, in one paragraph

After a successful rip lands in the local library, MusicRipper walks
the ordered list `cfg.SyncTargets` and pushes the album folder to each
target in turn. Targets are best-effort: a failure is logged, recorded
in `<LibraryRoot>\.musicripper\sync-state.json`, and **never blocks the
rip**. Once *every* configured target reports `OK`, the local-retention
rule (`cfg.LocalRetention`) fires — keep the local copy as-is, move it
into a `_Sent\` shadow tree, or send it to the Recycle Bin.

The local library is always the source of truth at the moment a rip
finishes. Sync is layered on top.

## Configuration

Two fields in `%LOCALAPPDATA%\MusicRipper\config.json`:

```jsonc
{
  // Ordered list of target names. Empty = no sync (default).
  "SyncTargets": ["Stub"],

  // What to do with the local copy once every target says OK.
  // One of: "Keep" | "MoveToSentAfterAllSynced" | "RecycleAfterAllSynced"
  "LocalRetention": "Keep"
}
```

`setup/New-RipperConfig.ps1` prompts for both during interactive
top-up; existing installs default to `[]` / `"Keep"` and behave
exactly as before.

### Built-in targets

| Name       | Purpose                                                                 |
| ---------- | ----------------------------------------------------------------------- |
| `Stub`     | Writes a marker file under `.musicripper\stub-sync\<rel>\.synced`. Honours `cfg.StubSyncFail = true` for failure-path testing. Use it to dry-run the framework before configuring a real target. |
| `OneDrive` | Phase 6.2: copies the album folder via `robocopy` into `cfg.OneDriveSyncTargetRoot` (a folder inside the user's OneDrive). Files appear in the OneDrive client's pending list and upload in the background. Pre-flight checks: OneDrive client installed (registry), target root exists. See [DECISIONS.md D-023](DECISIONS.md) for the robocopy switch rationale. |
| `SynologyNAS` | Phase 6.3: copies the album folder via `robocopy` onto `cfg.SynologyUnc` (typically a Synology DSM Shared Folder, but any UNC server works). When `cfg.HasSynologyCredential = $true`, the share root is mounted via `New-SmbMapping` for the duration of each album sync using a DPAPI-protected `PSCredential` from `credentials.clixml`; otherwise the sync uses ambient session credentials. Adds robocopy `/Z` (restartable) + `/R:5 /W:10` to weather flaky home networks. Pre-flight checks: `SynologyUnc` set, credential decrypts (when required), share reachable. The Settings editor refuses to Save when `SynologyNAS` is in `SyncTargets` but no credential is stored -- the parent-friendly failure mode is "can't save" rather than "saves but every sync fails with a misleading `not reachable` message." See [DECISIONS.md D-024](DECISIONS.md) for the auth model rationale. |

Phase 6.4 reuses the `SynologyNAS` target unchanged over WireGuard
(setup-doc addition only).

Phase 6.4.2 adds **direct-first NAS sync**: when WireGuard auto-toggle
is configured, MusicRipper probes the share's server on TCP/445
(~2s timeout) before each sync. If the share answers directly (you're
on the home LAN), the tunnel is NOT brought up and robocopy goes over
the LAN; if the probe fails, MusicRipper falls back to bringing the
tunnel up. Controlled by `cfg.PreferDirectNasConnection` (default
`$true`) -- toggle off in Settings → WireGuard if you want the tunnel
to always be used. See [DECISIONS.md D-031](DECISIONS.md).

### Retention modes

| Mode                          | Behaviour                                                                                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Keep` (default)              | Do nothing. The album stays in the library forever. Safe choice when you don't have an off-box backup yet.                                        |
| `MoveToSentAfterAllSynced`    | Move the album folder to `<LibraryRoot>\_Sent\<Artist>\<Album>\`. The `discids.json` entry is rewritten to point at the new path with `Source='sent'` so duplicate detection still works on later inserts. |
| `RecycleAfterAllSynced`       | Send the album folder to the Recycle Bin via the same helper as the target-exists "Discard" button (D-021). The `discids.json` entry is rewritten with `Source='recycled'` so re-inserting the same disc still trips the duplicate-disc dialog -- the dialog hides its Open-folder button (the local copy is intentionally gone) and shows a small note explaining the situation. |

Retention only fires when `Invoke-RipperSync` returns `AllOk = $true`
**and** `Skipped = $false` — i.e. at least one target was attempted
and every attempted target reported `OK`. A target that fails will
keep the album in the library until the user re-runs sync or fixes
the target.

## Sync-state index

Path: `<LibraryRoot>\.musicripper\sync-state.json`

```jsonc
{
  "Mannheim Steamroller/Christmas (1984)": {
    "DiscId":      "Wk6...",
    "FirstSeenAt": "2026-04-26T14:00:00Z",
    "Targets": {
      "OneDrive":    { "Status": "OK",     "SyncedAt": "...", "BytesCopied": 123456, "Diagnostic": null },
      "SynologyNAS": { "Status": "Failed", "SyncedAt": null,  "BytesCopied": 0,      "Diagnostic": "VPN tunnel down" }
    },
    "RetentionApplied": {
      "Action":    "Keep",
      "Reason":    "LocalRetention=Keep",
      "AppliedAt": "2026-04-26T14:00:05Z",
      "NewPath":   null
    }
  }
}
```

`RetentionApplied` is stamped on every retention decision the
pipeline makes, **including no-ops**. Possible `Action` values:

| Action                       | Meaning                                                                        |
|------------------------------|--------------------------------------------------------------------------------|
| `Keep`                       | `LocalRetention=Keep`, all targets OK. Local copy intentionally left in place. |
| `KeepTargetsNotOk`           | A move/recycle was requested but at least one target failed; album held for retry. `Reason` lists the failed target names. |
| `MoveToSentAfterAllSynced`   | Album moved to `<LibraryRoot>\_Sent\…`. `NewPath` records where.               |
| `RecycleAfterAllSynced`      | Album sent to the Windows Recycle Bin. `NewPath` is `null`.                    |

A `null` `RetentionApplied` therefore means *retention has not run
yet* for this album (e.g. the rip predates Phase 6.1 or the
post-process step has not reached the retention call). It is a
useful diagnostic — not a normal steady-state.

> When `cfg.SyncTargets` is empty (`Skipped=true`), no
> sync-state entry is created at all and there is consequently
> nothing to annotate. That is intentional: a user not opted into
> sync should not accumulate sync-state entries.

Same advisory rules as `discids.json`: missing file or corrupt JSON
degrades to "no record found", writes are atomic via temp + Move-Item,
write failures log `WARN` and never throw out of the rip pipeline.

### Vouching for manually-cleaned-up albums

When the rip box's library has been mirrored to a sync target,
the parent may free up local disk space later by deleting albums
by hand. `Find-RipperLibraryDiscIndexEntry` (in `src/core/`)
consults `sync-state.json` whenever a `Source='library'` row's
recorded path is missing: if any target reported `Status='OK'`
for that album, the entry is still surfaced and the duplicate-disc
dialog fires on re-insert (with the same path-hidden styling as
the recycled case). Rows with no successful sync record still
self-heal silently, matching the pre-Phase-6 behaviour.

## Adding a new target

1. **Create** `src/sync/Sync-To<Name>.ps1` with one function:

   ```powershell
   function Invoke-RipperSyncTo<Name> {
       [CmdletBinding()]
       [OutputType([hashtable])]
       param(
           [Parameter(Mandatory)] [string]$AlbumPath,
           [Parameter(Mandatory)] [string]$LibraryRoot,
           [Parameter(Mandatory)] [object]$Config
       )

       # ... do the work ...

       @{
           Target      = '<Name>'
           Status      = 'OK'        # or 'Failed' / 'Skipped'
           BytesCopied = [int64]$bytes
           Diagnostic  = $null       # or a short message on Failed
       }
   }
   ```

   Return shape is mandatory — the orchestrator normalises a
   `pscustomobject` return to a hashtable but every field above must
   be present. Throwing is allowed; the orchestrator catches and
   marks the result `Failed` with the exception message.

2. **Dot-source** it in `src/Start-Ripper.ps1` next to the existing
   sync files, *and* in `src/tools/Complete-OrphanedRip.ps1` so the
   orphan-resume path can sync too.

3. **Document** it in this file's "Built-in targets" table and in the
   `cfg.SyncTargets` comment in `config/config.template.json`.

4. **Update** `setup/New-RipperConfig.ps1`'s known-targets list so
   the interactive prompt accepts the new name.

5. **Add Pester coverage** in `tests/Invoke-RipperSync.Tests.ps1`
   (or a sibling file) — at minimum a happy-path call and one
   forced-failure case.

## Operational notes

- Targets run **sequentially**, in the order listed in
  `cfg.SyncTargets`. Phase 6.1 keeps it simple; if multi-target sync
  feels slow in 6.2+ we can revisit.
- An unknown name in `cfg.SyncTargets` (no matching
  `Invoke-RipperSyncTo<Name>` function loaded) logs a `WARN` and is
  reported `Failed`. It does not crash the rip.
- `cfg.SyncTargets = []` short-circuits the orchestrator to
  `Skipped = $true`. Retention also skips in that state, so an empty
  config is exactly the pre-Phase-6 behaviour.
- Manual retry / batch sync over already-ripped albums:
  `./src/tools/Sync-PendingAlbums.ps1` walks `sync-state.json` and
  re-invokes the orchestrator against every album whose configured
  targets are not all `OK`. Use after fixing a typo in
  `cfg.SyncTargets`, recovering from a NAS outage, or rotating
  credentials. Supports `-WhatIf`, `-Force` (retry everything,
  including AllOk entries), and `-LibraryRoot <path>`. The tool
  also runs `Invoke-RipperLibraryRetention` on entries it restores
  to AllOk so a deferred `MoveToSentAfterAllSynced` /
  `RecycleAfterAllSynced` finally applies.
- The same tool also performs a hygiene pass: any per-album
  `Targets.<name>` whose `<name>` is no longer in `cfg.SyncTargets`
  is pruned (logged INFO, persisted). Stale `Failed` rows from a
  fixed typo or a removed target read like unresolved problems
  three months later; the per-disc rip log retains the historical
  record. Pruning honours `-WhatIf`. The rip pipeline itself never
  prunes -- a normal rip only ever mutates state for its own album.
- **Startup auto-retry (Phase 6.5).** When `cfg.RetryPendingSyncOnStartup`
  is true (default), `Start-Ripper.ps1` shows a WPF dialog
  (`Show-RipperPendingSyncProgress`) at launch -- before the disc-rip
  loop -- that runs the same retry logic over `sync-state.json` and
  surfaces a friendly progress + summary screen. The dialog is skipped
  silently when nothing is pending. Cancel falls through to the
  normal rip flow without complaint; the pending entries simply
  retry on the next launch (or via the CLI tool above). Both the
  CLI and the dialog share the same core function
  `Invoke-RipperPendingSync` in `src/sync/Invoke-PendingSync.ps1`.
  See D-025 for the design rationale.
