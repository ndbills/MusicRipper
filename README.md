# MusicRipper

A Windows + PowerShell 7 tool that rips Audio CDs to FLAC for a family
music-digitization project. Click "Rip a CD," confirm the auto-detected
metadata, walk away, and end up with a clean, AccurateRip-verified FLAC
library that can also be reconstructed back into a bit-identical Audio CD.

Built on **CUETools / CUERipper** for the rip engine, with optional
OneDrive and Synology NAS sync post-processors.

## Who this is for

- **You** (the engineer): runs the tool on your own machine, maintains it,
  clears the review queue when MusicBrainz can't identify a disc.
- **Your parents** (the eventual users): hand-held by a Desktop shortcut
  and a one-page quickstart. They never see PowerShell.

## Current status

| Phase | Title                                    | Status        |
| ----- | ---------------------------------------- | ------------- |
| 1     | Foundations & setup                      | ✅ complete    |
| 2     | Disc identification & metadata           | ⏳ not started |
| 3     | Confirmation UI                          | ⏳ not started |
| 4     | Rip engine                               | ⏳ not started |
| 5     | Quality gate, tagging, library layout    | ⏳ not started |
| 6     | Optional post-processors (OneDrive, NAS) | ⏳ not started |
| 7     | Polish, packaging, parent-friendly UX    | ⏳ not started |

## 3-line quickstart (engineer install)

```powershell
git clone <this-repo> C:\bin\MusicRipper ; cd C:\bin\MusicRipper
./setup/Install-Dependencies.ps1   # winget: PS7, CUETools, Picard
./setup/New-RipperConfig.ps1 ; ./setup/Register-Drive.ps1 ; ./setup/Install-Shortcut.ps1
```

After that, the Desktop shortcut **"Rip a CD"** is the entry point.
(Today it shows a Phase-1 stub message box; rip logic lands in Phase 4.)

## Directory map

```
MusicRipper/
├── setup/                          # One-time, run as admin
│   ├── Install-Dependencies.ps1    # winget: PS7, CUETools, Picard
│   ├── Register-Drive.ps1          # Detect drive + AccurateRip offset
│   ├── New-RipperConfig.ps1        # Create per-machine config.json
│   └── Install-Shortcut.ps1        # Desktop shortcut "Rip a CD"
│
├── src/
│   ├── Start-Ripper.ps1            # Entry point (parents click this)
│   ├── ui/                         # WPF dialogs (Phase 3+)
│   ├── core/                       # Disc-id, metadata, rip, tag (Phase 2-5)
│   ├── postprocessors/             # OneDrive / Synology sync (Phase 6)
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
│   ├── SYNOLOGY-SHARE-SETUP.md     # Stub (Phase 6)
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
(`core/Move-ToLibrary`), and finally hand off to the optional
post-processors. Per-machine state — library path, drive offset, NAS
credentials — lives in `%LOCALAPPDATA%\MusicRipper\config.json`.
Logs go alongside it in `logs/`.

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — diagrams, pipeline, module map.
- [docs/SETUP.md](docs/SETUP.md) — engineer install + drive calibration.
- [docs/PARENTS-QUICKSTART.md](docs/PARENTS-QUICKSTART.md) — one-page user guide *(Phase 7)*.
- [docs/REVIEW-WORKFLOW.md](docs/REVIEW-WORKFLOW.md) — clearing `_ReviewQueue/` *(Phase 7)*.
- [docs/SYNOLOGY-SHARE-SETUP.md](docs/SYNOLOGY-SHARE-SETUP.md) — DSM walkthrough *(Phase 6)*.
- [docs/DECISIONS.md](docs/DECISIONS.md) — running architectural decision log.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common failures & fixes.

## Running the tests

```powershell
Invoke-Pester ./tests
```

Pester 5+ is required (`Install-Module Pester -MinimumVersion 5.0`).
