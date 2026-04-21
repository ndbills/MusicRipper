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
                                                  (confirm/edit)
                                                             │
                                                             ▼
                                  [Invoke-Rip] ──► CUETools secure rip
                                                             │
                                                             ▼
                                              [Test-RipQuality]
                                                  ├─ pass ──► [Write-Tags] ──► [Move-ToLibrary] ──► [PostProcessors] ──► [Eject]
                                                  └─ fail ──► [_ReviewQueue]
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
| `src/Start-Ripper.ps1`             | 1→7   | Orchestrator (currently runs Phase 1+2 stubs).         |
| `src/core/Get-DiscId.ps1`          | 2     | Read TOC via CUETools .NET DLLs; emit MB disc id.      |
| `src/core/Get-DiscMetadata.ps1`    | 2     | MusicBrainz + Cover Art Archive lookup, throttled.     |
| `src/ui/Show-MetadataDialog.ps1`   | 3     | WPF confirm/edit dialog. Returns Rip / Review / Cancel. |
| `src/ui/Show-RipProgress.ps1`      | 4     | Non-modal progress window.                             |
| `src/core/Invoke-Rip.ps1`          | 4     | Drive CUETools to perform the secure rip.              |
| `src/core/Test-RipQuality.ps1`     | 5     | Parse rip log → Verified/Probably-good/Suspect.        |
| `src/core/Write-Tags.ps1`          | 5     | Vorbis tags, ReplayGain, embedded cover art.           |
| `src/core/Move-ToLibrary.ps1`      | 5     | Plex layout + `_ReviewQueue/` routing.                 |
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
