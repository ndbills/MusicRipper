# SETUP — for the engineer

This is the install + calibration walkthrough for **your** machine.
Parents get the (much shorter) `PARENTS-QUICKSTART.md` once Phase 7 lands.

## Prerequisites

- Windows 10 1809+ or Windows 11.
- An optical drive (internal SATA or external USB).
- An internet connection (for winget + MusicBrainz lookups).

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
- `CUETools.CUETools` — rip engine, ships with `metaflac.exe`.
- `MusicBrainz.Picard` — manual re-tagging tool used when clearing the
  review queue.

Idempotent — re-running is a no-op for already-installed packages.

## 3. Create the config

```powershell
./setup/New-RipperConfig.ps1
```

Prompts you for:

| Field                     | Notes                                                              |
| ------------------------- | ------------------------------------------------------------------ |
| Library root              | Where ripped albums land. Created if missing.                      |
| MusicBrainz contact email | **Required by their ToS** — they'll contact you if MusicRipper misbehaves. |
| OneDrive mirror path      | Optional. Blank to skip.                                           |
| Synology UNC + credential | Optional. Credential is DPAPI-encrypted via `Export-Clixml`.       |

Output: `%LOCALAPPDATA%\MusicRipper\config.json` (and
`credentials.clixml` if you supplied a NAS credential).

## 4. Calibrate the optical drive

```powershell
./setup/Register-Drive.ps1
```

Detects optical drives, prompts you to pick if more than one, and looks
up the drive's **AccurateRip read offset** (a per-drive sample-count
correction needed for AccurateRip / CTDB verification).

Lookup order:

1. Live scrape of <http://www.accuraterip.com/driveoffsets.htm>.
2. Bundled fallback list at `data/driveoffsets.cached.json`.
3. Manual entry if neither matched.

Re-run anytime — e.g. if you swap drives.

## 5. Install the Desktop shortcut

```powershell
./setup/Install-Shortcut.ps1
```

Creates **"Rip a CD.lnk"** on your Desktop pointing at
`pwsh -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Start-Ripper.ps1`.

In Phase 1 the shortcut just shows a stub message box confirming the
config loads. Real rip logic lands in Phase 4.

## 6. Verify

```powershell
Invoke-Pester ./tests
```

All tests should pass. Then double-click the Desktop shortcut — you
should see the "MusicRipper — Phase 1 stub" message box reporting the
config status and log path.

## State locations cheat-sheet

| Thing                     | Path                                              |
| ------------------------- | ------------------------------------------------- |
| Config                    | `%LOCALAPPDATA%\MusicRipper\config.json`          |
| NAS credential (DPAPI)    | `%LOCALAPPDATA%\MusicRipper\credentials.clixml`   |
| Logs                      | `%LOCALAPPDATA%\MusicRipper\logs\`                |
| Library                   | (whatever you set as `LibraryRoot`)               |
| Review queue              | `<LibraryRoot>\_ReviewQueue\`                     |

## Resetting

To start over: delete `%LOCALAPPDATA%\MusicRipper\` and re-run the four
setup scripts.
