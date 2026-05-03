# Project: MusicRipper — Family CD Digitization Tool

You are an expert PowerShell engineer. You will implement a Windows + PowerShell 7 tool that rips Audio CDs to FLAC for a family music-digitization project. The full plan is below. Follow it exactly. Do not deviate without asking.

## Your operating rules

1. **Work one phase at a time, in order.** Do not begin Phase N+1 until Phase N's verification passes and its docs are updated. Confirm phase completion with me before moving on.
2. **Phase 4 starts with a spike** (see Phase 4 below) — do that first, then report results before writing the rest of Phase 4.
3. **Commit per logical unit** using Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`). Each commit must leave the repo in a working state.
4. **Docs are part of "done."** A phase is not complete until its code, tests, AND docs are all updated in the same commit (or commit chain) — including the root `README.md`'s "Current status" section.
5. **Ask before deviating** from the plan, choosing a different library, or expanding scope. Otherwise, proceed.
6. **Do not over-engineer.** Implement only what the plan specifies. No speculative features, no abstractions for one-time operations, no error handling for impossible cases.
7. **Read before you write.** When modifying existing files, read them fully first. Prefer editing over creating.

## Coding conventions

- **PowerShell 7+** only. Use approved verbs (`Get-`, `New-`, `Invoke-`, `Test-`, `Write-`, `Move-`, `Sync-`, `Show-`, `Install-`, `Register-`, `Start-`).
- **Comment-based help** on every public function: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (each), `.EXAMPLE` (≥1 realistic), `.NOTES` (gotchas + relevant external links).
- **File header block** at the top of every script/module: purpose, where it sits in the pipeline, key dependencies.
- **Inline comments explain *why*, not *what*** — especially for non-obvious choices (gap-append mode, AccurateRip offset, Plex compilation rules, MusicBrainz throttle, DPAPI).
- **Annotate config files heavily** — every setting in `cuetools.profile.txt` and `config.template.json` gets a one-line comment.
- **Pester tests** alongside any pure-logic code. File naming: `<thing>.Tests.ps1` under `tests/`.
- **Errors:** use `throw` for unrecoverable errors, `Write-Warning` for recoverable; never silently swallow.
- **Logging:** structured logs via the `Logging` module (Phase 1) to `%LOCALAPPDATA%\MusicRipper\logs\`.
- **Secrets:** DPAPI via `Export-Clixml` / `Import-Clixml`. Never plaintext.
- **Paths:** always use `Join-Path`. Sanitize per Windows rules before writing user-derived path components.
- **No external runtime** beyond PS7 + WPF (which ships with .NET).

## Definition of "done" per phase

A phase is complete when ALL of the following are true:

- [ ] All scripts/modules listed in that phase exist and are functional
- [ ] Every public function has comment-based help
- [ ] Pester tests for any pure-logic code, all passing
- [ ] Phase-specific verification step (listed in the plan) executed and confirmed
- [ ] Relevant docs under `docs/` updated (and created if they don't exist yet)
- [ ] Root `README.md` "Current status" section reflects the new phase as complete
- [ ] `docs/DECISIONS.md` updated if any new architectural choices were made or alternatives were rejected
- [ ] Conventional-commit history is clean and each commit builds
- [ ] You report completion to me with: a one-paragraph summary, the test results, the list of new/changed files, and any items that need my manual verification (e.g., "please rip a real disc and confirm")

## Repository conventions

- Init as a Git repo on the first commit (`chore: initialize repository`).
- `.gitignore` should exclude `*.flac`, `*.log` under runtime locations, `%LOCALAPPDATA%` artifacts, and any local `config.json` (only `config.template.json` is committed).
- Branch: work on `main` directly unless I ask otherwise.

---

# THE PLAN

# Plan: MusicRipper — Family CD Digitization Tool

A Windows + PowerShell tool that lets the user (and eventually their parents) click "Rip Disc," confirm/edit the auto-detected metadata, walk away, and end up with a clean, AccurateRip-verified FLAC library that can also be reconstructed back to an identical Audio CD. Built on **CUETools / CUERipper** for the rip engine, with an optional NAS/OneDrive sync post-processor.

## Architecture at a glance

```
MusicRipper/
├── setup/                          # One-time, run as admin
│   ├── Install-Dependencies.ps1    # winget: PS7, CUETools, optional Picard
│   ├── Register-Drive.ps1          # Detect drive + AccurateRip offset
│   ├── New-RipperConfig.ps1        # Create per-machine config.json
│   └── Install-Shortcut.ps1        # Desktop shortcut "Rip a CD"
│
├── src/
│   ├── Start-Ripper.ps1            # Entry point (parents click this)
│   ├── ui/
│   │   ├── Show-MetadataDialog.ps1 # WPF confirm/edit dialog
│   │   └── Show-RipProgress.ps1    # WPF progress window
│   ├── core/
│   │   ├── Get-DiscId.ps1          # MusicBrainz disc ID from TOC
│   │   ├── Get-DiscMetadata.ps1    # Query MusicBrainz + Cover Art Archive
│   │   ├── Invoke-Rip.ps1          # Wraps CUETools CLI ripper
│   │   ├── Test-RipQuality.ps1     # Parse log, check AccurateRip status
│   │   ├── Write-Tags.ps1          # metaflac tag + embed cover
│   │   └── Move-ToLibrary.ps1      # Final layout + _ReviewQueue routing
│   ├── postprocessors/             # Optional, enabled via config
│   │   ├── Sync-ToOneDrive.ps1
│   │   └── Sync-ToSynologyNAS.ps1  # SMB copy w/ retry
│   └── lib/
│       ├── Config.psm1             # Load/save config.json
│       ├── Logging.psm1            # Structured logs to %LOCALAPPDATA%
│       └── Common.psm1
│
├── config/
│   ├── config.template.json        # Library path, drive offset, sync targets
│   └── cuetools.profile.txt        # Pinned rip settings (see Decisions)
│
├── docs/
│   ├── PARENTS-QUICKSTART.md       # 1-page, screenshot-heavy
│   ├── SETUP.md                    # For you
│   └── SYNOLOGY-SHARE-SETUP.md     # Optional NAS guide
│
└── tests/
    └── Pester tests for pure-logic modules (parsers, config, layout)
```

**Daily-flow sequence:**

```
[Insert disc]
      │
      ▼
[Start-Ripper.ps1]──► [Get-DiscId] ──► [Get-DiscMetadata] ──┐
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

---

## Documentation & code-comment standards (cross-cutting)

Applies to every phase. The goal: you (or a future helper) can return after months and understand both *how* and *why* without reverse-engineering.

**In code:**
- Every public PowerShell function gets full **comment-based help**: `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (each), `.EXAMPLE` (at least one realistic invocation), `.NOTES` (gotchas, links to MusicBrainz/CUETools/Plex docs where relevant).
- Each script/module file starts with a **header block**: purpose, where it sits in the pipeline, key dependencies.
- Inline comments explain **why**, not what — especially for non-obvious choices (gap-append mode, AccurateRip offset lookup, Plex compilation rules, MusicBrainz throttle, DPAPI credential storage).
- `cuetools.profile.txt` and `config.template.json` are heavily annotated; every setting has a one-line comment explaining its effect.

**Repo-level docs (under `docs/`):**
- `README.md` (root) — **the front door of the project**, kept current with every phase. Contents: what this is, who it's for, current status (which phases are complete), 3-line quickstart, full directory map, links to every doc under `docs/`, and a short "how the pieces fit together" summary. This is the file you (or anyone) opens first to re-orient on the project.
- `docs/ARCHITECTURE.md` — the diagrams and pipeline from this plan, kept current; the "map" of how components fit together.
- `docs/SETUP.md` — for you: full install + drive calibration + config walkthrough.
- `docs/PARENTS-QUICKSTART.md` — one page, screenshot-heavy, for non-technical users.
- `docs/REVIEW-WORKFLOW.md` — clearing `_ReviewQueue/` (Picard re-tag, mounting `_image/`, re-rip).
- `docs/SYNOLOGY-SHARE-SETUP.md` — DSM walkthrough for the optional NAS post-processor.
- `docs/DECISIONS.md` — running log of architectural decisions (why CUETools vs EAC, why gap-append-to-previous, why Plex layout, etc.) so future-you knows what was already considered and rejected.
- `docs/TROUBLESHOOTING.md` — common failures and fixes (MusicBrainz down, drive offset wrong, scratched disc, Picard not finding album), grown organically as issues come up.

**Per-phase deliverable:** docs touched by a phase are updated *in the same commit* as the code, not deferred. A phase isn't "done" until its docs are current.

### Phase 1 — Foundations & setup (no rip logic yet)
1. Initialize repo layout above; add PS7 module manifests for `Config`, `Logging`, `Common`.
2. `Install-Dependencies.ps1` — install via winget: `Microsoft.PowerShell`, `CUETools.CUETools`, `MusicBrainz.Picard` (used for the Review-Queue fix-up workflow).
3. `Register-Drive.ps1` — enumerate optical drives via CIM (`Win32_CDROMDrive`), let user pick if multiple, look up the drive's AccurateRip offset from the AccurateRip database (`http://www.accuraterip.com/driveoffsets.htm` HTML scrape with cached fallback list bundled in repo), persist to `config.json`.
4. `New-RipperConfig.ps1` — interactive prompts: library root path, optional OneDrive path, optional Synology share UNC + credential (stored via `Export-Clixml` DPAPI). Writes `%LOCALAPPDATA%\MusicRipper\config.json`.
5. `Install-Shortcut.ps1` — creates a Desktop `.lnk` "Rip a CD" pointing at `pwsh -File Start-Ripper.ps1`, with the MusicRipper icon.

*Verify:* run all four setup scripts on a clean Win11 VM/machine; confirm config is written and shortcut launches a "Hello" stub of `Start-Ripper.ps1`.

### Phase 2 — Disc identification & metadata
1. `Get-DiscId.ps1` — read TOC via CUETools' command-line tools (CUETools ships `CUETools.eac.exe`/`CUERipper.exe` which can emit a disc-id); fallback to libdiscid binding via a small bundled helper.
2. `Get-DiscMetadata.ps1` — call MusicBrainz web service v2 (`https://musicbrainz.org/ws/2/discid/<id>?inc=artists+recordings+release-groups`), pick the best release (heuristic: prefer release with cover art, country match, earliest date), fetch cover art from Cover Art Archive (`https://coverartarchive.org/release/<mbid>/front`).
3. Build a normalized metadata object: `{ AlbumArtist, Album, Year, Genre, DiscNumber, TotalDiscs, Tracks[{Number, Title, Artist, Length}], CoverArtBytes }`.
4. Handle the "no match" and "multiple matches" cases — return a candidates array.

*Verify:* unit-test the MusicBrainz response parser with 3 fixture JSONs (single match, multi-match, no match). Manual: identify 5 real discs (one classical, one compilation, one multi-disc, one obscure indie, one mainstream).

### Phase 3 — Confirmation UI (parallel with Phase 2 once contracts are stable)
1. `Show-MetadataDialog.ps1` — WPF dialog (PowerShell + XAML) showing: cover art thumbnail, editable Album/Artist/Year fields, editable per-track titles in a DataGrid, dropdown to switch between MusicBrainz match candidates, "Re-search MusicBrainz" button, "Rip" / "Cancel" / "Send to Review (rip with placeholder tags)" buttons.
2. Returns the (possibly-edited) metadata object or `$null` on cancel.

*Verify:* launch dialog with each of the 3 fixture metadata objects; confirm edits round-trip; confirm Cancel ejects the disc and exits cleanly.

### Phase 4 — Rip engine
1. `Invoke-Rip.ps1` — invoke CUETools' command-line ripper (`CUETools.ConsoleRipper.exe` or equivalent; if no suitable CLI is available, fall back to driving `CUERipper.exe` with a pre-baked profile and watching its output folder). Settings pinned by `cuetools.profile.txt`:
   - Output: per-track FLAC, level 8
   - Gap handling: **Append to previous track (noncompliant)** — preserves all audio for reconstruction
   - Generate EAC-style **CUE sheet** referencing the per-track FLACs
   - Generate AccurateRip + CTDB log
   - Embed cover art via metaflac after rip
2. `Show-RipProgress.ps1` — non-modal progress window driven by stdout parsing of the ripper (track N of M, % complete, current AR confidence).
3. Pipe ripper output into structured log under `%LOCALAPPDATA%\MusicRipper\logs\<timestamp>-<album>.log`.

*Verify:* rip 3 known-good discs end-to-end; diff per-track FLAC checksums against a reference rip from CUERipper GUI to confirm bit-identical output.

### Phase 5 — Quality gate, tagging, library layout
1. `Test-RipQuality.ps1` — parse the rip log; classify as:
   - **Verified** (all tracks AccurateRip- or CTDB-verified)
   - **Probably good** (rip completed, no errors, but disc not in AR/CTDB databases)
   - **Suspect** (any read error, retry, or AR mismatch)
2. `Write-Tags.ps1` — apply the full Vorbis tag set via `metaflac.exe` (ships with CUETools). Required tags for Plex matching: `ALBUMARTIST`, `ARTIST`, `ALBUM`, `TITLE`, `TRACKNUMBER`, `TRACKTOTAL`, `DISCNUMBER`, `DISCTOTAL`, `DATE` (year only), `GENRE`, `COMPILATION` (`1` for VA albums), `MUSICBRAINZ_ALBUMID`, `MUSICBRAINZ_ARTISTID`, `MUSICBRAINZ_ALBUMARTISTID`, `MUSICBRAINZ_TRACKID`. Compute ReplayGain (`REPLAYGAIN_TRACK_GAIN/PEAK`, `REPLAYGAIN_ALBUM_GAIN/PEAK`) via `metaflac --add-replay-gain` over the full album. Embed cover art in every FLAC (Plex uses embedded art for Now Playing) AND write `cover.jpg` to the album folder (Plex uses file art for the album grid).
3. `Move-ToLibrary.ps1` — final layout follows the **Plex-recommended music structure** (also compatible with Navidrome, Jellyfin, foobar2000, MusicBee):
   ```
   <LibraryRoot>/
     <Album Artist>/
       <Album> (<Year>)/
         01 - <Track Title>.flac
         ...
         cover.jpg            # Plex picks this up; also embedded in each FLAC
         <Album>.cue          # for re-burning; ignored by players
         <Album>.log          # rip proof; ignored by players

     Various Artists/         # all compilations land here (COMPILATION=1 tag)
       <Compilation> (<Year>)/
         01 - <Track Artist> - <Track Title>.flac
         ...

     <Album Artist>/
       <Album> (<Year>)/
         Disc 1/              # multi-disc as subfolders
           01 - <Track Title>.flac
         Disc 2/
           01 - <Track Title>.flac
         cover.jpg
   ```
   Rules: top-level folder is **Album Artist** (not track artist) so guest features don't fragment the library; compilations always go under `Various Artists/`; year is `(YYYY)` suffix on the album folder; sanitize Windows-illegal chars (`< > : " / \ | ? *`) by replacing with a single space and collapsing whitespace; trim trailing dots and spaces (Windows path rules).

   **Review-Queue routing.** Suspect rips (read errors / AR mismatch / CTDB mismatch), no-metadata-match rips, low-confidence-match rips, and user-flagged "Send to Review" rips go to `<LibraryRoot>/_ReviewQueue/` instead. Per-album folder layout in the queue:
   ```
   _ReviewQueue/
     <PREFIX> - <descriptor> - <discId>/
       01 - <Track>.flac    ...    <Album>.cue    <Album>.log    cover.jpg (if any)
       _image/
         <Album>.flac        # single-file image, generated via CUETools (~5s)
         <Album>.cue         # cue pointing at the single-file image
       REVIEW.txt
   ```
   Folder-name prefix conventions:
   - `UNKNOWN - <ripDate> - <NNtracks> <MMmSSs> - <discId>` — no MusicBrainz match
   - `LOWMATCH - <Artist> - <Album> - <discId>` — match below confidence threshold
   - `SUSPECT - <Artist> - <Album> - <discId>` — rip-quality issue
   - `MANUAL - <Artist> - <Album> - <discId>` — user clicked "Send to Review"

   `REVIEW.txt` is a simple `Key: Value` file with: `Reason`, `RipDate`, `DiscId`, `MusicBrainzMatch` (none / low-confidence:NN% / mbid), `Tracks`, `Duration`, `SuggestedAction`, `LogFile`. Single-file image under `_image/` is generated **only for `_ReviewQueue` items** (not main library) so it can be mounted/scrubbed during inspection.

*Verify:* Pester tests for the path-sanitization and multi-disc layout logic. Manual: rip a known-bad (scratched) disc and confirm it lands in `_ReviewQueue` with a useful `REVIEW.txt`.

### Phase 6 — Optional post-processors
1. `Sync-ToOneDrive.ps1` — `robocopy /MIR` from library to a configured OneDrive subfolder, log result. Skipped silently if not configured.
2. `Sync-ToSynologyNAS.ps1` — `robocopy` over SMB to a UNC path with stored credentials; retry on transient failures; `_ReviewQueue` excluded by default (configurable). Both invoked from `Start-Ripper.ps1` after `Move-ToLibrary` succeeds.
3. `docs/SYNOLOGY-SHARE-SETUP.md` — screenshot walkthrough: DSM → Shared Folder → Permissions → SMB enable → grab UNC.

*Verify:* enable each post-processor against a temp folder and a real Synology share; confirm idempotent re-runs and that disabling them is a no-op.

### Phase 7 — Polish, packaging, parent-friendly UX
1. `docs/PARENTS-QUICKSTART.md` — one page: insert disc → click "Rip a CD" → confirm metadata → wait for green check → eject.
2. `docs/REVIEW-WORKFLOW.md` — short guide for clearing `_ReviewQueue/`: how to read `REVIEW.txt`, how to drag a folder into MusicBrainz Picard for re-tagging, how to mount `_image/<Album>.flac` for inspection (foobar2000 or WinCDEmu/Virtual CloneDrive), how to re-rip (just reinsert disc — tool detects existing queue entry and offers replace).
3. `src/tools/Move-FromReviewQueue.ps1` — helper that takes a now-properly-tagged review folder and relocates it into the main library tree using the standard sanitized layout (drops `_image/` and `REVIEW.txt` on the way).
4. Self-contained installer: a single `Install-MusicRipper.ps1` at repo root that clones/copies into `%LOCALAPPDATA%\MusicRipper`, runs Phase 1 setup scripts in order, ends with a "you're ready" message.
5. Start-Ripper top-level error handler: any uncaught exception → friendly dialog ("Something went wrong, the disc was not damaged. Please tell <you> and share the log file at this location.") with "Copy log path" button.
6. Add a "Rip another disc" loop at the end of a successful rip so parents can batch through a stack.

*Verify:* fresh-machine end-to-end test using only `PARENTS-QUICKSTART.md` instructions. Time how long a 12-track disc takes start-to-eject.

---

## Relevant files (to be created — empty repo today)

- `setup/Install-Dependencies.ps1`, `setup/Register-Drive.ps1`, `setup/New-RipperConfig.ps1`, `setup/Install-Shortcut.ps1`
- `src/Start-Ripper.ps1` — orchestrator, owns the daily-flow sequence
- `src/core/*.ps1` — each step is one script with a single exported function
- `src/ui/*.ps1` — WPF dialogs (XAML inline)
- `src/lib/*.psm1` — shared modules
- `config/config.template.json`, `config/cuetools.profile.txt`
- `docs/PARENTS-QUICKSTART.md`, `docs/SETUP.md`, `docs/SYNOLOGY-SHARE-SETUP.md`, `docs/REVIEW-WORKFLOW.md`
- `src/tools/Move-FromReviewQueue.ps1`
- `Install-MusicRipper.ps1` (root, top-level installer)
- `tests/*.Tests.ps1` (Pester)

## Decisions

- **Ripper:** CUETools / CUERipper. Drive via CLI if a working CLI ripper is available in the current CUETools build; otherwise wrap `CUERipper.exe` in auto-rip-on-insert mode with a pre-baked profile and watch its output folder. (To be confirmed in Phase 4 spike.)
- **Output format:** Per-track FLAC level 8 + CUE sheet + log + embedded cover, with **gap-append-to-previous** mode so the disc is reconstructable from the FLACs + CUE.
- **Language/runtime:** PowerShell 7, WPF for any UI (no extra runtime).
- **Config storage:** `%LOCALAPPDATA%\MusicRipper\config.json`; secrets (Synology creds) via DPAPI `Export-Clixml`.
- **Metadata source:** MusicBrainz primary, Cover Art Archive for art. No paid services.
- **Confirmation UX:** Always show the dialog (your preference), with a "Send to Review" escape hatch for discs you don't want to babysit.
- **Bad rips & bad metadata:** routed to `_ReviewQueue/` with a `REVIEW.txt`; never block the next disc.
- **Distribution:** single repo + `Install-MusicRipper.ps1`. Same code on your PC and theirs; per-machine `config.json` differentiates behavior (e.g., NAS sync only enabled on yours).
- **Out of scope (for now):** automatic library merging across machines, mobile UI, non-CD audio (DVD-A/SACD), Linux/macOS support.

## Verification (cross-cutting)

1. **Unit:** Pester tests for all pure-logic code (MusicBrainz parser, path sanitizer, log parser, config loader).
2. **Integration:** rip a fixed set of 5 reference discs (mainstream, classical, compilation, multi-disc, obscure indie) and diff outputs against a known-good baseline.
3. **Failure-mode:** scratched disc → lands in `_ReviewQueue`; no internet → metadata step degrades to "rip with placeholder tags, send to review"; wrong drive offset → `Register-Drive.ps1` re-run fixes it.
4. **UX:** parent-test — hand the QUICKSTART to someone unfamiliar and watch them rip 3 discs without help.

## Further considerations

1. **CLI ripper availability** — CUETools' command-line rip support has varied across versions. **Recommendation:** start Phase 4 with a 1–2 hour spike to confirm CLI ripping works with the current CUETools build; if not, switch to driving CUERipper GUI in auto-mode and watching its output folder. Same downstream pipeline either way.
2. **MusicBrainz rate limits** — 1 req/sec anonymous. **Recommendation:** add a polite throttle + a custom User-Agent string identifying MusicRipper + your contact email (MB requires this).
3. **Pre-emphasis & odd discs** — extremely rare on consumer CDs, but if encountered the FLAC needs a `PRE_EMPHASIS` tag for accurate playback. **Recommendation:** detect via the rip log and auto-tag; flag to `_ReviewQueue` if uncertain.

---

## Start here

1. Acknowledge you've read the plan and these rules.
2. Confirm your understanding of the phase order and the per-phase definition of done.
3. Begin **Phase 1 — Foundations & setup**. Initialize the repo, create the directory scaffold, set up the root `README.md` with a "Current status" table showing all 7 phases (Phase 1: in progress; rest: not started), then proceed with the Phase 1 work items in order.

When you finish Phase 1, stop and report. Wait for my approval before starting Phase 2.