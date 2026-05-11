# MusicRipper

![MusicRipper — Secure CD ripping for a bit-perfect FLAC library](assets/musicripper-hero.png)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Pester](https://github.com/ndbills/MusicRipper/actions/workflows/pester.yml/badge.svg?branch=main)](https://github.com/ndbills/MusicRipper/actions/workflows/pester.yml)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg?logo=powershell)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
[![Windows](https://img.shields.io/badge/platform-Windows-0078D6.svg?logo=windows)](#)

> **Disclaimer.** MusicRipper is not affiliated with or endorsed by Plex,
> MusicBrainz, the CUETools project, the WireGuard project, Apple, Deezer,
> or Illustrate (AccurateRip / dBpoweramp). Trademarks belong to their
> respective owners.

A Windows + PowerShell 7 tool that rips Audio CDs to FLAC for a family
music-digitization project. Click "Rip a CD," confirm the auto-detected
metadata, walk away, and end up with a clean, AccurateRip-verified FLAC
library that can also be reconstructed back into a bit-identical Audio CD.

Built on **CUETools / CUERipper** for the rip engine, with an extensible
sync framework for pushing finished albums off the rip box (OneDrive +
Synology NAS over WireGuard).

## Who this is for

- **You** (the engineer): runs the tool on your own machine, maintains it,
  clears the review queue when MusicBrainz can't identify a disc.
- **Your parents** (the eventual users): hand-held by a Desktop shortcut
  and a one-page quickstart. They never see PowerShell.

> **You'll need a CD drive that supports raw audio reads.** Most retail
> CD/DVD/Blu-ray drives sold in the last 10+ years work out of the box,
> but a class of older OEM tray drives (notably the **TSSTcorp TS-H65x**
> family that shipped pre-installed in many ~2008-2010 HP / Dell / Compaq
> desktops) can identify and play discs but reject the SCSI commands
> MusicRipper needs to rip them. If your fatal-error dialog mentions
> *"This CD drive cannot rip audio CDs"* or the log shows
> `ILLEGAL MODE FOR THIS TRACK`, see the *"CD drive cannot rip audio CDs"*
> section in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the
> diagnosis + a known-good drive list. (A modern external USB CD drive
> from ASUS / LG / Pioneer is ~$20-25 and will work.)

## Current status

**Feature-complete.** Initial development closed out the rip pipeline,
quality gating, library layout, three sync targets, WireGuard auto-toggle,
the WPF first-run + settings editor, and the parent-friendly polish pass.
See [docs/DECISIONS.md](docs/DECISIONS.md) for the architectural decision
log and the reasoning behind each choice.

<details>
<summary>Development phase history</summary>

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
| 6.5   | Startup pending-sync resync UI           | ✅ complete    |
| 6.4   | Synology NAS over WireGuard              | ✅ complete    |
| 6.4.1 | Refcounted WG tunnel lifecycle           | ✅ complete    |
| 6.6   | WPF first-run + config editor overhaul   | ✅ complete    |
| 7     | Polish, packaging, parent-friendly UX    | ✅ complete    |
| F-6   | Standalone Settings Start Menu shortcut  | ✅ complete    |

</details>

## 3-line quickstart (engineer install)

```powershell
git clone https://github.com/ndbills/MusicRipper.git C:\bin\MusicRipper ; cd C:\bin\MusicRipper
./Install-MusicRipper.ps1 -InPlace   # chains setup steps; or omit -InPlace to copy into %LOCALAPPDATA%\MusicRipper
# Then double-click the new "MusicRipper - Rip a CD" Desktop shortcut. First launch opens the WPF Settings editor.
```

To uninstall later: `./Uninstall-MusicRipper.ps1` removes the desktop
shortcut, dependency winget packages (CUETools, Xiph.FLAC, Picard,
WireGuard), the WireGuard tunnel service, and `%LOCALAPPDATA%\MusicRipper\`
(config + credentials + logs). Your music library is never touched, and
PowerShell 7 stays installed. The script self-elevates if needed (one UAC
prompt at launch). Add `-WhatIf` to preview without changing anything.

On first launch the WPF settings editor opens (library root, MusicBrainz
contact address, drive registration with progress bar, OneDrive / Synology
NAS sync targets, WireGuard `.conf` picker). Save and you're ripping.

After setup the shortcut identifies each inserted disc, queries
MusicBrainz, pops the confirm dialog, and (on **Rip**) performs a
secure FLAC rip with live progress, an AccurateRip / CTDB verification
pass, and an EAC-style CUE + log. Clean rips are tagged (full Vorbis
set + embedded cover + ReplayGain) and filed under
`<LibraryRoot>\<AlbumArtist>\<Album> (<Year>)\`. Suspect rips,
low-confidence MusicBrainz matches, and unknown discs route to
`<LibraryRoot>\_ReviewQueue\` with a `REVIEW.txt` and a single-file
`_image\<Album>.flac` for inspection.

## Directory map

```
MusicRipper/
├── Install-MusicRipper.ps1         # One-shot installer (chains setup steps)
├── Uninstall-MusicRipper.ps1       # Symmetric uninstaller (self-elevates)
│
├── setup/                          # Install chain steps + per-feature setup
│   ├── Install-Dependencies.ps1    # winget: PS7, CUETools, Xiph.FLAC, Picard, WireGuard
│   ├── Register-Drive.ps1          # Detect drive + AccurateRip offset (also called from WPF)
│   ├── New-RipperConfig.ps1        # Headless config wizard (WPF editor preferred)
│   ├── Install-Shortcut.ps1        # Desktop shortcut "MusicRipper - Rip a CD"
│   ├── Install-UninstallShortcut.ps1   # In-repo "Uninstall MusicRipper.lnk"
│   └── Install-StartMenuShortcuts.ps1  # Start Menu "MusicRipper - Rip a CD" + "Settings" + "Uninstall"
│
├── assets/                         # App icons + hero banner
│   ├── musicripper.ico             # Multi-resolution icon for shortcuts
│   ├── musicripper.svg             # Vector source
│   ├── musicripper-hero.png        # README hero banner
│   └── logo-concepts/              # Design-exploration archive (not shipped)
│
├── src/
│   ├── Start-Ripper.ps1            # Entry point (parents click this)
│   ├── ui/                         # WPF dialogs (Phase 3+)
│   ├── core/                       # Disc-id, metadata, rip, tag (Phase 2-5)
│   ├── sync/                       # Per-album sync targets + retention (Phase 6.1+)
│   ├── tools/                      # Move-FromReviewQueue (Phase 7), Show-RipperConfig (F-6)
│   └── lib/
│       ├── Config.psm1             # config.json + DPAPI credential storage
│       ├── Logging.psm1            # Per-session log files
│       ├── Wireguard.psm1          # Per-tunnel WG service control + refcount
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
│   ├── PARENTS-QUICKSTART.md       # One-page parent walkthrough with screenshots
│   ├── REVIEW-WORKFLOW.md          # Clearing _ReviewQueue/ + Move-FromReviewQueue helper
│   ├── SYNC-TARGETS.md             # Sync framework + how to add a target
│   ├── SYNOLOGY-SHARE-SETUP.md     # DSM walkthrough (Phase 6.3)
│   ├── DECISIONS.md                # Architectural decision log
│   ├── TROUBLESHOOTING.md          # Common failures & fixes
│   └── images/                     # Quickstart screenshots
│
└── tests/                          # Pester tests for pure-logic code
    └── *.Tests.ps1                 # 522 tests across ~30 modules
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
- [docs/PARENTS-QUICKSTART.md](docs/PARENTS-QUICKSTART.md) — one-page user guide.
- [docs/REVIEW-WORKFLOW.md](docs/REVIEW-WORKFLOW.md) — clearing `_ReviewQueue/` + Move-FromReviewQueue helper.
- [docs/SYNC-TARGETS.md](docs/SYNC-TARGETS.md) — sync framework + how to add a target *(Phase 6.1+)*.
- [docs/SYNOLOGY-SHARE-SETUP.md](docs/SYNOLOGY-SHARE-SETUP.md) — DSM walkthrough *(Phase 6.3)*.
- [docs/DECISIONS.md](docs/DECISIONS.md) — running architectural decision log.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common failures & fixes.

## Running the tests

```powershell
Invoke-Pester ./tests
```

Pester 5+ is required (`Install-Module Pester -MinimumVersion 5.0`).

## License

MusicRipper is released under the MIT License. See [LICENSE](LICENSE) for
the full text.

## Acknowledgements

MusicRipper is built on top of, and gratefully acknowledges, a number of
third-party tools and services. See [NOTICE.md](NOTICE.md) for the full
list (and [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md) for a structured
table view).

> **Deezer usage is non-commercial only.** The Deezer API provider is enabled by
> default for cover-art and text-search fallback. Per
> [Deezer's developer terms of use](https://developers.deezer.com/termsofuse)
> (Section IV), use of Deezer Content is *"strictly limited for a non-commercial
> purpose...within a family scope."* That maps cleanly onto MusicRipper's stated
> mission, but if you're repurposing this tool for paid work (DJ catalogs,
> commercial archives, etc.) **disable the Deezer providers** in your config
> (`Settings -> Metadata` and `Settings -> Cover Art` tabs, or remove `"Deezer"`
> from `MetadataProviders` / `CoverArtProviders` in `config.json`). MusicBrainz,
> Cover Art Archive, and iTunes Search remain available without that limitation.
