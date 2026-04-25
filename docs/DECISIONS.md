# Decisions

Running log of architectural decisions, with the reasoning so future-you
doesn't re-litigate them. Append-only; if a decision is reversed,
*amend in place* with a "Superseded YYYY-MM-DD" note rather than
deleting.

---

## D-001 — Ripper engine: CUETools / CUERipper *(Phase 1)*

**Choice:** Use CUETools (CLI if available; otherwise drive `CUERipper.exe`
in auto-mode). Phase 4 begins with a spike to confirm CLI availability.

**Alternatives considered:**

- **Exact Audio Copy (EAC):** Mature, gold-standard for accurate ripping,
  but Windows-GUI-only with no scripting story. Hard to drive
  unattended for parents.
- **dBpoweramp CD Ripper:** Excellent UX and AccurateRip support, but
  paid + closed source. Project rule: no paid services.
- **abcde / cdparanoia (WSL):** Strong Linux pedigree but adds a WSL
  dependency, and AccurateRip integration is weaker than CUETools'.

**Why CUETools wins:** Best-in-class AccurateRip + CTDB verification,
free, ships with `metaflac.exe` we need anyway, has at least a
GUI-watchable output folder if no CLI, and is the de-facto standard
on hydrogenaud.io for archival ripping.

---

## D-002 — Output format: per-track FLAC L8 + CUE + log, gap-append-to-previous *(Phase 1)*

**Choice:** Per-track FLAC level 8, plus an EAC-style CUE sheet
referencing those FLACs, plus the rip log. Gap audio (index 00) is
appended to the **end of the previous track** (the EAC "noncompliant"
mode).

**Alternatives considered:**

- **Single-file FLAC image + CUE:** Simpler reconstruction story, but
  Plex / Navidrome / Jellyfin all expect per-track files and silently
  fail on single-file images.
- **Gap mode "prepend to next" or "discard":** Prepend leaks audio onto
  the wrong track for skip/shuffle; discard loses ~1s of music per gap
  on some discs.

**Why this combination:** Per-track FLAC = playable everywhere. The
CUE + log + gap-append-to-previous = the rip is **bit-exactly
reconstructable** to the original disc image for re-burning, which is
the whole point of an archival rip.

---

## D-003 — Runtime: PowerShell 7 + WPF only *(Phase 1)*

**Choice:** PS7 for all logic, WPF (XAML inline) for any UI. No external
runtimes, no Python, no Node, no C# project.

**Why:** Single ask of the user (`winget install Microsoft.PowerShell`).
WPF ships with .NET on Windows, so confirm/progress dialogs add zero
install footprint. Anything more would make `Install-Dependencies.ps1`
heavier than the rip engine itself.

---

## D-004 — Config + secrets: `%LOCALAPPDATA%\MusicRipper\` + DPAPI *(Phase 1)*

**Choice:** Per-machine `config.json` under `%LOCALAPPDATA%`. Secrets
(currently just the Synology share PSCredential) persisted via
`Export-Clixml`, which wraps SecureStrings with the current Windows
user's DPAPI key.

**Alternatives considered:**

- **Windows Credential Manager:** Better UX (visible in Credential
  Manager UI), but the PowerShell wrapper modules add a dependency.
- **Plaintext JSON:** Disqualified by the "no plaintext secrets" rule.
- **Env vars / .env files:** Not durable across reboots without extra
  glue, and Mom won't edit `setx`.

**Why DPAPI:** Zero dependencies, file is unreadable by other users on
the machine, unportable to other machines (which is exactly what we
want for a family laptop). Documented at
<https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-clixml>.

---

## D-005 — Metadata source: MusicBrainz + Cover Art Archive *(Phase 1)*

**Choice:** MusicBrainz Web Service v2 for tags, Cover Art Archive for
front cover art. Anonymous (1 req/sec throttle) with a polite UA
identifying MusicRipper + a contact email.

**Alternatives considered:**

- **freedb / GnuDB:** Effectively dead.
- **Discogs:** Excellent for vinyl/CD metadata, but rate limits and
  auth requirements are heavier than MB; cover quality is inconsistent.
- **Apple Music / Spotify APIs:** Paid auth + ToS forbid this use case.

**Why MB+CAA:** Free, comprehensive, machine-readable, and the same
source MusicBrainz Picard uses — so the Phase-7 review-queue workflow
("drag folder into Picard") is consistent with what we shipped.

---

## D-006 — Bad rips & unknown discs route to `_ReviewQueue/`, not the main library *(Phase 1)*

**Choice:** Anything that isn't a clean AccurateRip-verified rip with a
high-confidence MusicBrainz match goes to `<LibraryRoot>/_ReviewQueue/`
with a `REVIEW.txt` explaining why. The main library only ever
contains "good" rips.

**Why:** Parents rip a stack and walk away. We never want a sketchy
rip to silently land in the family library and become the canonical
copy. The review queue keeps the library trustworthy and gives you a
clear backlog to clear.

---

## D-007 — Remote NAS access via self-hosted WireGuard, not third-party relay *(deferred to Phase 6)*

**Choice:** When the rip machine is off the home LAN, reach the
Synology share over the user's existing **router-hosted WireGuard
VPN**. MusicRipper itself will manage the tunnel: bring it up before
`Sync-ToSynologyNAS.ps1` runs, leave it up for an idle-timeout window
(default 10 min) to coalesce a batch of rips, then tear it down.

**Alternatives considered:**

- **Tailscale on the NAS + clients.** Easiest UX, no router config,
  free for personal use. Rejected because traffic is brokered
  through Tailscale's coordination + DERP relays; the user
  explicitly does not want their data path to involve any third
  party.
- **Synology QuickConnect + WebDAV.** Same third-party-relay
  objection, plus WebDAV-on-Windows is flaky for big file batches.
- **SMB exposed to the internet.** Security non-starter (port 445
  is a ransomware magnet).
- **VPN always-on.** Rejected because the rip machine may be a
  family laptop where forcing all traffic through the home router
  would tank web browsing.

**Implementation sketch (deferred to Phase 6, captured in
[SYNOLOGY-SHARE-SETUP.md](SYNOLOGY-SHARE-SETUP.md)):**

- Add `WireGuard.WireGuard` to `setup/Install-Dependencies.ps1`.
- New `src/lib/Wireguard.psm1` with idempotent
  `Start-/Stop-/Test-RipperVpnTunnel` wrapping `wireguard.exe
  /installtunnelservice` and `/uninstalltunnelservice`.
- New config keys: `WireGuardTunnelName`,
  `WireGuardAutoToggle`, `WireGuardIdleTimeoutMinutes`.
- `Sync-ToSynologyNAS.ps1` brings the tunnel up if not already up,
  syncs, registers a teardown hook in `Start-Ripper.ps1` that fires
  on exit or after the idle timeout. Repeated rips inside the
  window reuse the existing tunnel (no thrash).
- **Split-tunnel scope:** the user authors the `.conf` with
  `AllowedIPs = <nas-subnet>/24` so only NAS traffic is routed
  through the VPN. MusicRipper does NOT modify the user's
  `.conf` — split-tunnel is a documentation concern, not a code
  concern.

---

## D-008 — Disc-id reading via CUETools .NET assemblies, not a CLI tool *(Phase 2)*

**Choice:** `src/core/Get-DiscId.ps1` loads CUETools' .NET DLLs
(`CUETools.CDImage.dll`, `CUETools.Ripper.dll`,
`plugins/CUETools.Ripper.SCSI.dll`) via `Add-Type` and uses
`CUETools.Ripper.SCSI.CDDriveReader` directly. Reads the TOC,
pulls `MusicBrainzId` / `MusicBrainzTOC` / `TOCID` (CTDB) off the
resulting `CDImageLayout`, then closes the drive.

**Alternatives considered:**

- **CUETools CLI to print a disc ID.** The plan's first choice. In
  CUETools 2.2.6 the only CLI tool is
  `CUETools.Ripper.Console.exe`, and it has no "print disc id"
  mode \u2014 its only operating mode is to actually rip. There is
  no `CUETools.eac.exe` in this build. Rejected because we'd have
  to start a rip just to learn the disc id.
- **Bundled libdiscid + P/Invoke.** The plan's stated fallback.
  Means vendoring x64 + x86 native DLLs, writing a P/Invoke
  signature, and managing native lifetimes. More moving parts
  than option chosen, with no upside since CUETools is already
  installed.
- **Win32 IOCTL_CDROM_READ_TOC ourselves.** Reinventing a
  well-known wheel; ugly P/Invoke surface; we'd then still need
  to compute the MB disc id ourselves (Base64 of a SHA-1 over a
  specific TOC layout).

**Why the CUETools DLLs win:**

- Zero new dependency \u2014 CUETools is already in
  `Install-Dependencies.ps1`.
- The exact same code path the CUETools GUI uses, so disc IDs
  match what CUERipper would emit \u2014 useful when comparing
  rips later.
- Comes with the AccurateRip and CTDB IDs as side-effects, both
  needed in Phases 4-5.
- Trivial PowerShell wrapper (\~100 lines incl. comment-based help).

**Risk:** if a future CUETools version reshuffles its API, we adapt.
The relevant types have been stable for years; risk is low.

---

## D-009 — Tag-write engine: Xiph `metaflac.exe`, not CUETools .NET *(Phase 5)*

**Choice:** Add `Xiph.FLAC` (winget id `Xiph.FLAC`, currently v1.5.0) to
`setup/Install-Dependencies.ps1`. `src/core/Write-Tags.ps1` shells out to
`metaflac.exe` for the full Vorbis tag set, embedded cover art, and
ReplayGain (`--add-replay-gain` over the album).

**Alternatives considered:**

- **CUETools .NET assemblies.** CUETools is already installed (D-008), but
  it does **not** expose a public, stable metadata-write API. The Vorbis
  comment surface lives inside `CUETools.Codecs.FLAKE` internals that
  are not part of the documented assembly contract.
- **TagLib# / atldotnet.** Mature .NET tag libraries, but vendoring a
  managed DLL into a PowerShell repo adds a load-order ceremony and a
  third-party update path. ReplayGain still needs an audio-analysis
  pass that neither library ships.
- **Hand-write the FLAC metadata blocks.** Possible (the spec is small),
  but reinventing a wheel where Xiph ships the canonical reference tool.

**Why metaflac wins:**

- Canonical Xiph tool; whatever it writes is by definition
  spec-compliant.
- ReplayGain analysis is a single `--add-replay-gain` invocation across
  the album set — no separate analyzer dependency.
- Phase 4's `Invoke-Rip` already reserves 8192 bytes of
  `EncoderSettings.Padding` per file specifically so metaflac can write
  tags + 8 KB cover art **in place** with zero audio rewrite. Don't
  break this in any future Invoke-Rip change.
- One winget line in setup; no managed-DLL load-order surprises.

---

## D-010 — `_ReviewQueue/_image/` single-file image via `flac.exe` cmd-shell pipe *(Phase 5)*

**Choice:** When a rip routes to `_ReviewQueue/`, generate the inspection
image `_image/<Album>.flac` + `.cue` by decoding each per-track FLAC to
raw PCM, concatenating to one temp `.raw`, then re-encoding with
`flac.exe` invoked through `cmd.exe /c` with explicit quoting. The
encoder reads the raw stdin / `-o` writes the output — no PowerShell
binary pipe sits between two native processes.

**Alternatives considered:**

- **CUETools .NET decoder + Flake re-encoder.** Same dep we already use
  for ripping, no new winget line. Works in isolation, but the
  per-track decode loop is significantly more code than `flac.exe -d`,
  and a bug in stream-frame alignment surfaces as a corrupt image
  rather than a clean error.
- **`& $FlacPath` (PowerShell native call).** First implementation.
  Intermittently corrupted the encoded output (~1-in-10 runs) on the
  test fixture path, with no PowerShell-level error. Root cause was
  never fully isolated; symptom was a non-FLAC file with PowerShell
  banner bytes inserted near the start.
- **`Start-Process -FilePath flac.exe -ArgumentList ...`** Same
  intermittent corruption.
- **`sox`, `ffmpeg`, etc.** New dependency for one feature.

**Why `cmd.exe /c "flac.exe ... -o out.flac in.raw"` wins:**

- We already ship `flac.exe` for D-009 (metaflac and flac come from
  the same Xiph.FLAC winget package).
- Quoting and arg parsing happen entirely inside cmd.exe; PowerShell
  doesn't touch the native arg vector. The intermittent corruption
  disappeared after switching to this form.
- Skip-when-missing: if `flac.exe` isn't on PATH or in standard
  install dirs, `New-RipperReviewImage` logs a warning and returns
  `$null`. The per-track FLACs at the album root are still usable in
  foobar2000, so the review queue degrades gracefully.

**Test strategy:** Earlier commits used a hand-rolled `flac.cmd` stub to
fake the encoder. Tests went 159/1/1 to 160/0/1 randomly. Three
different stub-side fixes (`& exe`, `Start-Process exe`,
`Start-Process cmd /c`) all left occasional 1-in-5 failures. The fix
that stuck: use the **real** `flac.exe` plus a **real** `.flac`
fixture under `tests/fixtures/` (gitignored via `*.flac` so developers
drop one in manually; CI / fresh clones skip the integration tests
cleanly). Five consecutive clean suite runs confirmed stability.

---

---

## D-011 — Metadata + cover-art are pluggable provider chains *(Phase 5.2)*

**Choice:** Both metadata lookup and cover-art lookup go through ordered
provider chains, not a single hard-coded source. Default chains:
- `MetadataProviders`: `["MusicBrainz", "CuetoolsDb"]` — when both
  return matches, the orchestrator synthesizes a "Merged (MB + CTDB)"
  candidate (MB wins on conflict, CTDB fills nulls including missing
  track titles) and prepends it to the dropdown.
- `CoverArtProviders`: `["CoverArtArchive", "iTunesSearch", "Deezer"]`
  — first non-empty bytes win; chain stops on first hit, so common
  cases never touch iTunes/Deezer.

**Why now:** A real Various-Artists compilation we own lives in CTDB but
not MusicBrainz, so a single-source design fails it entirely. Even
when MB has a release, CTDB sometimes carries fields MB lacks
(local-language titles, regional release dates).

**Alternatives considered:**

- **Primary + single fallback:** Simpler but inflexible — adding a
  third source means another code change. The chain pattern lets a
  user reorder providers in `config.json` without touching code.
- **Parallel queries with quorum scoring:** Would let us auto-pick
  the most-agreed-upon answer, but it overweights popular discs and
  is a significant complication. Defer until we hit a case where the
  current "MB wins, others fill" rule is wrong.

**Provider contract:** Every metadata provider returns
`@{ Source; Status; BestMatch; Candidates; Diagnostic }`. Every
cover-art provider returns `@{ Source; Bytes; Url; Diagnostic }`.
Provider files live at `src/core/metadata/Get-MetadataFromXxx.ps1`
and `src/core/coverart/Get-CoverArtFromXxx.ps1`.

**Deferred to a later round (intentionally NOT v1):**

- **Discogs** — needs a personal access token; great for vinyl but
  outside the "no manual setup" UX goal for parents.
- **fanart.tv** — needs a project key, and its sweet spot is artist
  backgrounds, not per-album covers.
- **Apple Music / Last.fm / Spotify / Amazon** — require API keys or
  paid tiers; iTunes Search already covers Apple's catalog without
  auth for our purposes.

Revisit after Phase 6 if rip-failure-by-no-metadata becomes a real
pattern in the field.

---

## D-012 — Adopt GnuDB as a third metadata provider *(Phase 5.2 follow-on)*

**Reversal of one "deferred" item in D-011.** A live test of an EFY
2006 VA Christmas compilation hit a gap both MB and CTDB missed:
MusicBrainz had the release but no disc-id attached (so the
`/discid/` lookup 404'd), and CTDB had a verification-only row with
empty album/artist/tracks. The motivation for skipping GnuDB in
D-011 ("protocol abandoned, database stale") turned out to be
half-wrong: GnuDB is quiet but still active, owns the freedb catalog
since Magix retired freedb in 2020, and holds >10M CD entries
including the long tail of community-submitted / regional discs that
MB's curation bar keeps out.

**Provider:** `src/core/metadata/Get-MetadataFromGnuDb.ps1`. Uses
the CDDB HTTP protocol (proto=6, UTF-8) against
`https://gnudb.gnudb.org/~cddb/cddb.cgi`. Two-step flow:

1. `cddb query <disc-id> <ntrks> <offsets...> <nsecs>` — returns
   200 (single exact), 210 (exact list), 211 (inexact list), 202
   (no match).
2. `cddb read <category> <disc-id>` for the top N matches (default
   3) — returns xmcd text we parse for DTITLE / DYEAR / DGENRE /
   TTITLE*n*.

The CDDB1 disc-id is computed locally from `DiscIdInfo.Tracks[]`
(sum-of-digit checksum of track start seconds, total nsecs,
track count) so we don't need another CUETools helper.

**Why it slots after CTDB, not before:** CTDB is more likely to have
accurate per-track timings (it's auto-submitted alongside successful
rips) and GnuDB's legacy catalog has the most format variation /
partial entries. Ordering MB → CTDB → GnuDB keeps curated data
winning conflicts while GnuDB fills the tail.

**Rate-limit discipline:** GnuDB requires a distinct
`hello=email+host+app+version` on every request or they collapse
generic clients into one shared quota. We reuse
`cfg.MusicBrainzUserAgent` (which already has the user's email in
`( ... )`) and identify as `musicripper/0.1`. One query + up to 3
reads per disc is well under the per-user quota.

**Client-side filter:** `ConvertFrom-XmcdEntry` returns `$null` for
entries with blank DTITLE, blank DYEAR, and no TTITLE*n* values — the
same "verification-only row" pattern that bit us on CTDB (see the
fix described inline in `Get-MetadataFromCuetoolsDb.ps1`).

**Still deferred:** Discogs, fanart.tv, Apple Music, Last.fm,
Spotify, Amazon (unchanged from D-011).



---

## D-013 — Eject-after-rip is a per-rip user choice, defaulted from config *(Phase 5.4)*

**Choice:** A new `EjectAfterRip` boolean (default `true`) lives on
the config object. The confirm dialog renders an "Eject disc when
done" checkbox in the action-button row, IsChecked seeded from
`cfg.EjectAfterRip`. The user's per-rip choice rides on the dialog
result object as `.EjectAfterRip` and is honoured uniformly at every
eject site in `Start-Ripper.ps1` (Rip-success, post-process-fail,
rip-throw, rip-returned-null, Review, Cancel) via a single
`Invoke-RipperMaybeEject` wrapper.

**Why both layers:** The config default keeps the parent-friendly
batch flow (insert disc → wait for green check → eject → repeat).
The dialog checkbox lets a power user iterating on metadata flip it
per-disc without editing JSON. We did NOT want a config-only toggle
because the common power-user case ("I'm trying three different
metadata sources for the same disc") changes the answer per-rip.
We did NOT want a dialog-only toggle because the parents never
touch the dialog any differently than today.

**Rejected:** A second confirm dialog ("Eject? Y/N") after the rip
finishes — adds a click in the common case, doesn't help the
no-eject case, and creates a place where the script can hang
waiting for a click that never comes if the parent walked away.

**Wire:** `setup/New-RipperConfig.ps1` interactive Y/N prompt + top-up
detection (so an existing pre-5.4 config picks up the new key on
`-TopUp` or interactive `'u'`). `src/lib/Config.psm1` adds the field
to `New-RipperConfigObject` so a fresh config gets it. The dialog
wrapper accepts `-EjectAfterRip [bool]` and falls back to `$true`
for pre-5.4 configs in `Start-Ripper.ps1` via
`if ($cfg.PSObject.Properties['EjectAfterRip']) { ... } else { $true }`.


---

## D-014 — Cover-art picker is on-demand, not modal-by-default *(Phase 5.3)*

**Choice:** The confirm dialog keeps auto-picking the first cover-art
provider that returns bytes (`Get-RipperCoverArtChain`, unchanged).
A "Change cover…" button under the cover preview opens a sub-modal
(`Show-RipperCoverArtPicker`) that runs *every* configured provider
in chain order (`Get-RipperCoverArtCandidates`) and shows each
non-empty result as a thumbnail the user can pick. Picking one
swaps the in-memory `CoverArtBytes` on the current candidate so the
subsequent rip embeds the chosen image. Cancelling the picker is a
no-op; the auto-picked cover stays.

**Why on-demand:** The common case ("MusicBrainz/CAA returned a
perfectly fine cover") shouldn't cost the parent an extra click or
extra network calls. The power-user case ("this CAA cover is the
wrong edition / low-res / the user hates the Deezer one that won
the chain") is one click away, no config flag required.

**Rejected:**

- **Always show the picker up-front:** Extra click and latency for
  the 95% case where the auto-pick is fine.
- **Config flag `AlwaysShowCoverArtPicker`:** Yet another knob in
  `config.json` to explain. If a user wants to always pick, they
  can just click "Change cover…" every time.
- **Fetch all providers eagerly and only render the picker on
  demand:** Wastes bandwidth on every rip. The user opens the
  picker in a tiny fraction of rips.

**Provider contract:** Same shape as D-011
(`@{Source; Bytes; Url; Diagnostic}`). `Get-RipperCoverArtCandidates`
returns one entry per provider in chain order, preserving errors on
the `Diagnostic` field so we could surface them in the UI later.

**Still deferred (recorded here for the next cover-art iteration):**

- **Local file picker** — "Browse…" button in the picker modal that
  opens `Microsoft.Win32.OpenFileDialog` filtered to jpg/png/webp,
  reads the bytes, and adds a `(local)` thumbnail. Useful when the
  user has a scan of the booklet cover that beats every online
  source. Needs a size/MIME sanity check (reject >5 MB, reject
  non-image bytes) before we let it ride on the FLAC.
- **Paste from clipboard** — `[System.Windows.Clipboard]::GetImage()`
  (or `GetFileDropList` if the user copied a file) wired to a
  "Paste" button in the picker modal. Adds a `(clipboard)`
  thumbnail. Parallels the local-file picker but saves the
  save-and-browse step for users who grabbed an image from a
  browser.
- **Drag-and-drop onto the picker modal** — `AllowDrop="True"` on
  the picker window plus a `PreviewDragOver` / `Drop` handler that
  accepts a single file (or image data) and adds a `(dropped)`
  thumbnail. Same validation as local-file.

The three deferred sources would share one code path — a
`Register-RipperCoverArtPickerUserSource` helper that takes bytes +
a source label and appends a row to the picker's ItemsSource —
because they all produce the same `{Source; Bytes; Url=$null;
Diagnostic=$null}` shape as the network providers. When the time
comes: add the helper, wire three UI entry points (Button, Button,
DragDrop) to it, enforce the size/MIME gate in the helper not the
callers.

---

## D-015 — Phase-5 future-feature backlog *(documented Phase 5.3, deferred)*

These three ideas were scoped during the Phase 5.3 review but parked
for a later round so the user can pick them up against a stable
phase-5-library base. Each entry has enough detail that a future
session can resume implementation without re-deriving the design.

### F-1 — Submit disc-id back to providers when no match found

**Problem:** When all providers (MB, GnuDB, CTDB) come up empty for
a disc, the user types metadata in the text-search modal or just
sends to ReviewQueue. That correction never flows back upstream, so
the next person to insert the same disc gets the same NoMatch.

**Approach (sketch):**
- All three providers accept anonymous submissions:
  - **MusicBrainz**: open
    `https://musicbrainz.org/cdtoc/attach?toc=<toc>` in the user's
    default browser. They attach to an existing release or create
    one. No API key, no auth.
  - **GnuDB / freedb**: HTTP `cddb submit` with the xmcd payload.
    Fully anonymous.
  - **CoverArtArchive**: piggybacks on the MB submission — no
    separate path needed.
  - **CTDB**: `[CUETools.CTDB.CUEToolsDB]::Submit()` via the same
    .NET API we already use for queries.
- Where to surface it:
  - "Submit this disc to MusicBrainz" link in `REVIEW.txt` for
    UNKNOWN review-queue entries.
  - "Help others find this disc" button in the text-search modal
    once the user has picked a candidate they typed in themselves.
- New file: `src/core/metadata/Submit-DiscId.ps1` with one function
  per provider. Mirror the provider-chain pattern from D-011.
- Tests: pure URL/payload construction (don't actually submit in
  CI). Manual verify with a single throwaway test disc.

**Risk:** GnuDB is on a slow decline (per D-012) so the submit
endpoint may go away. MB is the safe long-term target; treat the
others as bonus.

**Estimate:** Small. Maybe a half-day plus manual verification on
one real submission.

---

### F-2 — Rip-speed mode (Secure / Balanced / Fast)

**Problem:** User reports ~4× average read speed on a drive
labelled much higher. Current Invoke-Rip.ps1 runs CUETools'
default Secure profile, which dual-reads every sector and re-reads
on disagreement. Most modern drives + most modern pressings can go
faster without sacrificing the "Verified" outcome because
AccurateRip + CTDB verification is the ground-truth check at the
end of the rip.

**The relevant CUETools knobs:**
- `CDDriveReader.CorrectionQuality` — 0=fast/single-read,
  1=normal, 2=paranoid. Set after `Open()` (Phase 4 lesson).
- `CDDriveReader.DriveC2ErrorMode` — controls whether the drive's
  C2 error pointers are used to skip re-reads on clean sectors.
  Most drives support C2.
- Cache-flush behaviour — Secure mode flushes between reads to
  defeat false confirmations from cache. Disabling helps speed
  but is only safe if the drive is on AccurateRip's
  "doesn't-lie-about-cache" list.
- Audio drives often top out at 24-40x even on a 48x-data label
  because they switch to CAV/CLV for audio.

**Proposed scope (`phase-5.5-rip-speed`):**
1. **Audit step**: log what `CorrectionQuality`,
   `DriveC2ErrorMode`, cache-flush settings Invoke-Rip currently
   passes. (Probably 1 / on / on. Verify.)
2. **New config field**: `RipSpeed = 'Secure' | 'Balanced' | 'Fast'`,
   default `'Balanced'`.
   - **Secure**: today's behaviour exactly. CorrectionQuality=2,
     no C2 trust, cache flushed.
   - **Balanced**: CorrectionQuality=1, trust C2 on clean sectors,
     re-read flagged sectors, cache flushed.
   - **Fast**: CorrectionQuality=0, single-read everywhere, trust
     C2 fully, no cache flush. (Optional — Balanced may be enough.)
3. New-RipperConfig.ps1: top-up + interactive
   "Secure / Balanced / Fast?" prompt.
4. Pass-through plumbing in Invoke-Rip.ps1.
5. Tests: pure config plumbing.
6. Manual verify: rip the same disc once per setting, compare
   wall-clock + final Status. Expect Verified across the board on
   a clean disc.

**Critical guardrail:** AR+CTDB verification stays on at every
speed setting. A wrong sector shows up as Suspect → ReviewQueue,
never as silently-bad Verified output. So the user can't lose
data by picking Fast.

**Estimate:** Medium. The config plumbing is small but you want
real measurements on multiple discs (clean / scratched / CD-R /
hybrid SACD) to publish defensible numbers in the docs.

---

### F-3 — On-disc metadata (CD-Text + ISRC) as a metadata source

**Problem:** When the disc-id chain comes up empty, we go straight
to "type the artist + album in the text-search box". But many
discs carry on-disc metadata that we never read. CD-Text is on
roughly 10-30% of commercial CDs (more common in the 2000s, on
Sony/BMG releases, on jazz/classical, on UK and Japan pressings).
ISRCs are on 40-60% of commercial CDs and uniquely identify a
recording — MusicBrainz indexes them.

**On-disc data sources:**
- **CD-Text** — burned in lead-in subchannel. Carries Album /
  AlbumPerformer plus per-track Title / Performer. Not on CD-Rs,
  not on most indie pressings.
  - Codepage caveat: ASCII or MS-JIS only. Latin-1 / Cyrillic /
    Greek titles come through as mojibake. Need a charset-detect
    or "looks wrong, ignore" heuristic.
- **ISRC** — 12-char per-track recording ID
  (`CC-XXX-YY-NNNNN`, e.g. `USX9P2512345`). Subchannel-encoded.
  MB has an ISRC->recording lookup endpoint
  (`/ws/2/isrc/<isrc>`).

**CUETools surface:**
`CDDriveReader.TOC` (after `Open()`) exposes `CDTextLength` and
the per-track `ISRC` field. We already make this Open call in
`src/core/Get-DiscId.ps1`, so the data is one line of code away.

**Proposed scope (`phase-5.6-on-disc-metadata`):**
1. Extend `Get-DiscId.ps1` to capture `Toc.CDTextLength > 0` and
   parse the lead-in CDText payload; capture per-track ISRCs into
   the disc-info shape returned by `Get-RipperDiscId`.
2. New file `src/core/metadata/Get-MetadataFromOnDisc.ps1`:
   a synthetic provider that produces a candidate from CD-Text
   when present (with `Source='OnDisc'`), and an ISRC-enriched
   candidate when MB returns a recording for any track's ISRC.
3. Insert into `MetadataProviders` chain at lowest priority by
   default — actual disc-id matches always win the ranking.
4. **NoMatch fallback wiring** in `Start-Ripper.ps1`: when the
   chain returns Status=NoMatch but on-disc metadata exists,
   open the text-search modal pre-populated with Artist+Album
   from CD-Text. User just hits Enter.
5. Cross-validate: when MB and CD-Text disagree (different album
   title, different track count), flag the discrepancy in
   `REVIEW.txt` for the queue case.
6. Tests: `ConvertFrom-CDText` handles empty / partial /
   codepage-bad inputs; ISRC parsing rejects malformed strings;
   fixture-based.
7. Manual verify: one CD-Text-bearing disc (Sony/BMG 2000s pop
   is a safe bet) + one without.

**Order suggestion if both 5.5 and 5.6 get scheduled:** do 5.6
first. On-disc metadata work happens at disc-id read time and
has zero risk to rip output, while rip-speed touches the actual
ripper engine and benefits from being on a stable base.

**Estimate:** Medium-large. The CDText codepage handling is the
fiddly bit. Plan for two fixture-disc reads (with + without
CD-Text) before merging.

---

**Re-entry checklist (any of F-1 / F-2 / F-3):**
1. `git checkout phase-5-library` (or main, if 5-library has
   merged by then) and `git pull`.
2. Re-read this D-015 entry plus the relevant Phase 5 lessons
   in `/memories/repo/musicripper-state.md`.
3. Branch `phase-5.5-rip-speed` / `phase-5.6-on-disc-metadata` /
   `feat/submit-disc-id` from the current tip.
4. Confirm current `Show-RipperMetadataDialog` and
   `Get-RipperDiscMetadata` shapes haven't drifted from what's
   described above.


---

## D-016 — Continuous mode: stay running between discs *(Phase 5.7)*

**Problem:** Today MusicRipper exits after one disc, so a parent
ripping a stack of CDs has to double-click the Desktop shortcut for
each one and re-answer the UAC prompt every single time. With
Phase 4-5 the per-disc loop is now a clean sequence (id → metadata
→ confirm → rip → quality → tag → move → eject), so the obvious
ergonomic win is to keep the application running and just go round
the loop again.

**Choice — Shape A (in-process loop), hybrid disc detection.**
Wrap the per-disc body of `Start-Ripper.ps1` in a function
(`Invoke-RipperOneDiscCycle`) and drive it from a new outer
`do { ... } while (True)` loop. After each cycle, show
`Show-RipperBetweenDiscsDialog` (new WPF window):

- Two buttons: `[Rip Next Disc]` (default) and `[Quit]`.
- Background WMI subscription via `Register-CimIndicationEvent`
  on `Win32_VolumeChangeEvent EventType=2` (volume arrival),
  filtered to `cfg.DriveLetter`. When a disc arrives, the
  subscriber marshals `window.Close()` onto the UI thread with
  Action='RipNext' / Trigger='AutoDetected', so the parent doesn't
  have to click anything.
- Window-X close == `Quit`.

A new config field `ContinuousMode` (default `true`) controls
whether the outer loop runs. `false` restores the original one-
disc-per-launch flow.

**Why Shape A over Shape B (relaunch shortcut + exit current):**
Shape B has zero state-leak risk but flickers a console between
discs, takes a measurable second to re-init the WPF runtime each
time, and makes "Quit after this disc" awkward. Shape A is the
better UX as long as we discipline per-cycle state — which we do
by wrapping the per-disc body in a function whose locals are
naturally garbage-collected when it returns.

**Why hybrid disc detection over either flavor alone:**

- Modal-only would force the parent to click "Rip Next" even when
  they've already inserted the next disc. Annoying for a stack.
- Auto-only (no modal) would mean there's no way to gracefully
  quit after a rip without ejecting and walking away — bad.
- Hybrid gets both: zero clicks for the common "swap disc" case,
  a clear Quit button for "I'm done."

**Logging.** Each iteration calls `Stop-RipperLog` then
`Start-RipperLog -Context "rip-disc-N"`, so
`%LOCALAPPDATA%\MusicRipper\logs\` ends up with one timestamped
file per disc. `Move-ToLibrary` already calls
`Copy-RipperLog` against whatever log is currently active, so the
album folder still receives its per-disc snapshot exactly as
before. The session-wide `start-ripper` log started at top of
script remains valid for any pre-loop work (config check, dep
check, orphan resume) and is rotated out when the first iteration
begins.

**Already-ripped-this-session prompt.** A script-scope hashtable
`\.RippedDiscs` keyed by `DiscId` records
every disc that finished a non-cancelled rip cycle. If the parent
re-inserts a disc with that id, a Yes/No message box asks "rip
again or skip?" before the metadata lookup. (Cancelled / failed
rips are NOT marked, so the parent can re-insert and try again
without the prompt.)

**Per-cycle error handling.** Per-disc failures (rip throws,
post-process throws, disc-id failures, unhandled exceptions) all
log + show a message box and `return` from the cycle function
rather than `throw`ing through the loop. The outer loop catches
any escapee with a last-ditch `try/catch` so the only way to exit
is through the between-discs dialog.

**Rejected:**

- **Auto-relaunch via Start-Process + exit.** See Shape B above.
- **Background-poll + auto-rip with no between-discs dialog at
  all.** Removes the user's chance to say "I'm done" without
  walking to the drive — and silently rips a disc inserted by
  accident.
- **Filter the WMI query down to `DriveName=...`.** Some
  platforms surface `DriveName` only on the inner
  `TargetInstance` rather than the top-level event, so the
  filter would silently miss arrivals. Filter in the action
  handler instead (cheap; events fire infrequently).
- **A separate "Continuous" tray icon.** Over-engineering for a
  single-process workflow that already has a window on screen.

**Wire:**

- `src/lib/Config.psm1` → `ContinuousMode = \True` default.
- `config/config.template.json` → field + comment.
- `setup/New-RipperConfig.ps1` → top-up detection + interactive
  Y/N prompt mirroring `EjectAfterRip`.
- `src/ui/Show-BetweenDiscsDialog.ps1` → new WPF window with
  dispatcher unhandled-exception sink (Phase-4 rule applies to
  every new window) writing to
  `%LOCALAPPDATA%\MusicRipper\logs\between-discs-dispatcher.log`.
- `src/Start-Ripper.ps1` → refactor per-disc body into
  `Invoke-RipperOneDiscCycle`; outer `do/while` driving it;
  per-iteration log rotate; session-state `\`
  with `DiscCount` / `RippedDiscs` / `LastSummary`.
- Tests: `Config.Tests.ps1` defaults assert `ContinuousMode -eq \True`.


---

## D-016 — Continuous mode: stay running between discs *(Phase 5.7)*

**Problem:** Today MusicRipper exits after one disc, so a parent
ripping a stack of CDs has to double-click the Desktop shortcut for
each one and re-answer the UAC prompt every single time. With
Phase 4-5 the per-disc loop is now a clean sequence (id → metadata
→ confirm → rip → quality → tag → move → eject), so the obvious
ergonomic win is to keep the application running and just go round
the loop again.

**Choice — Shape A (in-process loop), hybrid disc detection.**
Wrap the per-disc body of `Start-Ripper.ps1` in a function
(`Invoke-RipperOneDiscCycle`) and drive it from a new outer
`do { ... } while ($true)` loop. After each cycle, show
`Show-RipperBetweenDiscsDialog` (new WPF window):

- Two buttons: `[Rip Next Disc]` (default) and `[Quit]`.
- Background WMI subscription via `Register-CimIndicationEvent`
  on `Win32_VolumeChangeEvent EventType=2` (volume arrival),
  filtered to `cfg.DriveLetter`. When a disc arrives, the
  subscriber marshals `window.Close()` onto the UI thread with
  Action='RipNext' / Trigger='AutoDetected', so the parent doesn't
  have to click anything.
- Window-X close == `Quit`.

A new config field `ContinuousMode` (default `true`) controls
whether the outer loop runs. `false` restores the original one-
disc-per-launch flow.

**Why Shape A over Shape B (relaunch shortcut + exit current):**
Shape B has zero state-leak risk but flickers a console between
discs, takes a measurable second to re-init the WPF runtime each
time, and makes "Quit after this disc" awkward. Shape A is the
better UX as long as we discipline per-cycle state — which we do
by wrapping the per-disc body in a function whose locals are
naturally garbage-collected when it returns.

**Why hybrid disc detection over either flavor alone:**

- Modal-only would force the parent to click "Rip Next" even when
  they've already inserted the next disc. Annoying for a stack.
- Auto-only (no modal) would mean there's no way to gracefully
  quit after a rip without ejecting and walking away — bad.
- Hybrid gets both: zero clicks for the common "swap disc" case,
  a clear Quit button for "I'm done."

**Logging.** Each iteration calls `Stop-RipperLog` then
`Start-RipperLog -Context "rip-disc-N"`, so
`%LOCALAPPDATA%\MusicRipper\logs\` ends up with one timestamped
file per disc. `Move-ToLibrary` already calls `Copy-RipperLog`
against whatever log is currently active, so the album folder still
receives its per-disc snapshot exactly as before. The session-wide
`start-ripper` log started at top of script remains valid for any
pre-loop work (config check, dep check, orphan resume) and is
rotated out when the first iteration begins.

**Already-ripped-this-session prompt.** A script-scope hashtable
`$script:RipperSession.RippedDiscs` keyed by `DiscId` records every
disc that finished a non-cancelled rip cycle. If the parent
re-inserts a disc with that id, a Yes/No message box asks "rip
again or skip?" before the metadata lookup. (Cancelled / failed
rips are NOT marked, so the parent can re-insert and try again
without the prompt.)

**Per-cycle error handling.** Per-disc failures (rip throws,
post-process throws, disc-id failures, unhandled exceptions) all
log + show a message box and `return` from the cycle function
rather than `throw`ing through the loop. The outer loop catches
any escapee with a last-ditch `try/catch` so the only way to exit
is through the between-discs dialog.

**Rejected:**

- **Auto-relaunch via Start-Process + exit.** See Shape B above.
- **Background-poll + auto-rip with no between-discs dialog at all.**
  Removes the user's chance to say "I'm done" without walking to
  the drive — and silently rips a disc inserted by accident.
- **Filter the WMI query down to `DriveName=...`.** Some platforms
  surface `DriveName` only on the inner `TargetInstance` rather
  than the top-level event, so the filter would silently miss
  arrivals. Filter in the action handler instead (cheap; events
  fire infrequently).
- **A separate "Continuous" tray icon.** Over-engineering for a
  single-process workflow that already has a window on screen.

**Wire:**

- `src/lib/Config.psm1` → `ContinuousMode = $true` default.
- `config/config.template.json` → field + comment.
- `setup/New-RipperConfig.ps1` → top-up detection + interactive
  Y/N prompt mirroring `EjectAfterRip`.
- `src/ui/Show-BetweenDiscsDialog.ps1` → new WPF window with
  dispatcher unhandled-exception sink (Phase-4 rule applies to
  every new window) writing to
  `%LOCALAPPDATA%\MusicRipper\logs\between-discs-dispatcher.log`.
- `src/Start-Ripper.ps1` → refactor per-disc body into
  `Invoke-RipperOneDiscCycle`; outer `do/while` driving it;
  per-iteration log rotate; session-state `$script:RipperSession`
  with `DiscCount` / `RippedDiscs` / `LastSummary`.
- Tests: `Config.Tests.ps1` defaults assert `ContinuousMode -eq $true`.


---

## D-017 — Cross-session duplicate-rip detection via library check *(Phase 5+ backlog)*

**Status:** Deferred. Surfaced during Phase 5.7 manual verification
(Task 3) when the user asked whether the "already ripped this session"
prompt also catches discs ripped in *previous* sessions.

**Problem:** `$script:RipperSession.RippedDiscs` (D-016) only lives for
the lifetime of one Start-Ripper.ps1 process. Quit and relaunch and
the same disc will rip again with no warning, silently overwriting (or
worse, ReviewQueue-duplicating) work the user already finished. The
session-scoped check catches the "I forgot I just did this disc"
case but not the "I did this disc last weekend" case, which is the
more likely failure for a parents-grade tool used in short bursts.

**Approach (sketch):**

The library itself is the durable source of truth — if an album folder
already exists at the destination path, we already ripped this disc.
Two layers, cheap to check, both before the expensive rip:

1. **Fast path — DiscId index file.** Maintain
   `<library-root>/.musicripper/discids.json` mapping
   `DiscId -> { path, rippedAt, source }`. Append on every successful
   `Move-ToLibrary`. At the start of `Invoke-RipperOneDiscCycle`,
   right after `Get-DiscId`, look up the DiscId; if hit, prompt the
   user (Yes / No / Open in Explorer) before proceeding.
2. **Slow path — destination-folder probe.** If the JSON index is
   missing or stale (user moved files around manually), after metadata
   resolution we compute the would-be destination path and `Test-Path`
   it. Same prompt.

The session hashtable from D-016 stays in place as the in-memory
fast cache; the JSON index is its on-disk twin.

**Why JSON index over scanning:** Library may grow to thousands of
albums on a NAS share. Walking the tree on every disc insert would
add seconds of latency over SMB. A flat JSON keyed by DiscId is O(1)
and survives Synology snapshot/restore.

**Edge cases to handle:**
- ReviewQueue items shouldn't go in the index until they're approved
  and moved into the real library.
- "Rip again" (Yes) needs a clear destination strategy —
  overwrite, side-by-side `(2)` folder, or route to ReviewQueue for
  manual diff. Default proposal: side-by-side `(2)` so nothing is
  ever destroyed. The same three-way prompt should also replace the
  current late-stage `Move-ToLibrary` "already exists" throw
  (Move-ToLibrary.ps1#L316), which today is the only backstop for
  cross-session duplicates and forces the user to discover the
  collision *after* a 5-minute rip. Once the early index check is in
  place, the late-stage throw becomes a belt-and-braces safety net
  for index-miss cases (manual file moves, restored backups) and
  should reuse the same prompt UX rather than throwing.
- Index corruption: read errors fall back to the slow path, never
  block a rip.
- Multi-disc sets share TOCs across discs in some pressings; key on
  full DiscId (which includes track offsets), not just the freedb id.

**Files likely touched:**
- `src/core/Move-ToLibrary.ps1` — append to index on success.
- `src/Start-Ripper.ps1` — index lookup right after `Get-DiscId`,
  before metadata fetch.
- New `src/core/Get-LibraryDiscIndex.ps1` — read/write/repair the
  JSON.
- `tests/Get-LibraryDiscIndex.Tests.ps1` — round-trip + corruption
  recovery.

**Risk:** Low. Index is advisory; failure modes degrade to current
behaviour (no detection), never block the rip.

**Estimate:** Small-to-medium. A focused half-day plus tests.


---

## D-018 — Cross-session duplicate-rip detection (Phase 5.8)

**Status:** Implemented. Realises the F-1 layer of D-017.

**What it does:** Before any disc is ripped, MusicRipper consults a
durable JSON index at `<LibraryRoot>\.musicripper\discids.json` mapping
DiscId -> { Path, Label, RippedAt, Source }. On a hit (and the
recorded folder still exists), a polished WPF dialog
(`Show-RipperDuplicateDiscDialog`) offers three actions:

- **Skip rip** (default + Esc): eject + return to between-discs.
- **Open folder...**: `Invoke-Item` the prior album path; dialog
  stays open so the parent can decide after looking.
- **Rip again (keep both)**: proceed with the rip; the new copy
  lands side-by-side as `<Album> (<Year>) [rip 2]` (then `[rip 3]`
  ...) via `Move-RipToLibrary -AllowSideBySide`.

**Why the index file (vs. `Test-Path` on the destination):** the
album folder layout depends on metadata that hasn't been resolved yet
at the early-check point; we want to short-circuit before paying the
~5s metadata round-trip. The index keys on DiscId, which is known the
moment `Get-DiscId` returns. The slow-path `Test-Path` collision is
still caught by `Move-RipToLibrary`'s "target exists" throw at the
end of the rip -- belt and braces.

**Why JSON (vs. SQLite, walking the tree):** O(1) lookup, no native
dependency, survives Synology snapshots, human-inspectable. Library
size doesn't matter -- index size is one line per album, growing at
the rate of the user's ripping cadence.

**Square brackets in the side-by-side suffix:** `[rip N]` because
Plex's filename heuristics treat parenthesised tokens like `(2)` as
year/disambiguation, but ignore square-bracket tokens. Verified on
the Plex naming spec.

**Index hygiene:**
- Only `Library` moves are indexed; `_ReviewQueue` items stay out
  until they're approved into the real library (future work).
- Stale entries (folder deleted/moved) return `$null` from
  `Find-RipperLibraryDiscIndexEntry` so the dialog only fires on
  actionable hits.
- Read errors (corrupt JSON, missing file, NAS unreachable) degrade
  to "no record found" with a WARN log -- the index is advisory
  and never blocks a rip.
- Writes are atomic: `Set-Content` to `<file>.tmp`, `Move-Item` to
  the real path; failure cleans the tmp.
- Index writes from `Invoke-RipperPostProcess` are best-effort
  (try/catch -> WARN). A NAS write failure must not undo the move
  -- the rip is already on disk.

**Optional seeding tool:** `src/tools/Build-LibraryDiscIndex.ps1`
walks the library, reads `MUSICBRAINZ_DISCID` via `metaflac`, and
populates the index. Idempotent (skips entries already present
unless `-Force`). Not required by the runtime: the index will fill
itself one rip at a time. Surfaced for users who want detection of
existing albums right away.

**Tests:** 11 Pester cases in `tests/Get-LibraryDiscIndex.Tests.ps1`
cover round-trip, corruption recovery, stale-entry filtering,
upsert, multi-entry preservation, and missing-file behaviour. Plus
two new `tests/Move-ToLibrary.Tests.ps1` cases for `[rip 2]` /
`[rip 3]` selection, and three new `tests/Invoke-PostProcess.Tests.ps1`
cases for index-write call shape, `-AllowSideBySide` forwarding,
and best-effort failure swallowing.

**Files added:**
- `src/core/Get-LibraryDiscIndex.ps1` -- read/write/find primitives.
- `src/ui/Show-DuplicateDiscDialog.ps1` -- WPF three-way prompt.
- `src/tools/Build-LibraryDiscIndex.ps1` -- optional one-shot
  rebuild from `MUSICBRAINZ_DISCID` tags.
- `tests/Get-LibraryDiscIndex.Tests.ps1`.

**Files changed:**
- `src/core/Move-ToLibrary.ps1` -- new `-AllowSideBySide` switch +
  `IsSideBySide` field on the result.
- `src/core/Invoke-PostProcess.ps1` -- writes the index on
  `Library` route (best-effort), forwards `-AllowSideBySide`.
- `src/Start-Ripper.ps1` -- early dup-check + side-by-side flag
  threaded into the post-process call.

**Reverse references:** D-017 (the backlog entry that captured the
problem statement) is now implemented by this decision.


## D-019 -- Wire user-driven Send to Review through the rip pipeline (Phase 5.9)

**Status:** Implemented (Phase 5.9).
**Date:** 2026-04-24.

**Context:** The metadata dialog has had a Send to Review button
since Phase 3, but its Start-Ripper.ps1 switch arm was a stub: it
displayed a Phase 3 stub MessageBox and ejected the disc without
ripping. The intended workflow -- 'I want to fix metadata in Picard
before this lands in Plex' -- was therefore non-functional.

The supporting plumbing already existed: Invoke-RipperPostProcess,
Move-RipToLibrary, New-ReviewQueueArtifacts had all handled the
_ReviewQueue\ path since Phase 5 for *quality-gate-driven* routing
(SUSPECT/UNKNOWN). Only the user-driven entry point was missing.

**Decision:**
1. Add a `-ForceReviewQueue` switch to `Invoke-RipperPostProcess`.
   When set and `Test-RipQuality` reported `Destination=Library`,
   override to `Destination=ReviewQueue` with a distinct routing
   prefix `USER-REVIEW` so the folder name distinguishes user
   intent from auto-quality routing in `_ReviewQueue/`.
2. If the quality gate already routed to ReviewQueue (Suspect/Unknown),
   do NOT replace the prefix -- the auto-routing reason is more
   informative to the human triaging the queue.
3. Tagging is skipped on the forced review route (same as the
   auto-routed path): the raw disc state is what a human in Picard
   wants to see.
4. The cross-session DiscId index (Phase 5.8) is still NOT updated
   for review-queue rips, regardless of how they got there. The
   index represents 'this album is finished and in the library';
   review-queue entries are drafts.
5. `Start-Ripper` collapses the `'Rip'` and `'Review'` switch
   arms into one `{ \$_ -in 'Rip','Review' }` block. The only
   per-arm difference is a single `\$forceReviewQueue` boolean
   threaded through to `Invoke-RipperPostProcess`. Sidecar,
   eject, in-session tracking, and the rip-complete summary
   dialog are identical (the summary's destination line already
   reads 'Review queue: ...' because `Quality.Destination` was
   overridden upstream).

**Why USER-REVIEW (not e.g. MANUAL or DRAFT):** Matches the verb on
the button (`Send to Review`); short enough to fit Plex/Explorer
column widths; clearly distinct from the existing `SUSPECT` /
`UNKNOWN` / `LOWMATCH` prefixes.

**Why keep in-session tracking:** A re-inserted disc that was sent
to Review still triggers the Phase-5.7 'You already ripped this
this session' Yes/No prompt. The disc isn't in the durable index
(D-018), so the in-session check is the only guard. Skipping the
tracking would silently re-rip on re-insert, which is exactly what
Phase 5.7 was added to prevent.

**Files changed:**
- `src/core/Invoke-PostProcess.ps1` -- `-ForceReviewQueue` switch.
- `src/Start-Ripper.ps1` -- Rip+Review collapsed into one switch arm.
- `tests/Invoke-PostProcess.Tests.ps1` -- new `ForceReviewQueue`
  Describe block: routing override, no-double-override, no-tagging,
  artifacts-emitted, no-index-write.
- `docs/TROUBLESHOOTING.md` -- when to use Send to Review.

**Reverse references:** Phase 3 stub was introduced by the original
`confirm-dialog` work; this decision retires the stub.


## D-020 -- Honour EjectAfterRip on every disc-disposition path *(wontfix)*

**Status:** Wontfix (closed 2026-04-24 after live trial).
**Date:** 2026-04-24 (raised); 2026-04-24 (closed).

**Context:** Phase 5.4 added a per-rip `Eject disc when done` checkbox
in the metadata dialog (sourced from `cfg.EjectAfterRip`) which the
`Rip`/`Review`/`Cancel` arms in `Start-Ripper.ps1` honour via
`_maybeEject $choice`. But several earlier short-circuit paths --
fired before the metadata dialog ever opens -- still call
`Invoke-RipperEject` unconditionally:

- `Get-RipperDiscId` failure / `NoDisc` (line ~289).
- Phase-5.8 library duplicate dialog: `Skip` (line ~355) and
  `default`/unknown action (line ~365).
- Phase-5.7 in-session duplicate MessageBox: `No` answer (line ~391).

Surfaced during Phase 5.9 verification: `EjectAfterRip = False` in
config + clicking `No` on the in-session duplicate prompt still
ejected the disc.

**Decision (deferred):**
1. The unconditional eject in those paths exists because the user
   hasn't yet made a per-rip choice (the checkbox lives in the
   metadata dialog which hasn't opened). Treat `cfg.EjectAfterRip`
   as the fallback when no per-rip choice exists yet. New helper
   `_maybeEjectFromConfig` that reads `cfg.EjectAfterRip` (default
   `True` if missing); replace the four bare `Invoke-RipperEject`
   calls with it.
2. Audit other entry points for the same pattern:
   - `Resume.ps1` orphan-recovery completion path.
   - Any post-process failure `catch` blocks that eject.
   - The between-discs dialog `Quit` path.
   - Tools (`Complete-OrphanedRip`, `Update-AlbumTags`) -- shouldn't
     touch eject at all, but verify.
3. Document the contract in a header comment in `Start-Ripper.ps1`:
   "Anywhere we'd open the tray, defer to `_maybeEject $choice`
   (per-rip override) or `_maybeEjectFromConfig` (no per-rip choice
   available)."
4. Add a small Pester test that asserts `Invoke-RipperEject` is the
   ONLY function in `src/Start-Ripper.ps1` that calls
   `[mciSendString]` etc. -- everything else routes through the
   helpers (regression prevention).

**Why not in Phase 5.9:** 5.9 is scoped to wiring `Send to Review`;
the eject paths are pre-existing behaviour and unchanged by 5.9. No
data loss risk -- just a UX inconsistency. Cleanly separable into
its own small phase.

**Reverse references:** Eject-toggle was introduced in
`9835d1e feat(eject): per-rip eject toggle in confirm dialog (Phase 5.4)`;
this decision completes the audit that should have accompanied it.

**Outcome (2026-04-24):** Implemented on a short-lived branch
`phase-5.10-eject-audit` (commit `1a35f5f`) and trialled live. The
new behaviour felt wrong in practice: clicking `Skip rip` on the
library-duplicate dialog (or `No` on the in-session-duplicate
prompt) is fundamentally a "next disc, please" gesture, and the
parent expects the tray to open so they can swap discs --
regardless of `cfg.EjectAfterRip`. Drawing a finer line between
"skip-with-disc → eject" and "skip-without-disc → don't" is a
distinction nobody will remember six months from now.

**Final decision:** `cfg.EjectAfterRip` governs the *post-rip*
flows only -- the `Rip` / `Review` / `Cancel` arms in the metadata
dialog, routed through `_maybeEject $choice`. Pre-metadata
short-circuit paths (no-disc, library-dup Skip/default,
in-session-dup No) keep their unconditional `Invoke-RipperEject`
behaviour from before Phase 5.10. Branch discarded
(`git branch -D`); no code changes landed on `main`. Reproducer
from Phase 5.9 verification (`EjectAfterRip = false` + `No` on
in-session dup → still ejects) is now expected behaviour, not a
bug.

---

## D-021 -- Recover stranded rips when post-process hits "target already exists" (Phase 5.11)

**Context:** Live trial after Phase 5.10 fed a CD whose album was
already in the library but **not** indexed in `.musicripper\discids.json`
(pre-Phase-5.8 vintage). Outcome:

1. Disc-id lookup missed -> no `Show-RipperDuplicateDiscDialog`.
2. Rip + tag succeeded; sidecar written; rip lived in `_inbox\`.
3. `Move-RipToLibrary` threw "Target directory already exists..." for
   `Mannheim Steamroller\Christmas (1984)`.
4. `Invoke-RipperPostProcess` re-threw to `Invoke-RipperOneDiscCycle`'s
   catch, which surfaced a passive `Show-RipperInfo` warning and
   returned `Failed`.
5. The orphan-resume sweep only ran at script *startup*. In continuous
   mode, the next disc proceeded with the previous rip silently
   stranded.

**Choice:** Two-part fix on branch `phase-5.11-orphan-rescan-target-exists`.

1. **Between-cycle orphan rescan.** Refactor the startup orphan-resume
   block in `Start-Ripper.ps1` into `Invoke-RipperResumeOrphans
   [-Quiet]` returning `Continue` / `Quit`. Continuous-mode loop calls
   it (`-Quiet`) after `Show-RipperBetweenDiscsDialog`'s `RipNext` so
   any orphan from the previous cycle gets the same YesNoCancel prompt
   the user already knows from launch.
2. **Interactive target-exists dialog.** `Move-RipToLibrary` now throws
   `[System.IO.IOException]` with `Exception.Data['TargetExists']` =
   resolved target path (message preserved -> existing
   `*already exists*` test still passes). The post-process catch in
   `Invoke-RipperOneDiscCycle` walks `InnerException` looking for that
   marker and, when found, calls a new WPF
   `Show-RipperTargetExistsDialog` (`src/ui/Show-TargetExistsDialog.ps1`).
   Five buttons: *Open existing...* (best-effort `Invoke-Item`, dialog
   stays open), *Discard new rip*, *Send to Review*, *Leave for now*
   (IsCancel + close-X), *Keep both* (IsDefault, green). Branches:
   - **SideBySide / Review** -> retry `Invoke-RipperPostProcess` with
     `-AllowSideBySide` or `-ForceReviewQueue`.
   - **Discard** -> `Move-RipperFolderToRecycleBin` (a thin wrapper
     around `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory`
     with `RecycleOption.SendToRecycleBin`) so the orphan is
     **recoverable**, not hard-deleted.
   - **Leave** -> passive notice; the new between-cycle rescan picks
     it up.

**Alternatives considered:**

- **Just always force side-by-side.** Rejected: silent duplicates
  pollute the library and the user can't tell *which* disc he just
  ripped at a glance.
- **Hard-delete the new rip on Discard.** Rejected per user instruction:
  Recycle Bin keeps the recovery path open if the user changes his mind.
- **Pre-flight target check before ripping.** Considered for a future
  phase; today the rip is fast enough that catching at move-time and
  recovering interactively is fine, and it keeps `Move-RipToLibrary`
  the single source of truth for collision policy.
- **Always route to `_ReviewQueue\` on collision.** That's now one of
  the offered actions; not the only one because the most common case
  during the parents' use is the album genuinely is the same and the
  rip should be discarded.

**Tests:**

- `tests/Move-ToLibrary.Tests.ps1` -- new case asserts
  `Exception.Data['TargetExists']` is populated and ends in
  `Spirit of the Season (2007)`.
- `tests/Show-TargetExistsDialog.Tests.ps1` -- input validation for
  `Move-RipperFolderToRecycleBin` (missing path, file-not-dir,
  `-WhatIf` no-op) plus a source-contract scan for the dispatcher
  sink and the four documented actions. WPF window itself is not
  driven from Pester (same convention as `Show-DuplicateDiscDialog`).
- Full suite: 324 passed / 0 failed / 1 skipped (was 318 before
  Phase 5.11).

**Manual verification:** User left the stranded
`_inbox\Mannheim Steamroller - Christmas\` in place and will re-run
MusicRipper after merge to confirm the dialog appears, each branch
behaves, and discarded folders land in the Recycle Bin recoverable.
