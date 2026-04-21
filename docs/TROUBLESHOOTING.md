# Troubleshooting

Append entries as new failure modes show up in the wild.

## Setup

### `winget` is not recognized
Install **App Installer** from the Microsoft Store, then re-run
`./setup/Install-Dependencies.ps1`.

### `Install-Dependencies.ps1` says "No package found matching input criteria"
The winget id for a package may have changed upstream. Find the current
id with `winget search <name>` and update the `$packages` list in
`setup/Install-Dependencies.ps1`. Known historical gotcha:
**CUETools** is published as `gchudov.CUETools` (the upstream
maintainer's GitHub handle), not `CUETools.CUETools`.

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

## Disc identification (Phase 2)

### `Get-RipperDiscId` says "Could not open drive D: Access is denied"
Three usual causes:
1. **No disc inserted.** Insert an Audio CD and retry.
2. **Drive held by another app.** Close CUERipper, Windows Media
   Player, foobar2000, or anything else using the drive.
3. **Lower-level Windows access policy.** Try running from an
   elevated `pwsh` once to confirm; if that works, the drive
   needs a normal-user run-once to register.

### `CUETools not found` from `Get-CueToolsPath`
Re-run `./setup/Install-Dependencies.ps1`. winget installs CUETools
as a *portable* package under
`%LOCALAPPDATA%\Microsoft\WinGet\Packages\gchudov.CUETools_*`,
not Program Files \u2014 if `winget list gchudov.CUETools` returns
nothing, the install never completed.

### MusicBrainz lookup returns `Status: NoMatch`
Real for any disc not in the MB database (rare for mainstream music,
common for self-pressed CDs / box-set bonus discs / homebrew
compilations). The pipeline will route these to `_ReviewQueue/`
in Phase 5.

### MusicBrainz lookup returns `Status: Offline`
No internet, MusicBrainz is down (`https://status.musicbrainz.org`),
or the rate limit kicked in. Tool retries on the next disc; the
current disc still rips (Phase 5+) but goes to `_ReviewQueue/` with
placeholder tags.
