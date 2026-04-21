# Phase 4 Spike Report — CUETools rip-engine contract

**Status:** Research only. No production code lands in this commit.
**Goal:** Lock the contract between MusicRipper and the CUETools rip
backend before `src/core/Invoke-Rip.ps1` is written.

The state file says: *"CLI ripper availability has already been confirmed
in Phase 2: `CUETools.Ripper.Console.exe` exists."* That is true — but
"exists" turned out to be very different from "does what the plan
assumed". This spike documents what it actually does, what it doesn't,
and the resulting go/no-go.

CUETools version probed: **2.2.6** (winget package `gchudov.CUETools`,
installed at `%LOCALAPPDATA%\Microsoft\WinGet\Packages\gchudov.CUETools_*\CUETools_2.2.6\`).

---

## 1. CLI surface of `CUETools.Ripper.Console.exe`

Verbatim `--help`:

```
CUERipper v2.2.6 Copyright (C) 2008-2024 Grigory Chudov
Usage    : CUERipper.exe <options>

-S, --secure             secure mode, read each block twice (default);
-B, --burst              burst (1 pass) mode;
-P, --paranoid           maximum level of error correction;
-D, --drive <letter>     use a specific CD drive, e.g. F: ;
-O, --offset <samples>   use specific drive read offset;
-C, --c2mode <int>       use specific C2ErrorMode, 0 (None), 1 (Mode294),
                         2 (Mode296), 3 (Auto);
-T, --test               detect read command;
--d8                     force D8h read command;
--be                     force BEh read command;
```

That is the **entire** flag set. Notably **absent**:

- No `--output` / output-directory flag.
- No `--codec` / `--format` flag — output codec is hard-coded.
- No `--profile` / settings-file flag — `user_profiles_enabled.txt`
  exists in the install dir as a 0-byte marker but the Console ripper
  ignores it.
- No CUE-sheet emission flag.
- No tag / metadata flag.
- No "embed cover art" flag.

`%APPDATA%\CUE Tools\` and `%APPDATA%\CUERipper\` are both **absent**
on this machine — i.e. the Console ripper does not read user settings
from a roaming profile dir either.

## 2. What the binary actually does (verified via reflection)

Loaded `CUETools.Ripper.Console.exe`'s `Main` method via `System.Reflection`
and enumerated every method-call/newobj/callvirt token. Key findings:

| Behaviour | Evidence |
|---|---|
| **Output codec is WAV, hard-coded.** No FLAC/ALAC/etc. | `CUETools.Codecs.WAV.AudioEncoder..ctor`, `CUETools.Codecs.WAV.EncoderSettings..ctor` |
| **Output is per-track, written to current working directory.** | `IAudioDest.Write` per track; `Path.GetInvalidFileNameChars`/`Replace` for filename sanitization; no path-construction with absolute roots |
| **Filenames are derived from CTDB metadata** (album/artist/year + per-track artist/name), not from CLI args | `CTDBResponseMeta.get_album/get_artist/get_year`, `CTDBResponseMetaTrack.get_artist/get_name` then `String.Replace` + invalid-char strip |
| **Always contacts AccurateRip + CTDB** during the rip | `AccurateRipVerify.ContactAccurateRip`, `CUEToolsDB.ContactDB`, `CUEToolsDB.Init`, `CUEToolsDB.get_Metadata` |
| **Writes a single rip log** alongside the WAVs | `AccurateRipVerify.GenerateFullLog` → `StringWriter` → `StreamWriter` |
| **Drive-tuning IS plumbed through** from the documented flags | `set_DriveOffset`, `set_DriveC2ErrorMode`, `set_ForceBE`, `set_ForceD8`, `set_CorrectionQuality` |
| **Gap detection runs**, but gap *handling* (append-to-previous vs prepend-to-next vs leave-out) is **not configurable** | `CDDriveReader.DetectGaps` is called once; no branch on a "mode" parameter |
| **No CUE sheet is emitted.** | No `CDImageLayout.Write*` / no CUE-writer types in the call graph |
| **Progress is delivered via a ReadProgress event** that the program prints with `\r` (overwriting line) | `add_ReadProgress`, `EventHandler<ReadProgressArgs>..ctor`, `Console.Write`, custom `ProgressMeter` class with one `ReadProgress` method |
| **Process exit code is always 0**, even on hard failures (e.g. drive open denied) | No `Environment.Exit` reference; observed `ExitCode=0` on `Open failed: Access is denied` (no admin) and on `--bogus` flag |

Reproducer (no CD required, no admin required):

```powershell
& "$ct\CUETools.Ripper.Console.exe"            # prints Open-failed error
echo $LASTEXITCODE                             # → 0
& "$ct\CUETools.Ripper.Console.exe" --bogus    # prints usage
echo $LASTEXITCODE                             # → 0
```

## 3. What the CUETools install gives us elsewhere

| Tool | Has CLI? | Useful? |
|---|---|---|
| `CUETools.Ripper.Console.exe` | yes (above) | Rip + AR/CTDB log — **but WAV-only, no CUE, no tags** |
| `CUETools.exe` | **GUI-only**, opens a window even on `--help` (verified — had to kill it) | No |
| `CUETools.Flake.exe` | yes — full WAV→FLAC encoder with `-0..-11`, `-T FIELD=VAL` tagging, `-V` verify, `-P` padding | **Yes** |
| `CUETools.Converter.exe` | yes — generic codec converter (`--encoder`, `-m`, `--lossless`) | Maybe (Flake is more direct for our case) |
| `CUERipper.exe` | WPF GUI, no headless mode | No |
| `CUETools.Codecs.Flake.dll`, `CUETools.Codecs.libFLAC.dll`, `CUETools.Codecs.FLACCL.dll` (in `plugins/`) | .NET DLLs callable directly from PowerShell, the same way `Get-DiscId.ps1` already calls `CUETools.Ripper.SCSI.dll` and `CUETools.AccurateRip.dll` (D-008 path) | **Yes** |

## 4. Mismatch with `config/cuetools.profile.txt`

The pinned profile we authored in Phase 1 lists:

| Setting we pinned | Console ripper supports it? |
|---|---|
| `codec = flac`, `flac_compression_level = 8` | **No** — WAV-only |
| `output_style = per_track` | Yes (only mode it supports) |
| `gap_handling = append_to_previous` | **No** — not configurable |
| `emit_cuesheet = true`, `cuesheet_style = eac` | **No** — never emitted |
| `verify_accuraterip = true`, `verify_ctdb = true`, `emit_log = true` | Yes (always on) |
| `embed_cover_art = true` | **No** — has to be a separate post-step (was already a Phase 5 problem per state file note re. metaflac) |

So the profile file is best read as a **MusicRipper-internal spec** that
*we* implement on top of whichever rip path we choose, not something we
hand to the ripper.

## 5. Options considered

### Option A — Console ripper + Flake post-encode

Pipeline:

1. Run `CUETools.Ripper.Console.exe -D <drive> --secure --offset <n>` from
   an empty per-disc temp folder. Capture stdout (parse for progress &
   `Error:` lines). Ignore exit code.
2. After it returns, glob `*.wav` and `*.log` in the temp folder. WAV
   filenames will be CTDB-derived ("01 - Artist - Track.wav" or
   similar — exact pattern needs an admin-mode confirmatory rip to
   pin down).
3. Sort WAVs by leading track number; pair with the **user-confirmed**
   metadata from Phase 3 (not the CTDB names CUETools picked).
4. For each WAV, encode WAV → FLAC L8 with
   `CUETools.Flake.exe -8 -V -T ARTIST=… -T TITLE=… -T ALBUM=… …`.
5. Generate the EAC-style CUE sheet ourselves from the disc TOC
   (we already have the layout in memory from `Get-DiscId`) +
   confirmed metadata.
6. Persist the AR/CTDB log next to the FLACs (it's the proof for
   `Test-RipQuality` in Phase 5).
7. Delete the temp WAVs.
8. (Phase 5) Embed cover art via metaflac/Flake `-T` is metadata only;
   picture embedding needs `metaflac --import-picture-from` or a
   custom `TagLibSharp` write — already an open Phase 5 question.

**Pros:** uses the well-tested rip path that hydrogenaud.io trusts. Less
.NET surface area to learn.
**Cons:** double-disk-writes (WAV then FLAC). Depends on CTDB-derived
filenames being predictable enough to glob+sort (risk: collisions on
"Various Artists" discs). The Console ripper picks a CTDB metadata
candidate of its own choosing — this can disagree with what the user
confirmed in Phase 3 (different release), which makes the rip log
header read "wrong album". Also: no exit-code → must rely entirely on
stdout regex for "did it succeed".

### Option B — Drive `CUERipper.exe` GUI headlessly

Reject: requires an interactive desktop session, fragile to UI changes,
and we'd still need to scrape its output folder + parse a log we don't
control. Strictly worse than A or C.

### Option C — Custom rip driver via the same .NET DLLs we already use

We already load `CUETools.Ripper.SCSI.dll` and friends from PowerShell
in `src/core/Get-DiscId.ps1` (per **D-008**). The same code path the
Console ripper takes is just `CDDriveReader` + `AccurateRipVerify` +
`CUEToolsDB` + an `IAudioDest` of our choice. Pipeline:

1. Open `CDDriveReader` against the configured drive (we already do
   this in Phase 2). Set `DriveOffset`, `DriveC2ErrorMode`,
   `CorrectionQuality` from `cuetools.profile.txt`.
2. Construct a `CUETools.Codecs.Flake.AudioEncoder` per output track,
   using the user-confirmed track titles for filenames. FLAC L8 in
   one pass — no WAV intermediate.
3. Subscribe to `CDDriveReader.ReadProgress` → marshal to the
   non-modal `Show-RipProgress.ps1` window (Phase 4) on the UI thread.
4. Drive `AccurateRipVerify.Write` per buffer; emit
   `AccurateRipVerify.GenerateFullLog` at the end. Emit `CTDB`
   verification the same way.
5. Emit the EAC-style CUE sheet from `CDImageLayout` (we already have
   the layout from `Get-DiscId`).
6. Apply gap-handling (`append_to_previous`) by adjusting per-track
   start/end sample boundaries before encoding — `CDImageLayout`
   exposes pregap as `CDTrack.Pregap`, and we can include it in the
   previous track's encoded output.
7. Tags written via Flake encoder's tag dictionary. Cover art embed
   still defers to Phase 5 (metaflac-or-equivalent question stands).

**Pros:** single FLAC write (no WAV→FLAC re-encode). Filenames + tags
match exactly what the user confirmed. Real success/failure signal
(exceptions, not stdout-regex). Full control over gap handling.
Architecturally consistent with **D-008**.
**Cons:** more PowerShell ↔ .NET integration code to write and
maintain. Subject to the same "method calls leak return values into
pipeline" gotcha already documented (must `| Out-Null` every void
method on the reader).

## 6. Decision: **Go with Option C.**

Rationale:

- The Console ripper's hard-coded WAV-only output and CTDB-driven
  filenames force us to write **most of Option C's code anyway** —
  glob, sort, rename, re-encode, CUE-emit, tag. The "use the well-
  tested binary" advantage erodes once you account for the post-
  processing that's required either way.
- We have already accepted the .NET-DLL approach (D-008) and proven
  it works in Phase 2 for disc-id. Phase 4 is the natural extension
  of that path.
- The user already saw the ergonomics of Option C's predecessor: the
  Phase 3 dialog works because it has access to the *user's* edited
  metadata. Option A would silently use CTDB's metadata for filenames
  and the AR log header — a UX regression.
- Exit-code-always-zero from the Console ripper alone is a
  show-stopper for our error handling: we'd need stdout regex as the
  single source of truth for "did it succeed". Option C uses .NET
  exceptions, which we already trust.

## 7. Locked contract for Phase 4 implementation

`src/core/Invoke-Rip.ps1` — public surface:

```powershell
Invoke-RipperRip
  -DiscIdInfo  <obj from Get-RipperDiscId>
  -Metadata    <confirmed metadata from Show-RipperMetadataDialog>
  -OutputRoot  <abs path; per-disc folder will be created under it>
  -Settings    <obj parsed from config/cuetools.profile.txt>
  -OnProgress  <scriptblock {param($pct,$track,$totalTracks,$arConfidence)}>
  -OnLog       <scriptblock {param($level,$line)}>
```

Returns:

```powershell
[pscustomobject]@{
    Status         = 'Verified' | 'ProbablyGood' | 'Suspect' | 'Failed'
    OutputDir      = '...'
    FlacFiles      = @('01 - …flac', …)
    CueFile        = 'album.cue'
    LogFile        = 'album.log'
    AccurateRip    = @{ MatchedTracks = N; TotalTracks = M; Confidence = K }
    CtdbVerify     = @{ Status = 'verified' | 'differ' | 'notpresent'; Confidence = K }
    Errors         = @()  # any non-fatal warnings
}
```

(`Test-RipQuality.ps1` in Phase 5 will *re-derive* `Status` from the log
file — `Invoke-RipperRip` only emits a best-effort summary for the UI.)

`src/ui/Show-RipProgress.ps1` — non-modal WPF window driven by
`OnProgress`. Shows: current track / total, % of current track,
overall %, current AR confidence, and a "Cancel rip" button (which
calls `CDDriveReader.Close()` to abort). Same WPF + inline-XAML
pattern as `Show-MetadataDialog.ps1`. Same gotcha applies: bind helper
functions as scriptblock locals before the click handler (gotcha #6).

`Start-Ripper.ps1` — replace the `Action='Rip'` stub with: open a
`Show-RipProgress` window, call `Invoke-RipperRip` with the user's
confirmed metadata, then on completion eject the drive and surface
a final "Verified / Probably Good / Suspect" summary.

Pure-logic helpers that get **Pester tests** under `tests/`:

- CUE-sheet generator: input `(CDImageLayout, ConfirmedMetadata)`,
  output an EAC-style CUE string. Test against fixtures.
- Filename sanitizer: input `(track number, artist, title)`,
  output `"01 - Artist - Title.flac"` with NTFS-safe chars,
  collision-free across the album.
- Log-summary parser (small): pull AR/CTDB confidence out of the
  log text emitted by `AccurateRipVerify.GenerateFullLog`. Phase 5
  will need this anyway; building it in Phase 4 lets us populate
  the `Invoke-RipperRip` return value cleanly.

Disc-touching code (`CDDriveReader` lifecycle, encoder pipeline,
WPF window) is **not** unit-tested — covered by the manual
verification list at the end of Phase 4.

## 8. Risks & open questions

- **Admin requirement.** `CDDriveReader.Open` requires Administrator
  (gotcha #3). The Desktop shortcut already runs elevated; `Invoke-Rip`
  will inherit that. Anyone running it from a non-elevated terminal
  will get the same `E_ACCESSDENIED` already documented.
- **`Cancel rip` semantics.** Calling `Close()` on the reader mid-rip
  needs to be tested — partial-FLAC files must be deleted on cancel.
  Will sort out during impl.
- **Cover art embedding** is still a Phase 5 problem. `Invoke-RipperRip`
  writes a `cover.jpg` to the output folder if `Metadata.CoverArtBytes`
  is present, and Phase 5's `Write-Tags.ps1` embeds it as APIC. This
  matches the existing plan note about metaflac not being shipped.
- **Pregap-as-track-1.** Some discs have an audio pregap before track 1
  (the "hidden track" pattern). `gap_handling = append_to_previous`
  has no "previous" for track 1's pregap — convention is to discard
  it or write it as `00 - HTOA.flac`. Punt on this until we hit it
  in the manual verification.
- **Drive-offset config flow.** `cuetools.profile.txt` doesn't carry
  the drive offset (it's per-drive, not per-rip). Read from
  `data/driveoffsets.cached.json` (already populated by
  `setup/Register-Drive.ps1` in Phase 1) keyed by drive vendor/model.

## 9. Manual verification (end of Phase 4)

To be re-stated in the Phase 4 final report. At minimum:

- Rip 3 known-good discs end-to-end (a CD-DA, an enhanced CD with a
  data track, and a multi-disc set's disc 2 → tests CTDB pick
  disagreement risk).
- Per-track FLAC checksums (`flac --decode` then SHA-256 of WAV)
  must match a reference rip taken from CUERipper GUI with
  identical settings — bit-identical proof.
- The AR/CTDB log must report ≥1 confidence on at least one mainstream
  disc (sanity check that the verification path is wired).
- Cancel-mid-rip must leave no orphan FLAC files.

---

**This spike is throwaway research.** The contract above (§7) is what
gets built next. Any deviation during impl that touches the public
surface or the rip-pipeline shape requires a follow-up note here
before code lands.
