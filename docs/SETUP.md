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

Creates **"Rip a CD.lnk"** on your Desktop pointing at
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
