# Troubleshooting

Append entries as new failure modes show up in the wild.

## Setup

### `winget` is not recognized
Install **App Installer** from the Microsoft Store, then re-run
`./setup/Install-Dependencies.ps1`.

### `Register-Drive.ps1` says "no AccurateRip offset found"
The live AccurateRip page may have been unreachable AND the bundled
fallback list (`data/driveoffsets.cached.json`) doesn't have your
drive. Look up your drive at <http://www.accuraterip.com/driveoffsets.htm>
manually and enter the offset when prompted. Open a PR adding the
drive to `data/driveoffsets.cached.json` while you're there.

### `Import-RipperConfig` throws "config not found"
You haven't run `./setup/New-RipperConfig.ps1` yet on this machine, or
`%LOCALAPPDATA%\MusicRipper\config.json` was deleted. Re-run that
script.

### Desktop shortcut does nothing when double-clicked
Open PowerShell, run the command from the shortcut's "Target" field
manually, and read the error. Most likely cause: PS7 isn't on `PATH` —
re-run `./setup/Install-Dependencies.ps1`.

## Tests

### `Invoke-Pester` not found
```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

---

*(Phases 2–7 will add disc-identification, metadata, rip, and sync
failure modes here as they're encountered.)*
