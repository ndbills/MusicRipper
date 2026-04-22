# Review Workflow

> **Status:** Phase 5 lands the queue itself. The `Move-FromReviewQueue.ps1`
> promote-helper is still pending in Phase 7.

When a rip can't be safely auto-filed into the main library, MusicRipper
routes it to `<LibraryRoot>\_ReviewQueue\` instead. This page is the
runbook for clearing that queue.

## When does an album end up here?

Four cases, each tagged with a folder-name prefix:

| Prefix      | Reason                                                         |
| ----------- | -------------------------------------------------------------- |
| `UNKNOWN`   | No MusicBrainz match for this disc id.                         |
| `LOWMATCH`  | MusicBrainz match below the confidence threshold.              |
| `SUSPECT`   | Rip log shows read errors, retries, or AccurateRip mismatches. |
| `MANUAL`    | You clicked **Send to Review** in the confirm dialog.          |

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

### `UNKNOWN` — no MusicBrainz match

1. Drag the album folder into **MusicBrainz Picard** and let it scan.
2. If Picard finds a match, accept it and **Save** — Picard rewrites
   the FLAC tags in place.
3. (Phase 7) Run `src/tools/Move-FromReviewQueue.ps1 <folder>` to
   relocate into the main library tree. Until that ships, move the
   folder by hand into `<LibraryRoot>\<AlbumArtist>\<Album> (<Year>)\`.
4. If Picard *also* can't identify it, the disc may genuinely be
   missing from MusicBrainz. Submit it from Picard's **Tools → Submit
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

### `MANUAL` — you sent it here on purpose

Fix whatever you noticed (wrong release year? bad cover art?), then
promote.

## Inspecting the single-file image

`_image/<Album>.flac` is a concatenation of every per-track FLAC,
paired with a cue that maps INDEX 01 timestamps back to track
boundaries. Two ways to listen:

- **foobar2000:** open `_image/<Album>.cue` directly. The track list
  pulls from the cue.
- **WinCDEmu / Virtual CloneDrive:** mount the cue + flac as a virtual
  CD; play it like the original disc.

The single-file image is **only generated for review-queue items**, not
the main library, so it never needs to be cleaned up after a successful
promote (Phase 7's `Move-FromReviewQueue.ps1` will drop `_image/` and
`REVIEW.txt` on the way).

## Re-ripping a queue entry

Just reinsert the disc. The rip-time identification step recognizes
the disc id and — once the loop in Phase 7 lands — will offer
**Replace** vs **Add as duplicate**. Until then, delete the old queue
folder by hand before re-ripping.
