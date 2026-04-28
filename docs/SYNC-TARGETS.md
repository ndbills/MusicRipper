# Sync targets

> **Status:** Phase 6.1 framework + built-in `Stub` target shipped.
> Real targets land in 6.2 (OneDrive) and 6.3 (Synology NAS over LAN /
> 6.4 over WireGuard). Background: [DECISIONS.md D-022](DECISIONS.md).

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

| Name   | Purpose                                                                 |
| ------ | ----------------------------------------------------------------------- |
| `Stub` | Writes a marker file under `.musicripper\stub-sync\<rel>\.synced`. Honours `cfg.StubSyncFail = true` for failure-path testing. Use it to dry-run the framework before configuring a real target. |

OneDrive (`Sync-ToOneDrive.ps1`) and SynologyNAS
(`Sync-ToSynologyNAS.ps1`) ship in 6.2 and 6.3 respectively.

### Retention modes

| Mode                          | Behaviour                                                                                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Keep` (default)              | Do nothing. The album stays in the library forever. Safe choice when you don't have an off-box backup yet.                                        |
| `MoveToSentAfterAllSynced`    | Move the album folder to `<LibraryRoot>\_Sent\<Artist>\<Album>\`. The `discids.json` entry is rewritten to point at the new path with `Source='sent'` so duplicate detection still works on later inserts. |
| `RecycleAfterAllSynced`       | Send the album folder to the Recycle Bin via the same helper as the target-exists "Discard" button (D-021). The `discids.json` entry is removed. |

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
    "RetentionApplied": null
  }
}
```

Same advisory rules as `discids.json`: missing file or corrupt JSON
degrades to "no record found", writes are atomic via temp + Move-Item,
write failures log `WARN` and never throw out of the rip pipeline.

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
- Manual retry / batch sync over already-ripped albums lands in a
  later sub-phase as `src/tools/Sync-PendingAlbums.ps1`.
