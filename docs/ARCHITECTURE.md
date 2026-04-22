# Architecture

This is the map. Whenever a phase changes the pipeline shape, this file is
the first thing to update.

## Daily-flow sequence

```
[Insert disc]
      │
      ▼
[Start-Ripper.ps1] ──► [Get-DiscId] ──► [Get-DiscMetadata] ──┐
                                                             ▼
                                              [Show-MetadataDialog]
                                                  (confirm/edit/review)
                                                             │
                                                             ▼
                                  [Invoke-Rip] ──► CUETools secure rip
                                                             │
                                                             ▼
                                              [Test-RipQuality]
                                                             │
                            ┌── Verified / Probably-good ─┤
                            ▼                                ▼ Suspect / Unknown / LowMatch / Manual
                  [Write-Tags] (metaflac:                    │
                   Vorbis + cover + RG)                      │
                            │                                │
                            ▼                                ▼
                  [Move-ToLibrary]                 [Move-ToLibrary] (route=_ReviewQueue)
                            │                                │
                            ▼                                ▼
                            │           [Write-RipperReviewTxt] + [New-RipperReviewImage]
                            │                                │
                            └─────────────[Eject]─────────────┘
```

## Module map

| Component                          | Phase | Responsibility                                         |
| ---------------------------------- | ----- | ------------------------------------------------------ |
| `setup/Install-Dependencies.ps1`   | 1     | winget-install PS7, CUETools, Picard.                  |
| `setup/Register-Drive.ps1`         | 1     | Pick optical drive, find AccurateRip offset.           |
| `setup/New-RipperConfig.ps1`       | 1     | Interactive config build, DPAPI credential storage.    |
| `setup/Install-Shortcut.ps1`       | 1     | Desktop "Rip a CD" shortcut.                           |
| `src/lib/Config.psm1`              | 1     | config.json schema + DPAPI cred load/save.             |
| `src/lib/Logging.psm1`             | 1     | Per-session structured log files.                      |
| `src/lib/Common.psm1`              | 1     | Path sanitization, repo-root locator.                  |
| `src/lib/RipHelpers.psm1`          | 4     | Filename, CUE-sheet, ETA/speed formatters, log rollup. |
| `src/Start-Ripper.ps1`             | 1→7   | Orchestrator (currently runs Phase 1–5).               |
| `src/core/Get-DiscId.ps1`          | 2     | Read TOC via CUETools .NET DLLs; emit MB disc id.      |
| `src/core/Get-DiscMetadata.ps1`    | 2     | MusicBrainz + Cover Art Archive lookup, throttled.     |
| `src/ui/Show-MetadataDialog.ps1`   | 3     | WPF confirm/edit dialog. Returns Rip / Review / Cancel. |
| `src/ui/Show-RipProgress.ps1`      | 4     | Non-modal progress window (overall + per-track bars,    |
|                                    |       | elapsed, ETA, read speed, AR/CTDB status, Cancel).      |
| `src/core/Invoke-Rip.ps1`          | 4     | Secure FLAC rip via CUETools .NET DLLs (CDDriveReader   |
|                                    |       | + AccurateRip + CTDB + Flake encoder); emits CUE + log. |
| `src/core/Test-RipQuality.ps1`     | 5     | Parse rip log → Verified/ProbablyGood/Suspect/Unknown; |
|                                    |       | emit `RoutingPrefix` (`''`/`SUSPECT`/`UNKNOWN`/...).    |
| `src/core/Write-Tags.ps1`          | 5     | Vorbis tags, ReplayGain, embedded cover via metaflac.   |
| `src/core/Move-ToLibrary.ps1`      | 5     | Plex layout + sanitization + `_ReviewQueue/` routing.   |
| `src/core/New-ReviewQueueArtifacts.ps1` | 5 | `REVIEW.txt` + single-file `_image/<Album>.flac+cue`. |
| `src/postprocessors/*.ps1`         | 6     | Optional OneDrive / Synology mirror.                   |
| `src/tools/Move-FromReviewQueue.ps1` | 7   | Promote a fixed-up review-queue album into the library. |
| `Install-MusicRipper.ps1` (root)   | 7     | One-shot self-installer.                               |

## State on disk

```
%LOCALAPPDATA%\MusicRipper\
├── config.json           # per-machine config (never committed)
├── credentials.clixml    # DPAPI-protected NAS PSCredential, if any
└── logs\                 # one .log per setup or rip run
    └── <yyyyMMdd-HHmmss>-<context>.log
```

## Cross-cutting policies

- **Errors:** `throw` for unrecoverable; `Write-Warning` for recoverable;
  never silently swallow.
- **Secrets:** DPAPI via `Export-Clixml` only.
- **Paths:** every user-derived path component goes through
  `ConvertTo-SafeWindowsPathSegment` before reaching disk.
- **MusicBrainz:** 1 req/sec throttle + UA string with contact email
  (Phase 2).
- **CUETools rip settings:** pinned in `config/cuetools.profile.txt`
  with inline rationale.

## Library layout (final, Phase 5)

A successful rip lands directly in the Plex layout below. Suspect rips,
low-confidence MusicBrainz matches, and unknown discs route to
`_ReviewQueue/` with a `REVIEW.txt` plus a single-file inspection image
under `_image/`. See [REVIEW-WORKFLOW.md](REVIEW-WORKFLOW.md) for the
clear-the-queue runbook.

```
<LibraryRoot>/
  <Album Artist>/
    <Album> (<Year>)/
      01 - <Track Title>.flac
      ...
      cover.jpg
      <Album>.cue
      <Album>.log

  Various Artists/                    # COMPILATION=1 albums
    <Compilation> (<Year>)/
      01 - <Track Artist> - <Track Title>.flac
      ...

  _ReviewQueue/                       # suspect rips / no-match metadata
    <PREFIX> - <descriptor> - <discId>/
      ...
      _image/<Album>.flac (+ .cue)    # single-file image for inspection
      REVIEW.txt
```
