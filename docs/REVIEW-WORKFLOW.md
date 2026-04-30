# Review Workflow

When a rip can't be safely auto-filed into the main library, MusicRipper
routes it to `<LibraryRoot>\_ReviewQueue\` instead. This page is the
runbook for clearing that queue.

## When does an album end up here?

Five cases, each tagged with a folder-name prefix:

| Prefix        | Reason                                                                |
| ------------- | --------------------------------------------------------------------- |
| `UNKNOWN`     | No MusicBrainz match for this disc id.                                |
| `LOWMATCH`    | MusicBrainz match below the confidence threshold.                     |
| `SUSPECT`     | Rip log shows read errors, retries, or AccurateRip mismatches.        |
| `MANUAL`      | (Reserved -- legacy auto-routing prefix; not currently emitted.)      |
| `USER-REVIEW` | You clicked **Send to Review** in the metadata dialog (Phase 5.9+).   |

Main library = trustworthy. The review queue is your backlog.

## What's in the folder?

```
_ReviewQueue/
  <PREFIX> - <descriptor> - <discId>/
    01 - <Track>.flac        # per-track FLACs at the root — playable as-is
    ...
    cover.jpg                # if cover art was found
    <Album>.cue              # cue referencing the per-track FLACs
    <Album>.log              # the original rip log
    REVIEW.txt               # why it's here + suggested next step
    _image/
      <Album>.flac           # single-file image (concat of per-track audio)
      <Album>.cue            # cue referencing the single-file image
```

`REVIEW.txt` is a `Key: Value` file with `Reason`, `RipDate`, `DiscId`,
`MusicBrainzMatch`, `Tracks`, `Duration`, `SuggestedAction`, and
`LogFile`. Read it first.

## Per-prefix playbook

### `UNKNOWN` -- no MusicBrainz match

1. Drag the **per-track FLACs** (the ones at the album-folder root --
   `01 - <Track>.flac`, `02 - ...`, etc.) into **MusicBrainz Picard**
   and let it scan. Do *not* drag in `_image\<Album>.flac`; see
   [Inspecting the single-file image](#inspecting-the-single-file-image).
2. If Picard finds a match, accept it and **Save** -- Picard rewrites
   the FLAC tags in place.
3. Promote into the main library (see
   [Promoting an album to the library](#promoting-an-album-to-the-library)).
4. If Picard *also* can't identify it, the disc may genuinely be
   missing from MusicBrainz. Submit it from Picard's **Tools -> Submit
   disc IDs** menu, then re-rip.

### `LOWMATCH` — confidence too low

Same as `UNKNOWN` — Picard usually picks the right release on its
second pass with full audio fingerprints (the rip-time match is
TOC-only).

### `SUSPECT` — rip-quality issue

1. Open `<Album>.log` and skim for the offending track(s) — look for
   read errors, retries, or AccurateRip/CTDB mismatches.
2. Inspect `_image/<Album>.flac` in **foobar2000** (or mount via
   **WinCDEmu** / **Virtual CloneDrive**) and listen for audible
   defects on the suspect tracks.
3. **Re-rip:** just reinsert the disc. MusicRipper detects the
   existing queue entry by disc id and offers to replace it. Clean
   the disc first (microfiber cloth, inside-out wipe).
4. If repeated re-rips can't get past a damaged sector, accept the
   suspect rip: tag it manually with Picard, then promote.

### `MANUAL` / `USER-REVIEW` -- you sent it here on purpose

The `USER-REVIEW` prefix means you clicked **Send to Review** in the
metadata dialog (Phase 5.9+). The rip itself is fine; you wanted to
fix metadata before it landed in the library.

1. Open the **per-track FLACs** at the album-folder root in
   MusicBrainz Picard (not `_image\<Album>.flac`).
2. Fix whatever you noticed (wrong release year? bad cover art?
   wrong release of a multi-pressing album?), then **Save**.
3. Promote (see
   [Promoting an album to the library](#promoting-an-album-to-the-library)).

## Promoting an album to the library

Use the Phase 7 helper -- it reads the (now-correct) tags off the
per-track FLACs, computes the standard library path, moves library
content into place, discards the review-queue scratch (REVIEW.txt +
`_image\`), and seeds the cross-session duplicate-disc index for you:

```powershell
./src/tools/Move-FromReviewQueue.ps1 'E:\digitize\MusicRipper\_ReviewQueue\<folder>'
```

The target folder is computed from your config's `LibraryRoot` plus
the Picard-written tags:

```
<LibraryRoot>\
  <AlbumArtist>\
    <Album> (<Year>)\
      01 - <Track>.flac
      02 - <Track>.flac
      ...
      cover.jpg
      <Album>.cue
      <Album>.log
```

(Compilations route under `Various Artists\` instead of
`<AlbumArtist>\`. Multi-disc releases stay flat at album root with the
disc number prefixed in each filename, e.g. `1-01 - Track.flac`.)

Useful flags:

- `-WhatIf` -- show the planned move without touching disk.
- `-AllowSideBySide` -- if the target folder already exists, land in
  `<Album> (<Year>) [rip 2]` (then `[rip 3]`, ...) instead of erroring.
- `-Force` -- overwrite existing destination files.
- `-AlbumArtist`, `-Album`, `-Year`, `-IsCompilation` -- explicit
  overrides for cases where Picard wrote slightly different values
  than what you want on disk.
- `-KeepReviewArtifacts` -- move REVIEW.txt and `_image\` into the
  destination too instead of discarding them. Default is to discard.
- `-SkipSync` -- by default, a promoted album follows the same sync
  chain a normal Library-routed rip would (every `cfg.SyncTargets`
  entry, then `cfg.LocalRetention`). Pass this to seed
  `discids.json` only and leave sync for later (e.g. when you're
  ripping offline and will sync back at home). Sync failures land
  in `sync-state.json` and the next launch's pending-sync flow
  picks them up automatically -- same recovery as a normal rip.

If you'd rather move things by hand (or your particular case needs
tweaks the script doesn't support), the same target layout applies:

1. Move the per-track FLACs + `cover.jpg` + `<Album>.cue` + `<Album>.log`
   into the destination folder above. Use Windows Explorer or:

   ```powershell
   Move-Item -LiteralPath 'E:\digitize\MusicRipper\_ReviewQueue\<folder>' `
             -Destination  'E:\digitize\MusicRipper\<AlbumArtist>\<Album> (<Year>)'
   ```

2. **Discard** the `_image\` subfolder and `REVIEW.txt` -- they're
   review-queue artifacts, not library content.
3. (Optional) Open the album in your library and confirm Plex picks
   it up.
4. (Optional) If you want this disc to participate in the
   cross-session duplicate-disc detector (Phase 5.8), run the seeding
   tool: `./src/tools/Build-LibraryDiscIndex.ps1`. It will pick up
   the new album from its `MUSICBRAINZ_DISCID` tag.

## Inspecting the single-file image

`_image\<Album>.flac` is a concatenation of every per-track FLAC,
paired with a cue that maps INDEX 01 timestamps back to track
boundaries.

**You do not tag or promote this file.** It is a diagnostic artifact
for inspecting the rip in foobar2000 (or any cuesheet-aware player):

- Play through track boundaries without microsecond gaps.
- Scrub back and forth across pre-gaps.
- Verify HTOA (hidden track 00, e.g. *Her Majesty* on Abbey Road),
  missing pregaps, or off-by-a-few-frames track splits -- things that
  are awkward to hear when you have to manually advance between 12
  separate files.

It is the *"is this rip actually correct?"* view, not the
*"tag and ship"* view. If you only need to fix tags, ignore it
entirely; tag the per-track FLACs at the album root, promote, and
the `_image\` folder gets discarded on the way to the library.

Two ways to listen:

- **foobar2000:** open `_image\<Album>.cue` directly. The track list
  pulls from the cue.
- **WinCDEmu / Virtual CloneDrive:** mount the cue + flac as a virtual
  CD; play it like the original disc.

## Re-ripping a queue entry

Just reinsert the disc. The rip-time identification step recognizes
the disc id and offers **Rip again** vs **Skip**
([Show-DuplicateDiscDialog](../src/ui/Show-DuplicateDiscDialog.ps1)).
If you choose Rip again the new rip will land side-by-side under
`<Album> (<Year>) [rip 2]`; you can then delete whichever copy you
don't want.
