# SETUP — for the engineer

This is the install + calibration walkthrough for **your** machine.
Parents get the (much shorter) `PARENTS-QUICKSTART.md` once Phase 7 lands.

## Prerequisites

- Windows 10 1809+ or Windows 11.
- An optical drive (internal SATA or external USB).
- An internet connection. Required at install time for:
  - `winget` to download CUETools / Xiph.FLAC / Picard / WireGuard.
  - The one-time AccurateRip drive-offset list fetch (the list is
    proprietary and not redistributable, so we download it fresh on
    your machine into `data/driveoffsets.cached.json`).
  And at runtime for MusicBrainz / Cover Art Archive / iTunes / Deezer
  metadata lookups.

## 1. Clone the repo

```powershell
git clone <this-repo> C:\bin\MusicRipper
cd C:\bin\MusicRipper
```

## 2. Install dependencies

```powershell
./setup/Install-Dependencies.ps1
```

This `winget install`s:

- `Microsoft.PowerShell` — PS7 runtime.
- `gchudov.CUETools` — rip engine, ships with `metaflac.exe`.
- `MusicBrainz.Picard` — manual re-tagging tool used when clearing the
  review queue.

Idempotent — re-running is a no-op for already-installed packages.

## 3. First launch — config + drive registration in one window

```powershell
./src/Start-Ripper.ps1
```

On first launch (no `%LOCALAPPDATA%\MusicRipper\config.json` yet) MusicRipper
opens the **WPF settings editor** in first-run mode. Everything you need to
get working is in tabs:

| Tab            | What you set                                                                                                  |
| -------------- | ------------------------------------------------------------------------------------------------------------- |
| **General**    | Library root (Browse...), MusicBrainz contact email, **Register drive...** button (with progress bar).        |
| **Metadata**   | Order of metadata providers (MusicBrainz / CTDB / GnuDB / Deezer†).                                           |
| **Cover Art**  | Order of cover-art providers (CoverArtArchive / iTunesSearch / Deezer†).                                      |
| **Sync**       | Sync targets (OneDrive / SynologyNAS), OneDrive folder (Browse...), NAS UNC + DPAPI credential **Set...**, retention rule. |
| **WireGuard**  | `.conf` file picker + **Install / register tunnel...** button (one UAC prompt). Auto-toggle + keep-alive.     |

> † **Deezer is non-commercial only** per their
> [developer ToU](https://developers.deezer.com/termsofuse) (Section IV,
> *"strictly private use within a family scope"*). Fine for the family
> music-digitization use case MusicRipper is designed for; **uncheck the
> Deezer providers** if you're repurposing the tool for paid / commercial
> work. MB, CTDB, GnuDB, CoverArtArchive, and iTunesSearch have no such
> restriction.

**Click Save** to write `%LOCALAPPDATA%\MusicRipper\config.json` and
continue. **Cancel** exits cleanly.

Cross-field validation prevents silly mistakes (Save is disabled if e.g.
OneDrive is in SyncTargets but no folder is picked).

> The legacy console wizard `setup/New-RipperConfig.ps1` still works for
> headless / scripted setups, but the WPF editor is the supported path.

> **Driveless test machines:** if you click No on the "no drive registered"
> prompt, MusicRipper enters **no-drive mode** — the startup pending-sync
> UI still runs (so you can flush a NAS backlog), then the app exits.

## 4. Install the Desktop shortcut

```powershell
./setup/Install-Shortcut.ps1
```

Creates **"MusicRipper - Rip a CD.lnk"** on your Desktop pointing at
`pwsh -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Start-Ripper.ps1`.

After Phase 6.6 the shortcut is the user-facing entry point: it launches
the full ripper, and on first run pops the WPF settings editor described
in step 3.

`Install-MusicRipper.ps1` also drops three Start Menu shortcuts via
`setup/Install-StartMenuShortcuts.ps1`:

- **MusicRipper - Rip a CD** — same target as the Desktop shortcut.
- **MusicRipper - Settings** *(F-6, Phase 8)* — opens the WPF settings
  editor standalone via `src/tools/Show-RipperConfig.ps1`. Use this any
  time after install to change `LibraryRoot`, sync targets, the NAS
  credential, or the WireGuard tunnel. Saved settings apply the next
  time MusicRipper runs (the Save toast says so). Safe to launch even
  while MusicRipper is mid-rip — main reads config once at startup.
- **MusicRipper - Uninstall** — runs `Uninstall-MusicRipper.ps1`.

## 5. Verify

```powershell
Invoke-Pester ./tests
```

All tests should pass.

## State locations cheat-sheet

| Thing                     | Path                                              |
| ------------------------- | ------------------------------------------------- |
| Config                    | `%LOCALAPPDATA%\MusicRipper\config.json`          |
| NAS credential (DPAPI)    | `%LOCALAPPDATA%\MusicRipper\credentials.clixml`   |
| Logs                      | `%LOCALAPPDATA%\MusicRipper\logs\`                |
| Library                   | (whatever you set as `LibraryRoot`)               |
| Review queue              | `<LibraryRoot>\_ReviewQueue\`                     |

## Resetting

To start over: delete `%LOCALAPPDATA%\MusicRipper\` and re-launch the
Desktop shortcut — the WPF first-run editor will reappear.

## Cutting a release (engineer side, Phase 8 / D-032)

Parents update via the **MusicRipper - Update** Start Menu shortcut,
which calls the GitHub Releases API and downloads the latest tagged
zip. To make a new release available to them:

1. Bump the version in [VERSION](../VERSION) at the repo root
   (single line, e.g. `0.2`). This is the value the running app
   reports as its own version, and the value the auto-updater
   compares against the GitHub tag. Phase 8.3 / D-032 amendment
   replaced the previous `$script:RipperVersion` hardcode with this
   file-based source of truth so the version-in-code and the
   git-tag are bumped in the same commit.
2. Commit + push to `main`.
3. Cut the tagged release:
   ```powershell
   gh release create v0.2 --title "v0.2: <one-line summary>" --notes "..."
   ```
   (or `--notes-file CHANGELOG-v0.2.md` for longer notes; the body is
   shown verbatim in the parent's update dialog).
4. The updater on the parents' machine will see the new tag the next
   time they click **MusicRipper - Update**.

### SemVer for MusicRipper

VERSION follows [Semantic Versioning](https://semver.org/) loosely:

| Bump  | When                                                          |
| ----- | ------------------------------------------------------------- |
| MAJOR | A change a parent has to do something for (re-do config, etc.). Pre-1.0 (we're at 0.x) this rule is relaxed -- 0.x is "experimental, we reserve the right to break things." |
| MINOR | New parent-visible feature, backward-compatible (auto-updater itself, NAS-credential validator, etc.). Most MusicRipper bumps are MINOR. |
| PATCH | Bug fix only, no new features. The four Updater fixes shipped on 2026-05-11 would be a single PATCH bump if they were tagged. |

Use the matching git tag prefix (`v0.2`, `v0.2.1`). The auto-
updater's `Compare-RipperVersion` strips the leading `v` and
compares numerically; tags without a `v` prefix work too.

If you skip step 3 (no Release tag), the updater falls back to a
direct download of the `main`-branch zip. There's no version tag to
compare against, so the comparator can't tell "up to date" from
"newer available" — it conservatively reports **"Update available"
on every click**, downloads the current `main` zip, and re-applies
it. Functionally harmless (each apply just overwrites with the same
content + creates a new `-old-<timestamp>` backup), but it nags the
parent and clutters the install dir's parent with backup folders.
**Cut at least one Release before handing the install to a parent**
— `gh release create v0.1 --title "v0.1: baseline" --notes "Initial
tagged release."` is enough to silence the always-prompts behavior
and establish the comparison anchor. From that point on you only
see "Update available" when you actually cut a new tag.

After the parent applies an update, the prior install is kept at
`<install-dir>-old-<timestamp>` (the most recent 2 backups are
retained; older ones are auto-pruned). Recovery from a bad release
is "rename the latest `-old-*` folder back to the live install path."

### What `Update-MusicRipper.ps1` does at runtime

[Update-MusicRipper.ps1](../Update-MusicRipper.ps1) is a sibling of
[Install-MusicRipper.ps1](../Install-MusicRipper.ps1) and
[Uninstall-MusicRipper.ps1](../Uninstall-MusicRipper.ps1) at the
repo root. It's a thin entry-point shim — the actual logic lives in
[src/lib/Updater.psm1](../src/lib/Updater.psm1) (pure helpers) and
[src/ui/Show-UpdateDialog.ps1](../src/ui/Show-UpdateDialog.ps1)
(WPF). The script:

1. Self-minimizes the host pwsh window (so the WPF dialog is the
   only user-visible surface).
2. Imports `Logging` / `Common` / `Updater` modules + dot-sources
   the WPF dialog.
3. Resolves the install root via `Get-RipperInstallRoot` (validates
   that `Install-MusicRipper.ps1` + `src\Start-Ripper.ps1` exist
   alongside).
4. Opens the `Show-RipperUpdateDialog` — three states:
   - **Checking**: queries `https://api.github.com/repos/ndbills/MusicRipper/releases/latest`
     in a worker runspace.
   - **Result**: either *"You're up to date"* (single OK), *"Update
     available: vX.Y"* (Update + Cancel buttons + release notes
     panel), or *"Couldn't check"* (Retry + Cancel).
   - **Applying** (if the user clicks Update): downloads the source
     zip to `%TEMP%\musicripper-update-<guid>\`, expands it,
     validates the layout, snapshots user-generated files
     (`data\driveoffsets.cached.json`), renames the live install to
     `<install>-old-<yyyyMMdd-HHmmss>` as a rollback point, moves
     the new tree into place, restores user files, re-runs
     [setup/Install-Dependencies.ps1](../setup/Install-Dependencies.ps1)
     + [setup/Install-Shortcut.ps1](../setup/Install-Shortcut.ps1)
     + [setup/Install-StartMenuShortcuts.ps1](../setup/Install-StartMenuShortcuts.ps1)
     idempotently, prunes old backups (keeps 2).
5. Logs every step to `%LOCALAPPDATA%\MusicRipper\logs\<stamp>-update.log`
   so a failed apply can be diagnosed after the fact.

Failure semantics:

- **Network error checking** → "Couldn't check" panel; no state changed.
- **Download/extract fails** → install untouched (no backup created
  yet); dialog shows the error.
- **Apply fails mid-move** → automatic rollback (rename `-old-*`
  back to live); dialog reports "rolled back to previous version."
- **Setup-chain re-run fails post-apply** → new files ARE in place;
  logged as WARN, apply still reports success. Parent re-runs the
  Update shortcut later or runs the failing setup script manually.

Engineers can invoke the script directly during testing
(`./Update-MusicRipper.ps1` from a clone), but the parent-facing
entry point is the **MusicRipper - Update** Start Menu shortcut
created by `setup/Install-StartMenuShortcuts.ps1`.

Full architectural rationale (why stage+atomic-rename, why backup
retention 2-deep, why "leave orphan files", rejected alternatives
including auto-check-on-launch and push-from-engineer) lives in
[DECISIONS.md D-032](DECISIONS.md).
