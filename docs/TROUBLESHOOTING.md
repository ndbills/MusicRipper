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

### `Get-RipperDiscId` fails with "Could not open drive" or "0x80070000"
CUETools' SCSI driver requires **Administrator** privileges to open
an optical drive. The Desktop shortcut installed by
`./setup/Install-Shortcut.ps1` already requests elevation. If you're
running `Start-Ripper.ps1` from a non-elevated terminal, either
re-launch PowerShell as Administrator or use:

```powershell
Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-File','C:\bin\MusicRipper\src\Start-Ripper.ps1'
```

If you upgraded from an early Phase-1 install and the shortcut isn't
prompting for UAC, re-run `./setup/Install-Shortcut.ps1` to refresh
the `.lnk` with the elevation flag.

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

## Tagging & library files (Phase 5)

### Why does Phase 5 "re-tag" files that already have tags?
CUETools' encoder writes a **minimal** Vorbis comment block during the
rip (TITLE / ARTIST / ALBUM / TRACKNUMBER) — enough to identify the
file in isolation, not enough for a real music library. Phase 5
(`src/core/Write-Tags.ps1`) wipes those minimal tags and writes the
full Plex/MusicBrainz Picard set:

- `ALBUMARTIST` (Plex needs this distinct from `ARTIST` for compilation
  grouping; without it, every track on a Various Artists disc shows up
  as a separate "album" in your library).
- `TRACKTOTAL`, `DISCNUMBER`, `DISCTOTAL` (multi-disc set support).
- `DATE`, `GENRE`, `COMPILATION`.
- `MUSICBRAINZ_DISCID`, `MUSICBRAINZ_ALBUMID`, `MUSICBRAINZ_ALBUMARTISTID`,
  `MUSICBRAINZ_ARTISTID`, `MUSICBRAINZ_TRACKID`, `MUSICBRAINZ_RELEASEGROUPID`
  — so Picard / Plex can re-match without re-querying MusicBrainz.
- Embedded `PICTURE` block (front cover) on every track. The
  `cover.jpg` sidecar alone is not enough; Plex mobile/Roku display
  the embedded picture, not the sidecar.
- `REPLAYGAIN_TRACK_GAIN/PEAK` per track + `REPLAYGAIN_ALBUM_GAIN/PEAK`
  across the disc. CUETools has **no .NET API** for ReplayGain at all;
  if you skip Phase 5, volume normalization in Plex/foobar2000 will
  not work.

This is exactly what you'd do by dragging the rip folder into
MusicBrainz Picard after a CUETools / EAC rip — most online "rip for
Plex" guides assume you'll do the Picard step manually. We just
automated it.

### Windows Explorer shows blank Title/Artist/Album columns
Windows 11's built-in FLAC property handler is unreliable and
frequently shows blank columns even when the tags are perfectly
written. F5 won't help — there is no cache to invalidate, the handler
just doesn't read those Vorbis comment layouts.

Verify the file is actually fine:

```powershell
./src/tools/Show-FlacTags.ps1 'E:\digitize\MusicRipper\<artist>\<album>'
```

If that prints a populated 20-line VORBIS_COMMENT block, the file is
golden — Plex, foobar2000, MusicBee, Picard, VLC, MediaInfo will all
read it correctly.

To also fix Explorer, install [Icaros](https://shark007.net/Icaros.html)
(free shell extension; gives FLAC files real Title/Album/Artist/Length
columns and album-art thumbnails). This is a Windows-side cosmetic
fix; nothing to change in MusicRipper.

### "My rip crashed mid-flow — what happens to the partial folder?"
Commit C added a `_ripper-state.json` sidecar that's written after the
rip completes but before post-process moves the folder. On the next
launch of `Start-Ripper.ps1`, the orphan-recovery prompt offers to
finish those rips automatically (Yes = process all / No = skip /
Cancel = quit).

For pre-sidecar orphans (rips from before commit C, or sidecars
manually deleted), use the manual tool:

```powershell
./src/tools/Complete-OrphanedRip.ps1 `
    -RipFolder 'E:\digitize\MusicRipper\_inbox\<orphan folder>' `
    -DiscId    '<musicbrainz disc id>'
```

The MusicBrainz disc id is in the first few lines of the rip log
inside the orphan folder, and on `https://musicbrainz.org/cdtoc/<id>`.

### "An older rip is missing tags Picard would set (sort names, ASIN, etc.)"
The Phase-5 tag set has grown over time. Older rips were tagged
against an earlier schema and are missing fields like `ALBUMARTISTSORT`,
`ORIGINALDATE`, `RELEASESTATUS`, `LABEL`, etc. To bring an existing
album up to the current schema without re-ripping the disc:

```powershell
./src/tools/Update-AlbumTags.ps1 'E:\digitize\MusicRipper\<artist>\<album>'
```

Lookup ladder (first hit wins, all rate-limited per MusicBrainz's
1 req/sec policy):

1. `-ReleaseMbid <mbid>` argument (explicit override)
2. `MUSICBRAINZ_ALBUMID` tag on track 1 (preferred)
3. `MUSICBRAINZ_DISCID` tag on track 1
4. Text search on `ALBUMARTIST` + `ALBUM` (best-effort fallback)

Audio is never re-encoded — `metaflac` edits in place against the
padding the encoder reserved at rip time. Cover art is preserved by
default; pass `-RefreshCoverArt` to also re-pull from Cover Art
Archive. Pass `-SkipReplayGain` if you don't need the analysis pass
to re-run.

If the tool refuses with a track-count mismatch, that usually means a
multi-disc release whose `MUSICBRAINZ_DISCID` tag is missing or wrong.
Re-run with an explicit `-ReleaseMbid` pointing at the correct medium.
