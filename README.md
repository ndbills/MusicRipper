# MusicRipper

A Windows + PowerShell 7 tool that rips Audio CDs to FLAC for a family
music-digitization project. Click "Rip a CD," confirm the auto-detected
metadata, walk away, and end up with a clean, AccurateRip-verified FLAC
library that can also be reconstructed back into a bit-identical Audio CD.

Built on **CUETools / CUERipper** for the rip engine, with an extensible
sync framework for pushing finished albums off the rip box (OneDrive in
Phase 6.2, Synology NAS over WireGuard in Phase 6.3+).

## Who this is for

- **You** (the engineer): runs the tool on your own machine, maintains it,
  clears the review queue when MusicBrainz can't identify a disc.
- **Your parents** (the eventual users): hand-held by a Desktop shortcut
  and a one-page quickstart. They never see PowerShell.

## Current status

| Phase | Title                                    | Status        |
| ----- | ---------------------------------------- | ------------- |
| 1     | Foundations & setup                      | ✅ complete    |
| 2     | Disc identification & metadata           | ✅ complete    |
| 3     | Confirmation UI                          | ✅ complete    |
| 4     | Rip engine                               | ✅ complete    |
| 5     | Quality gate, tagging, library layout    | ✅ complete    |
| 6.1   | Sync framework + LocalRetention + Stub   | ✅ complete    |
| 6.2   | OneDrive sync target                     | ✅ complete    |
| 6.3   | Synology NAS sync target (LAN)           | ✅ complete    |
| 6.4   | Synology NAS over WireGuard              | ⏳ not started |
| 7     | Polish, packaging, parent-friendly UX    | ⏳ not started |

## 3-line quickstart (engineer install)

```powershell
git clone <this-repo> C:\bin\MusicRipper ; cd C:\bin\MusicRipper
./setup/Install-Dependencies.ps1   # winget: PS7, CUETools, Picard
./setup/New-RipperConfig.ps1 ; ./setup/Register-Drive.ps1 ; ./setup/Install-Shortcut.ps1
```

After that, the Desktop shortcut **"Rip a CD"** is the entry point.
It identifies the disc, queries MusicBrainz, pops the confirm dialog,
and (on **Rip**) performs a secure FLAC rip with live progress, an
AccurateRip / CTDB verification pass, and an EAC-style CUE + log.
Clean rips are tagged (full Vorbis set + embedded cover + ReplayGain)
and filed under `<LibraryRoot>\<AlbumArtist>\<Album> (<Year>)\`.
Suspect rips, low-confidence MusicBrainz matches, and unknown discs
route to `<LibraryRoot>\_ReviewQueue\` with a `REVIEW.txt` and a
single-file `_image\<Album>.flac` for inspection.

## Directory map

```
MusicRipper/
├── setup/                          # One-time, run as admin
│   ├── Install-Dependencies.ps1    # winget: PS7, CUETools, Xiph.FLAC, Picard
│   ├── Register-Drive.ps1          # Detect drive + AccurateRip offset
│   ├── New-RipperConfig.ps1        # Create per-machine config.json
│   └── Install-Shortcut.ps1        # Desktop shortcut "Rip a CD"
│
├── src/
│   ├── Start-Ripper.ps1            # Entry point (parents click this)
│   ├── ui/                         # WPF dialogs (Phase 3+)
│   ├── core/                       # Disc-id, metadata, rip, tag (Phase 2-5)
│   ├── sync/                       # Per-album sync targets + retention (Phase 6.1+)
│   ├── tools/                      # Move-FromReviewQueue (Phase 7)
│   └── lib/
│       ├── Config.psm1             # config.json + DPAPI credential storage
│       ├── Logging.psm1            # Per-session log files
│       └── Common.psm1             # Path sanitization + shared helpers
│
├── config/
│   ├── config.template.json        # Library path, drive offset, sync targets
│   └── cuetools.profile.txt        # Pinned rip settings (annotated)
│
├── data/
│   └── driveoffsets.cached.json    # Fallback AccurateRip offsets
│
├── docs/
│   ├── ARCHITECTURE.md             # Diagrams + how the pieces fit together
│   ├── SETUP.md                    # Engineer install + drive calibration
│   ├── PARENTS-QUICKSTART.md       # Stub (Phase 7)
│   ├── REVIEW-WORKFLOW.md          # Stub (Phase 7)
│   ├── SYNC-TARGETS.md             # Sync framework + how to add a target (Phase 6.1+)
│   ├── SYNOLOGY-SHARE-SETUP.md     # Stub (Phase 6.3)
│   ├── DECISIONS.md                # Architectural decision log
│   └── TROUBLESHOOTING.md          # Common failures & fixes
│
└── tests/                          # Pester tests for pure-logic code
    ├── Common.Tests.ps1
    └── Config.Tests.ps1
```

## How the pieces fit together (one paragraph)

`Start-Ripper.ps1` is the orchestrator. On a real disc insert it will
identify the disc (`core/Get-DiscId`), fetch metadata (`core/Get-DiscMetadata`
→ MusicBrainz + Cover Art Archive), show a confirm dialog
(`ui/Show-MetadataDialog`), drive CUETools to perform a secure rip
(`core/Invoke-Rip`), grade the rip (`core/Test-RipQuality`), tag and embed
art (`core/Write-Tags`), file the album into the library or `_ReviewQueue/`
(`core/Move-ToLibrary`), and — if any sync targets are configured —
run the per-album sync chain (`sync/Invoke-RipperSync`) and apply the
local-retention rule (`sync/Invoke-LibraryRetention`) so successfully
synced albums can be moved aside or recycled. Per-machine state — library
path, drive offset, sync targets, NAS credentials — lives in
`%LOCALAPPDATA%\MusicRipper\config.json`. Logs go alongside it in `logs/`.

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — diagrams, pipeline, module map.
- [docs/SETUP.md](docs/SETUP.md) — engineer install + drive calibration.
- [docs/PARENTS-QUICKSTART.md](docs/PARENTS-QUICKSTART.md) — one-page user guide *(Phase 7)*.
- [docs/REVIEW-WORKFLOW.md](docs/REVIEW-WORKFLOW.md) — clearing `_ReviewQueue/` *(Phase 7)*.
- [docs/SYNC-TARGETS.md](docs/SYNC-TARGETS.md) — sync framework + how to add a target *(Phase 6.1+)*.
- [docs/SYNOLOGY-SHARE-SETUP.md](docs/SYNOLOGY-SHARE-SETUP.md) — DSM walkthrough *(Phase 6.3)*.
- [docs/DECISIONS.md](docs/DECISIONS.md) — running architectural decision log.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common failures & fixes.

## Running the tests

```powershell
Invoke-Pester ./tests
```

Pester 5+ is required (`Install-Module Pester -MinimumVersion 5.0`).
