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
The live AccurateRip page was unreachable AND the install-time
cache (`data/driveoffsets.cached.json`, populated by
`setup/Install-DriveOffsetCache.ps1` on first install) doesn't
have your drive. Look up your drive at
<http://www.accuraterip.com/driveoffsets.htm> manually and enter
the offset when prompted. Re-running
`./setup/Install-DriveOffsetCache.ps1 -Force` will refresh the
local cache from the live page if you suspect it's gone stale.

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
- `ALBUMARTISTS` / `ARTISTS` — multi-value forms (one tag line per
  credited artist, no joinphrases). Picard always writes these.
- `ALBUMARTISTSORT` / `ARTISTSORT` — sort-name forms so clients file
  "The Beatles" under B and "Lowell Mason" under M.
- `TRACKTOTAL`, `DISCNUMBER`, `DISCTOTAL` (multi-disc set support).
- `DATE`, `ORIGINALDATE`, `ORIGINALYEAR`, `GENRE`, `COMPILATION`.
- `RELEASESTATUS`, `RELEASETYPE`, `RELEASECOUNTRY`, `SCRIPT`,
  `LANGUAGE`, `MEDIA`, `LABEL`, `CATALOGNUMBER`, `BARCODE`, `ASIN` —
  the full Picard release-level descriptor set.
- `MUSICBRAINZ_DISCID`, `MUSICBRAINZ_ALBUMID`, `MUSICBRAINZ_ALBUMARTISTID`,
  `MUSICBRAINZ_ARTISTID`, `MUSICBRAINZ_TRACKID` (recording id),
  `MUSICBRAINZ_RELEASETRACKID` (per-release track id; Picard's
  confusingly-named "MusicBrainz Track Id"), `MUSICBRAINZ_RELEASEGROUPID`
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
`ARTISTS`, `MEDIA`, `MUSICBRAINZ_RELEASETRACKID`, `ORIGINALDATE`,
`RELEASESTATUS`, `LABEL`, etc. To bring an existing album up to the
current schema without re-ripping the disc:

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

By default the tool also preserves each file's `LastWriteTime` and
`CreationTime` across the rewrite (matches Picard's "Preserve
timestamps of tagged files" option). Pass `-PreserveTimestamps:$false`
if you actually want the OS to bump the mtimes (e.g. so a sync tool
re-uploads).

### "I re-inserted a CD I already ripped — what should happen?"
Phase 5.8 added cross-session duplicate detection. Every successful
rip records its MusicBrainz disc id in
`<LibraryRoot>\.musicripper\discids.json`. When you insert a disc that
already has an entry there, you get a three-way prompt before any
ripping starts:

- **Skip rip** — eject and return to the disc-insert screen (default
  on Esc / window close).
- **Open folder...** — open the existing album in Explorer so you can
  confirm it's the same album (the dialog stays open).
- **Rip again (keep both)** — re-rip the disc side-by-side. The new
  copy lands in `<Album> (<Year>) [rip 2]` (then `[rip 3]`, etc.) so
  it never overwrites the original. Square brackets are used so Plex's
  year heuristic doesn't get confused.

If MusicRipper *doesn't* warn you about a disc you know is already in
the library, see the next section about seeding.

### Seeding the duplicate-disc index for a pre-existing library
The `discids.json` index is built up automatically as you rip discs
with Phase 5.8 or later. If you already have a library full of FLACs
ripped with an earlier version (or with Picard / EAC), seed it once:

```powershell
./src/tools/Build-LibraryDiscIndex.ps1
```

It walks `<LibraryRoot>` (skips `_ReviewQueue\` and `.musicripper\`),
reads the `MUSICBRAINZ_DISCID` Vorbis tag from one FLAC per album
folder, and writes one entry per disc into `discids.json`. By default
it merges with whatever's already there; pass `-Force` to wipe and
rebuild from scratch. Pass `-LibraryRoot <path>` to point at a
specific tree instead of the one in your `config.json`.

Albums without a `MUSICBRAINZ_DISCID` tag are skipped (they can't
participate in duplicate detection until they're re-tagged with
`./src/tools/Update-AlbumTags.ps1`). Multi-disc releases get one
entry per disc.

### "How do I see what's in the duplicate-disc index?"
It's a plain JSON file you can open in any editor:

```powershell
Get-Content "$((Import-RipperConfig).LibraryRoot)\.musicripper\discids.json" |
    ConvertFrom-Json
```

To remove an entry (e.g., you deleted the album folder by hand and
want MusicRipper to re-rip the disc cleanly), delete the matching
top-level key from the JSON and save. Stale entries (folder no longer
exists on disk) are filtered out automatically at lookup time, so the
file is forgiving of out-of-band library changes.

### When should I click "Send to Review" instead of "Rip"? (Phase 5.9)
The metadata dialog has three buttons: **Rip**, **Send to Review**,
**Cancel**. Both Rip and Send to Review actually rip the CD; the
difference is where the finished folder lands and whether the FLACs
get tagged.

Use **Rip** when the metadata in the dialog is correct -- the rip
goes straight into the Plex layout under `<LibraryRoot>` with full
Picard-style tags (album artist sorts, MusicBrainz IDs, ReplayGain,
embedded cover art, etc.) and gets recorded in the cross-session
duplicate-disc index.

Use **Send to Review** when:
- the disc's track titles look wrong and you want to fix them in
  Picard before they reach Plex,
- MusicBrainz returned the wrong release and the text-search results
  weren't right either,
- the disc is a private/unreleased pressing that needs hand-tagging,
- you want to compare against a different release before committing
  the album to the library.

The rip lands in `<LibraryRoot>\_ReviewQueue\USER-REVIEW - <Artist> - <Album> - <DiscId>\`
with the raw CUETools tags (TITLE/ARTIST/ALBUM/TRACKNUMBER only),
plus a `REVIEW.txt` describing why it's there and a single-file FLAC
image you can drag into foobar2000 for inspection. The `USER-REVIEW`
prefix distinguishes 'I sent this here on purpose' from
auto-routed `SUSPECT` / `UNKNOWN` / `LOWMATCH` rips. The disc is
**not** added to the duplicate-disc index, so re-inserting it later
will offer a fresh metadata search rather than a 'this is already in
your library' prompt.

When you've finished fixing tags in Picard, promote the album with
`./src/tools/Move-FromReviewQueue.ps1 <folder>` (or do it by hand;
the layout is identical to the main library).

## Sync (Phase 6.1+)

### "I configured a SyncTarget but it doesn't match any installed target"
Symptom: rip finishes, log shows `WARN Sync Unknown sync target
'<Name>' (no function Invoke-RipperSyncTo<Name>)`, the album is left
in the library, and `sync-state.json` records `Status=Failed` for
that target. Retention (Move/Recycle) does not fire because not every
target reported OK -- the album records `RetentionApplied.Action =
'KeepTargetsNotOk'`.

Recovery:

1. Fix `cfg.SyncTargets` -- typo, missing target script, etc. The
   built-in name is `Stub`; future phases ship `OneDrive` and
   `SynologyNAS`.
2. Run the retry tool:
   ```powershell
   ./src/tools/Sync-PendingAlbums.ps1
   ```
   It walks `sync-state.json`, retries every album whose configured
   targets are not all `OK`, applies retention on the freshly-OK
   ones, and exits 1 if anything still fails. Add `-WhatIf` to
   preview, `-Force` to retry every entry (useful after rotating
   credentials or wiping the destination), or `-LibraryRoot <path>`
   to point at a non-default library.

The same tool covers transient failures (NAS offline, OneDrive
throttled, SMB share momentarily unmounted): just re-run it once
the underlying problem is fixed.

While it's at it, the tool prunes any `Targets.<name>` whose
name is no longer in `cfg.SyncTargets` -- so the `Bogus: Failed`
row above disappears from `sync-state.json` after the first
successful run with the corrected config. The historical record
stays in the per-disc rip log; sync-state.json reflects the
current configuration only.

### "What does `RetentionApplied: null` in sync-state.json mean?"
`null` means the retention layer never ran for that album yet --
e.g. the rip predates Phase 6.1, or `Invoke-RipperPostProcess` was
interrupted before the retention call. Every retention decision
(including the `Keep` no-op and the `KeepTargetsNotOk` waiting state)
records a non-null value with `Action`, `Reason`, `AppliedAt`. See
`docs/SYNC-TARGETS.md` for the full Action table.

### "SynologyNAS sync reports: NAS server is reachable on TCP/445 but the share could not be opened"
Phase 6.4.2 diagnostic. Symptom: `sync-state.json` shows
`SynologyNAS: Failed` with a `Diagnostic` along the lines of:

> NAS server is reachable on TCP/445 but the share '\\<host>\<share>' could not be opened. The most likely cause is that the share requires authentication and no credential is configured. Open Settings -> Sync -> 'Set Synology credential...' to save your NAS username/password, then retry.

Meaning: the NAS itself is up and answering on the SMB port, but
the share rejected the connection at the auth step. Most home NAS
shares (Synology DSM, TrueNAS, etc.) require a username/password
and do *not* accept anonymous SMB.

Fix: open **MusicRipper - Settings** -> **Sync** tab -> click
**Set...** under *NAS credential*, enter your NAS username +
password, Save. The credential is stored as a DPAPI-protected
`PSCredential` at `%LOCALAPPDATA%\MusicRipper\credentials.clixml`
(only the user account that saved it can decrypt it). Then re-run
`./src/tools/Sync-PendingAlbums.ps1` -- or just relaunch
`MusicRipper - Rip a CD` and the Phase-6.5 startup retry dialog
will catch up automatically.

Note: the WPF Settings editor refuses to Save when `SynologyNAS` is
in SyncTargets but no credential is stored, so the failure mode
above can only happen if you enabled the target via the CLI setup
before Phase 6.4.2, or by hand-editing `config.json`.

### "OneDrive sync target reports Failed: OneDrive client is not installed"
Phase 6.2 detects the OneDrive client by reading
`HKCU\Software\Microsoft\OneDrive\UserFolder` (set on first sign-in)
with fallbacks to `Accounts\Personal\UserFolder` and `$env:OneDrive`.
If none resolve to an existing folder, the target fails fast with
exactly that message.

Fix: install OneDrive (it ships with Windows; if it was uninstalled,
get it from <https://www.microsoft.com/microsoft-365/onedrive/download>),
sign in with your Microsoft account, then re-run
`./src/tools/Sync-PendingAlbums.ps1`.

### "OneDrive sync target reports Failed: OneDriveSyncTargetRoot does not exist"
The configured `cfg.OneDriveSyncTargetRoot` (the album mirror folder
inside OneDrive) is missing. The target deliberately doesn't auto-
create folders inside OneDrive -- a missing folder usually means
"config got moved/renamed" rather than "make a new one, please".

Fix: re-run `./setup/New-RipperConfig.ps1` -- it pops a folder picker
seeded at the registered OneDrive root so you can navigate to (or
create) the right subfolder. Then re-run
`./src/tools/Sync-PendingAlbums.ps1`.


### "Can I use MusicRipper with Deezer for paid / commercial work?"

Short answer: **no -- disable the Deezer providers first.**

Deezer's
[developer terms of use](https://developers.deezer.com/termsofuse)
(Section IV, "Non-commercial use") restrict use of Deezer Content to
*"a strictly private use within a family scope"* -- the family
music-digitization use case MusicRipper is explicitly designed for.
Repurposing it for paid work (DJ catalogs, commercial archives,
music-licensing prep, etc.) is **outside** that scope and out of
compliance.

Fix: open `MusicRipper - Settings`, go to the **Metadata** and
**Cover Art** tabs, and uncheck **Deezer** in both lists. Or edit
`%LOCALAPPDATA%\MusicRipper\config.json` and remove the string
`"Deezer"` from both `MetadataProviders` and `CoverArtProviders`.

MusicBrainz, CTDB, GnuDB, CoverArtArchive, and iTunes Search remain
available without that limitation. (iTunes Search has its own Apple
attribution clause -- already satisfied by the project's
`NOTICE.md`.)

See `docs/THIRD-PARTY.md` and `docs/DECISIONS.md` D-030 for the
investigation behind this caveat.
