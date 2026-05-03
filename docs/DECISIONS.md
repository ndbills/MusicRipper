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
generic clients into one shared quota. We pass `cfg.contactAddress`
directly (an email is what the GnuDB hello= contract really wants;
URL forms still get accepted but won't satisfy the spirit of the
policy) and identify as `musicripper/<version>`. One query + up to 3
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

---

## D-022 -- Sync framework + LocalRetention (Phase 6.1)

**Context:** Phase 5 closed the rip-to-tagged-library loop. The
single remaining gap before parents could safely use the box was
"the rip box must not be the only copy." Phase 6 splits into four
sub-phases:

- **6.1** -- generic sync framework + built-in `Stub` target +
  `LocalRetention` (this decision).
- **6.2** -- `OneDrive` sync target.
- **6.3** -- `SynologyNAS` sync target over LAN.
- **6.4** -- `SynologyNAS` over a self-hosted WireGuard tunnel
  (see [SYNOLOGY-SHARE-SETUP.md](SYNOLOGY-SHARE-SETUP.md) Part B
  for the planned tunnel-management API).

**Choice:** Provider-chain pattern (mirrors D-011 metadata
providers + the cover-art chain). Two new top-level config fields:

```jsonc
{
  "SyncTargets":     [],          // ordered list of target names
  "LocalRetention":  "Keep"       // Keep | MoveToSentAfterAllSynced | RecycleAfterAllSynced
}
```

Empty defaults preserve pre-Phase-6 behaviour bit-for-bit.

**Module layout:** new `src/sync/` directory.
- `Get-LibrarySyncState.ps1` -- durable per-album index at
  `<LibraryRoot>\.musicripper\sync-state.json`. Sibling of
  `discids.json` (D-018) with the same advisory-write rules.
- `Invoke-RipperSync.ps1` -- orchestrator + the built-in
  `Invoke-RipperSyncToStub` target (writes a marker file under
  `.musicripper\stub-sync\<rel>\.synced`).
- `Invoke-LibraryRetention.ps1` -- consumes the orchestrator
  result and applies the retention rule when (and only when) the
  rip wasn't `Skipped` and every target reported `OK`.

**Per-target contract** (matches what the orchestrator persists):

```powershell
@{
    Target      = '<Name>'           # forced to match the configured name
    Status      = 'OK' | 'Failed' | 'Skipped'
    BytesCopied = [int64]<n>
    Diagnostic  = $null | '<message>'
}
```

Targets MAY return a `pscustomobject` of the same shape; the
orchestrator normalises to a hashtable. Targets MAY throw; the
orchestrator catches and synthesises a `Failed` result. Targets
NEVER block the rip -- `Invoke-RipperPostProcess`'s sync call is
itself wrapped in try/catch as a belt-and-braces guard.

**Retention modes:**

| Mode                          | Action                                                                                                               |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `Keep`                        | No-op. Album stays in the library.                                                                                   |
| `MoveToSentAfterAllSynced`    | `Move-Item` to `<LibraryRoot>\_Sent\<Artist>\<Album>\`. Side-by-side `[moved N]` suffix on collision. `discids.json` rewritten with `Source='sent'` so duplicate detection still hits. |
| `RecycleAfterAllSynced`       | `Move-RipperFolderToRecycleBin` (D-021). `discids.json` entry rewritten with `Source='recycled'` so re-insert still trips the duplicate-disc dialog -- having ripped this CD before is independent of whether the local copy still exists. The duplicate-disc dialog hides its Open-folder button when the recorded path is intentionally gone. |

`Source='sent'` and `Source='recycled'` are new values on the
`discids.json` `Add-RipperLibraryDiscIndexEntry -Source` validate-set.
`Find-RipperLibraryDiscIndexEntry` skips its path-exists guard for
recycled entries (and only recycled entries -- a vanilla `library`
row with a missing folder still self-heals to `$null`).

**Sync-state vouch for manually-cleaned-up albums.** When a `library`
row's recorded path no longer exists, `Find-RipperLibraryDiscIndexEntry`
best-effort consults `sync-state.json` for the same album-relative
key: if any target reported `Status='OK'`, the entry is surfaced
with its original Label/RippedAt and the duplicate-disc dialog
fires (with the same path-hidden styling as the recycled case).
That covers the realistic family workflow where a parent ships
the rip box's library to a NAS over time and then frees up disk
space by deleting albums by hand -- they still get the "you
already ripped this CD" prompt on re-insert. Genuinely-stale rows
(deleted before any sync vouch) continue to self-heal silently.
The sync-state lookup is a soft Get-Command import so tools that
load only `src/core/` still work.

**Wiring into the rip pipeline:**

- `Invoke-RipperPostProcess` gains `-Config $cfg` (optional, for
  back-compat with existing tests). When supplied, after the
  Library move + log copy, it runs
  `Invoke-RipperSync ... -Config $cfg` and \u2014 unless the result
  came back `Skipped` \u2014 then `Invoke-RipperLibraryRetention`. Both
  calls are try/catch'd; failures populate
  `result.Sync.Diagnostic` / `result.Retention.Diagnostic` and log
  `WARN`. If retention moves the folder, the result's `Target`
  reflects the new path.
- `Resume-RipperOrphan` and `src/tools/Complete-OrphanedRip.ps1`
  thread `-Config` through the same way so orphan-resume gets the
  same sync + retention treatment.

**Rejected alternatives:**

- *Per-target post-processor scripts under
  `src/postprocessors/`* (the original Phase-6 plan). Rejected:
  no shared retention layer, no shared persistence, every target
  has to re-implement the "have I already pushed this?" check.
  The empty `src/postprocessors/.gitkeep` was removed in this
  phase.
- *Library-level sync (mirror the whole tree)*. Rejected: hides
  per-album status, defeats retention, and conflicts with the
  user-stated goal that the LibraryRoot stays local and authoritative.
- *Refuse to retire the local copy until the user says so*. The
  three-mode `LocalRetention` setting *is* that opt-in; defaulting
  to `Keep` means the safe behaviour is the path of least
  resistance.

**Tests:** 35 new Pester cases across
`Get-LibrarySyncState.Tests.ps1`,
`Invoke-RipperSync.Tests.ps1`,
`Invoke-LibraryRetention.Tests.ps1`, plus 6 new cases in
`Invoke-PostProcess.Tests.ps1` covering the wiring (back-compat
when `-Config` omitted; sync+retention dispatched; retention
skipped when sync was `Skipped`; retention failure swallowed;
review-queue route does NOT sync). Full suite: **359 passed / 0
failed / 1 skipped** (was 324 / 0 / 1 at end of Phase 5.11).

**Lessons (recorded in `/memories/repo/musicripper-state.md`):**

- A bare `@()` literal as a `[pscustomobject]` NoteProperty value
  unrolls to `$null` on property access. Cast to `[string[]]@()`
  (or `[object[]]@()`) to keep an empty-array shape on round-trip.
- Pester 5 treats `<token>` substrings in `Describe` / `It`
  names as data-driven placeholders -- they're interpreted as
  `$token` and fail at run-time when the variable isn't set.
  Use plain prose instead (e.g. "the .musicripper sync-state.json
  path under library root").
- Under `Set-StrictMode -Version 3.0`, an empty
  `Where-Object` pipe returns `AutomationNull`, which has no
  `.Count`. Wrap the pipe in `@(...)` whenever you call `.Count`
  on the result.

---

## D-023 -- OneDrive sync target (Phase 6.2)

**Context:** Phase 6.1 shipped the sync framework, the durable
`sync-state.json` index, the `Stub` test target, and the
`LocalRetention` policy. Phase 6.2 ships the first real off-box
target: copy each finished album into a folder inside the user's
OneDrive and let the OneDrive client upload it.

**Choice:** `robocopy /E /COPY:DAT /R:2 /W:5 /NP /NFL /NDL /NJH /BYTES`.

| Switch       | Why |
|--------------|-----|
| `/E`         | Copy subdirs incl. empty -- rare for a finished album, but harmless. |
| `/COPY:DAT`  | Data + Attributes + Timestamps. **Skip Security** -- OneDrive's sync engine ignores NTFS ACLs, including them slows the copy and spams the OneDrive activity log. |
| `/R:2 /W:5`  | 2 retries, 5s wait. Robocopy's defaults (1M retries x 30s) are fine for an unattended overnight pass and ruinous in the foreground rip pipeline. |
| `/NP /NFL /NDL` | No progress %, no per-file or per-dir lines. We only need the trailing summary block. |
| `/NJH`       | Suppress the job header. |
| `/BYTES`     | Byte counts in the summary so we can parse `BytesCopied` without rescanning the source. |

No `/MIR`. The framework already invokes one target per album;
mirroring at the library root would risk purging anything inside
the OneDrive folder we didn't put there.

**Pre-flight:** two checks before any copy runs.

1. OneDrive client must be installed for the current user. We
   detect it via `HKCU\Software\Microsoft\OneDrive\UserFolder`
   (set by the client at first sign-in), with fallbacks to
   `Accounts\Personal\UserFolder` and `$env:OneDrive`. Missing ->
   `Status='Failed'` with a Diagnostic that tells the user to
   install + sign in then re-run `src/tools/Sync-PendingAlbums.ps1`.
2. The configured `cfg.OneDriveSyncTargetRoot` must exist on disk.
   We deliberately do NOT auto-create it -- creating folders inside
   OneDrive can confuse the client, and a missing target root
   usually means "config is stale" rather than "make a new folder,
   please". Failed with a Diagnostic.

Both pre-flight failures are recorded as `Status='Failed'` so the
album sticks in `KeepTargetsNotOk` retention; once the user fixes
the underlying issue, `Sync-PendingAlbums.ps1` retries cleanly.

**Status mapping** (robocopy bit-flag exit codes):
- `0..7` -> `OK` (0 = nothing to copy, 1 = files copied, 2 = extras
  detected, 4 = mismatches detected, etc. -- all benign).
- `>=8`  -> `Failed`. Bit 8 = "files failed to copy after retries",
  bit 16 = "fatal error (destination unreachable / out of disk?)".
  Diagnostic includes the last 6 lines of robocopy output.

**Config:** the legacy `OneDrivePath` field is renamed to
`OneDriveSyncTargetRoot` (Phase 6.1 shipped before any user had
configured it; no back-compat shim needed). `setup/New-RipperConfig.ps1`
pops a Windows Forms `FolderBrowserDialog` seeded at the registry-
detected OneDrive root so the user navigates inside it instead of
typing the path. Cancelling the dialog leaves the field unset; the
user can re-run setup or hand-edit `config.json` later. **No mid-rip
prompts** -- a missing target at sync time fails fast and drops into
the existing retry tool, which preserves the unattended batch flow.

**Files added:**
- `src/sync/Sync-ToOneDrive.ps1` -- target + the registry helper
  `Get-RipperOneDriveUserFolder` + the pure helpers
  `Get-RipperOneDriveStatusFromExitCode` and
  `Get-RipperOneDriveBytesCopied`.
- `tests/Sync-ToOneDrive.Tests.ps1` -- exit-code mapping, byte
  parsing, both pre-flight failures, and a real robocopy
  integration test against a temp folder pretending to be the
  OneDrive root.

**Files changed:**
- `src/lib/Config.psm1` -- `OneDrivePath` parameter renamed to
  `OneDriveSyncTargetRoot`.
- `setup/New-RipperConfig.ps1` -- folder picker + new field name.
- `config/config.template.json` -- field rename + docstring.
- `src/Start-Ripper.ps1` and `src/tools/Sync-PendingAlbums.ps1` --
  dot-source the new target.
- `tests/Config.Tests.ps1` -- field rename in fixture.

---

## F-4 -- OneDrive notifier so the user sees sync status without opening the app *(deferred to Phase 8)*

**Problem:** Once `Sync-ToOneDrive.ps1` lands in Phase 6.2 the
album is queued into the OneDrive client's pending list, but the
user has no surface that says "the last 5 rips made it up." The
parents-facing flow shouldn't require opening the OneDrive system-tray
flyout.

**Sketch:** A small toast on rip completion that reflects
`sync-state.json`'s view of the current album. Ties into Phase 7
polish but doesn't need to block 6.2 -- the framework already
records the data; only the surfacing is missing.

**Re-entry:** revisit after Phase 6.4 (WireGuard) ships and 7
starts; same notifier infrastructure can also surface VPN-up /
NAS-unreachable warnings.

---

## F-5 -- Sync per-disc session logs off-box for remote troubleshooting *(deferred)*

**Problem:** Phase 6.1's `Copy-RipperLog` snapshots the per-disc
session log into each album folder *before* the sync block runs, so
the in-album copy never contains the `Sync` / `Retention` events
(spotted during Phase 6.1 manual verification). The full per-disc
log lives at
`%LOCALAPPDATA%\MusicRipper\logs\<timestamp>-rip-disc-<N>.log` on
the rip box and is therefore invisible from anywhere else \u2014 there's
no way to triage a broken sync target without sitting at the
machine.

**Sketch:**

- Add a fourth target-style hook (or piggyback on an existing target
  like `OneDrive` / `SynologyNAS`) that pushes the rip box's log
  directory \u2014 not just a per-album snapshot \u2014 to a known location
  off-box. Plain SMB / OneDrive folder mirror is plenty; nothing
  parses these logs, a human reads them.
- Push at end of each rip cycle (so the latest disc's log is up
  there immediately), and at MusicRipper exit (so the closing
  session log lands too). De-bounce / dedupe by mtime so we don't
  re-upload unchanged files.
- Honour the same `cfg.SyncTargets` flexibility \u2014 e.g.
  `cfg.LogSyncTarget = 'SynologyNAS'` (or `null` = off) so the
  user can pick where logs go independently of where albums go.
  Default off; opt-in via `New-RipperConfig.ps1`.
- Optional follow-up: also reorder the per-album `Copy-RipperLog`
  call to run *after* the sync block so the in-album snapshot
  includes the sync events. Trade-off: a partially-synced album's
  log won't be self-contained until the next snapshot. Easy to
  reverse, decide when implementing.

**Re-entry:** pick up after Phase 6.3 / 6.4 \u2014 by then we know which
remote target the user actually relies on, so the log-sync can ride
the same plumbing instead of inventing a parallel path. Cross-link
to F-4 (notifier): a "sync failed" toast can deep-link to the
synced log location.

**Reverse references:** D-017 (the backlog entry that captured the
problem statement) is now implemented by this decision.

---

## F-6 -- Standalone "MusicRipper – Settings" Start Menu shortcut for editing config *(Phase 8)*

**Status:** Implemented.
**Date:** 2026-05-01.

**Problem.** The Phase 6.6 WPF config editor (`Show-RipperConfigDialog`)
is currently reachable only via the first-run path in `Start-Ripper.ps1`
or the no-drive-registered prompt. A parent who wants to add a sync
target, change `LibraryRoot`, refresh DPAPI creds, or swap the
WireGuard tunnel after install has no friendly entry point.

**Choice.** Add a fourth Start Menu shortcut, **"MusicRipper – Settings"**,
pointing at a new `src/tools/Show-RipperConfig.ps1` adapter that imports
the relevant modules, calls `Show-RipperConfigDialog -Config $cfg
-ConfigPath $path`, and exits. No in-app gear button on the rip /
between-discs windows.

**Reload model: next launch only.** The Save toast reads "New settings
will apply the next time MusicRipper runs." This is honest whether the
app is closed, idle, or mid-rip — see runtime safety analysis below.

**Why no in-app gear / live reload:**
- `LibraryRoot` mid-session would split-brain `_inbox`, `discids.json`,
  and `sync-state.json` for an in-flight rip.
- WireGuard refcount/env-var sentinel (`MUSICRIPPER_WG_SESSION_REF`)
  is per-session; swapping tunnels mid-session would orphan a tunnel
  we started.
- Drive letter is captured by the rip-progress runspace, the
  between-discs DispatcherTimer, and the MCI tray-close code — a
  mid-session swap means tearing all of those down.
- DPAPI creds are imported into sync-runspace closures at sync time;
  edits don't bite the active runspace anyway.
- The mid-session-safe knobs (providers, `EjectAfterRip`,
  `ContinuousMode`) are not worth a separate "live-reload allowlist"
  code path. Parents already understand "save and relaunch" from
  every other Windows app.

**Why no in-process race when both run simultaneously:**
- Main app reads `cfg` once at startup (Phase 6.6 made
  `Get-RipperConfig` startup-only); it never polls.
- Main app does not write `config.json`. State writes go to
  `discids.json` / `sync-state.json` — disjoint from the editor's
  writes.
- No single-instance Mutex exists today (or is needed). Settings is
  a separate pwsh process and parent file-locks via `Save-RipperConfig`
  are short-lived.

**Implementation sketch.**
1. New `src/tools/Show-RipperConfig.ps1` — thin adapter (~30 lines):
   import `Common`, `Logging`, `Config` modules; dot-source
   `Show-RipperConfigDialog.ps1`; resolve `$configPath` via
   `Get-RipperConfigPath`; load cfg if present (or pass `-FirstRun`
   if absent so a never-installed user still gets the right flow);
   call `Show-RipperConfigDialog`; exit 0 regardless of save/cancel.
   Same dot-source / module-import pattern as
   `src/tools/Sync-PendingAlbums.ps1`.
2. New shortcut entry in `setup/Install-StartMenuShortcuts.ps1`
   pointing at the adapter. Use the same icon as the main app
   (`assets/musicripper-app-icon.ico`).
3. One-line update to the Save-confirmation MessageBox in
   `Show-RipperConfigDialog.ps1` to read "New settings will apply
   the next time MusicRipper runs." (Currently silent on OK; the
   tooltip on the Save button already says "Restart MusicRipper to
   apply.")
4. Remove the stale `.NOTES` reference to a never-shipped
   between-discs Configure... button in `Show-RipperConfigDialog.ps1`.
5. Docs:
   - `docs/SETUP.md` — note the new entry point in the install
     output section.
   - `docs/PARENTS-QUICKSTART.md` — one short paragraph + screenshot
     placeholder under a new "Changing settings later" subsection.
   - `README.md` directory-map — list `src/tools/Show-RipperConfig.ps1`.
6. No new Pester surface needed; the dialog and `Save-RipperConfig`
   already have tests, and the adapter is glue.

**Out of scope (re-pick if/when parents ask):**
- In-app gear button on rip-progress / between-discs windows.
  Same dialog code, just a different entry point with a "changes
  apply on next launch" header banner.
- Live-reload allowlist for mid-session-safe knobs.
- Single-instance enforcement on the main app (orthogonal; not
  required for F-6 to be safe).

**Re-entry checklist:** branch `phase-8-config-shortcut` from `main`;
verify Settings shortcut launches cleanly with no rip session active;
verify two-process scenario (main app running, open Settings, save,
exit Settings, finish current rip, relaunch — confirm new cfg in
effect on the second launch); update README "Current status" table
+ docs index.

**Cross-references:** Phase 6.6 (config editor implementation),
Phase 7 (Start Menu shortcut infrastructure in
`setup/Install-StartMenuShortcuts.ps1`), F-4 (notifier — separate
Phase 8 backlog item, not bundled).

**Outcome.** Three commits on `phase-8-config-shortcut`, merged to
`main` with --no-ff:
- `0f935f6` docs: this entry, recorded up-front before any code.
- `bc3c924` feat: `src/tools/Show-RipperConfig.ps1` adapter, third
  Start Menu shortcut, Save-toast (suppressed in `-FirstRun` because
  Start-Ripper enters the rip flow immediately and there is no
  "next launch" to wait for), removed the stale `.NOTES` reference
  to a never-shipped between-discs Configure... button. Pester
  522/0/1 (Phase 7 baseline unchanged).
- `16b9599` fix: foreground-the WPF when launched from the Settings
  shortcut. **Gotcha not anticipated in the original sketch:** the
  .lnk's `WindowStyle=7` (Minimized) on pwsh, combined with the WPF
  opening <100 ms after pwsh starts, let the dialog inherit
  `SW_SHOWMINIMIZED` from the parent process and/or fail to activate
  due to foreground-rights timing. Fix matches the long-standing
  pattern in `src/Start-Ripper.ps1`: the adapter self-minimizes the
  pwsh host via `MusicRipper.Win32.ShowWindow(SW_MINIMIZE)` before
  importing modules, and the dialog's `Loaded` handler also forces
  `WindowState = Normal` alongside the existing
  Topmost+Activate-on-Loaded sequence. Belt-and-suspenders against
  elevated launches that don't honour the .lnk WindowStyle.

**Manual verification (1 May 2026).** All re-entry-checklist items
passed end-to-end: clean launch from Settings shortcut, foreground
steal works, Save toast fires, change persists across re-open, no
interference observed when launched alongside a running main app.

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


## D-024 -- Synology NAS sync target (Phase 6.3)

**Context:** Phase 6.2 shipped the OneDrive sync target. Phase 6.3 adds `SynologyNAS` -- the third built-in sync target after `Stub` and `OneDrive`. It mirrors one album per call onto an SMB share (typically a Synology DSM Shared Folder, though any UNC server works) via robocopy, optionally authenticating with a DPAPI-protected credential captured at setup time.

**Decision:** Implement as `src/sync/Sync-ToSynologyNAS.ps1` exporting `Invoke-RipperSyncToSynologyNAS`. Re-uses the OneDrive target's pure helpers (`Get-RipperOneDriveStatusFromExitCode`, `Get-RipperOneDriveBytesCopied`) since the robocopy output shape is identical -- duplicating the parsers would create two places to fix any future robocopy quirk.

**Authentication model:** When `cfg.HasSynologyCredential = True`, the target loads the DPAPI-protected `PSCredential` via `Import-RipperCredential` (file at `%LOCALAPPDATA%\MusicRipper\credentials.clixml`), mounts the share root via `New-SmbMapping` for the duration of one album sync, then unmounts via `Remove-SmbMapping` in `finally`. When the flag is false, no mount is attempted and robocopy uses ambient session credentials.

**Why `New-SmbMapping` over `cmdkey /add`:** `cmdkey` writes the credential into Windows Credential Manager (DPAPI-encrypted but visible to other processes running as the same user) and *leaves it there* if the rip is killed mid-pipeline -- a parent-friendly tool can't rely on the user knowing to clean that up. `cmdkey` also takes the password on the command line, briefly visible to any process that snoops `Win32_Process`. `New-SmbMapping` keeps the credential in-process, scopes the mapping to the current logon session (auto-cleared on PowerShell exit), and supports concurrent mounts to the same server from different sessions. The `cmdkey` path could be added later as a separate sync-target type if a user really needs it.

**Robocopy switch differences vs OneDrive:**
- `/Z` (restartable) added: a NAS link drop mid-album is far more likely than a OneDrive folder write failing, and resume saves a full re-copy on transient blips. Worth the per-file overhead on flaky home networks.
- `/R:5 /W:10` (vs OneDrive's `2/5`): home WiFi rebounds in 30s; bumped retries are still bounded so the foreground rip pipeline never hangs forever.

**Pre-flight checks (all fail fast with `Status='Failed'` + diagnostic):**
1. `cfg.SynologyUnc` is set.
2. If `cfg.HasSynologyCredential = True`, `credentials.clixml` exists and decrypts.
3. (Post-mount) `Test-Path` on the configured root succeeds. This surfaces "NAS off" / "wrong password" before robocopy spends 30s timing out.

**Setup UX (`setup/New-RipperConfig.ps1`):** When the user enters a UNC, prompt:
- If a credential is already stored: "A NAS credential is already stored. Re-enter? (y/N)" -- defaults N so re-running setup never silently asks for the NAS password again.
- If no credential is stored: "Store a NAS credential now? (Y/n) -- needed if the share is not already mapped in Explorer" -- defaults Y (the common case).

**Files added/changed:**
- `src/sync/Sync-ToSynologyNAS.ps1` -- new target.
- `src/Start-Ripper.ps1` -- dot-source at top + inside the post-process runspace.
- `src/tools/Sync-PendingAlbums.ps1` -- dot-source.
- `setup/New-RipperConfig.ps1` -- `knownSync` += `'SynologyNAS'` and the new credential-prompt logic.
- `config/config.template.json` -- updated `SynologyUnc` / `HasSynologyCredential` / `SynologySyncReviewQueue` comments.
- `tests/Sync-ToSynologyNAS.Tests.ps1` -- 16 tests covering helpers, pre-flight, robocopy integration (via local folder), and SMB mount lifecycle (mocked).
- `docs/SYNC-TARGETS.md` -- `SynologyNAS` row in built-in targets table.
- `README.md` -- Phase 6.3 marked complete.

**Pester:** 400/0/1 green.

**Cross-references:** D-022 (sync framework), D-023 (OneDrive target). Phase 6.4 will reuse this same target over WireGuard -- no code change expected, just a setup-doc addition for the VPN tunnel.

## D-025 -- Startup pending-sync resync UI (Phase 6.5)

**Date:** 2026-04-29
**Phase:** 6.5
**Status:** Implemented.

### Problem
Phase 6.3 left us in a place where a transient NAS outage (NAS off, network blip, VPN dropped) downgrades a per-album `Invoke-RipperSync` result to `Failed` and writes that into `<LibraryRoot>\.musicripper\sync-state.json`. The rip pipeline keeps going (intentional -- see D-022), but the album never makes it to the NAS. We had a CLI tool (`src/tools/Sync-PendingAlbums.ps1`) that walks `sync-state.json` and retries every non-OK entry, but a parent user is unlikely to remember it exists. Without an automatic catch-up, "rip a stack of CDs while the NAS is off" silently produces a half-mirrored library.

### Decision
At launch, **before the disc-rip loop starts**, MusicRipper shows a WPF dialog (`Show-RipperPendingSyncProgress`) that retries every album whose previous sync didn't finish. The dialog is gated by `cfg.RetryPendingSyncOnStartup` (default `$true`) and skipped silently when `sync-state.json` has nothing pending.

### Why a startup dialog (not a tray app / not background)
- The user is already at the keyboard about to use MusicRipper -- this is the cheapest UX moment to surface "hey, three albums are still pending."
- A tray app or scheduled task would mean another piece of always-on infrastructure to install on Mom's laptop. Phase 1 explicitly stays single-script-launch (D-001).
- Doing it strictly in the foreground, before the disc-id read, means there's no race with the rip pipeline, no shared file-lock contention on `sync-state.json`, and no surprise "why is my CD ripping slow?" (the NAS would be fighting the ripper for disk + network).

### UI shape
- **Pre-flight panel:** lists every pending album (with the actual artist/album label resolved via `Get-RipperLibraryDiscIndex`) plus which targets are missing/failed. Two buttons: `Sync now` (default) and `Cancel (rip discs instead)`.
- **Working panel:** swaps in once `Sync now` is clicked. Two progress bars (overall "album N of M" + per-album indeterminate marquee) and a status line. Cancel turns into "Cancelling after current album finishes...".
- **Summary panel:** mandatory click-through (no auto-close, per user's explicit ask). Headline + friendly explanatory body + per-album result list. `OK` closes. Three flavours of headline:
  - All synced: green, "All caught up. N album(s) synced."
  - Cancelled mid-run: red-ish, "Stopped at your request" + reassurance the rest will retry next launch.
  - Some still failing: amber, "K of N synced. M still failing" + likely-cause hints (NAS off, OneDrive offline, creds need refresh).

### Cancellation semantics
- Cancel sets a synchronised-hashtable flag that the worker runspace polls **between** albums, not mid-album. Robocopy without `/MIR` is safe to leave half-done -- the next retry sees a size mismatch and re-copies just the partial file. Killing robocopy mid-flight saves a few seconds at the cost of leaving a thread half-bound to a network handle, which is the worse trade.
- The current album finishes; the dialog jumps straight to the summary panel marked `Cancelled=$true`.
- The caller (`Start-Ripper.ps1`) treats `Action='Cancelled'` as a successful skip and falls through to the normal disc-rip flow. We never crash the launch path because the resync UI threw -- the `try/catch` around the call logs WARN and proceeds.

### Cross-runspace plumbing (gotcha-driven)
- The worker runs in a fresh STA runspace (per Phase-1 lesson: the parent function table doesn't follow scriptblocks across runspace boundaries, so we re-`Import-Module` and re-dot-source every dependency inside the runspace's `AddScript` block).
- Cancel flag goes through `[hashtable]::Synchronized(@{...})` -- not `[ref]$arr[0]`, which snapshots.
- `ProgressCallback` and `CancelRequested` are scriptblocks that close over `$shared`; the worker re-creates them inside the runspace as plain blocks (no need for `[scriptblock]::Create()` here because they're declared inline within the AddScript body).

### Reuse of the core function
Both this dialog and the existing CLI tool (`src/tools/Sync-PendingAlbums.ps1`) call into a new pure-logic core, `Invoke-RipperPendingSync` (in `src/sync/Invoke-PendingSync.ps1`). The CLI tool keeps a console adapter that prints colored status with `Write-Host`; the dialog provides a WPF adapter that mutates the synchronised state hashtable. Both adapters use the same `ProgressCallback` shape, so future callers (a tray app in some hypothetical Phase 8) need only supply a callback.

### Rejected alternatives
- **Re-trigger on every disc rip.** Cheap to implement but hammers the NAS for no reason on the 95% of launches where everything is already synced; would also delay every disc rip's `Move-ToLibrary` finish.
- **Run the resync invisibly in a background runspace.** No user feedback when the NAS is still off after retry, no easy way to surface "hey, you should plug in the NAS" -- defeats the whole point.
- **`/MIR` + `/FORCE` on robocopy.** `/MIR` would delete files we *want* to keep on the NAS but no longer have locally (after `LocalRetention=RecycleAfterAllSynced`). `/FORCE` is for read-only attribute fights, not what we have here.

### Files changed
- `src/sync/Invoke-PendingSync.ps1` -- NEW. `Get-RipperPendingSyncPlan` + `Invoke-RipperPendingSync` (pure-logic core, used by both CLI and UI).
- `src/ui/Show-PendingSyncProgress.ps1` -- NEW. WPF dialog with pre-flight / working / summary panels.
- `src/Start-Ripper.ps1` -- startup hook (between `Import-RipperConfig` and the do/while disc loop), guarded by `cfg.RetryPendingSyncOnStartup` and a `try/catch` that downgrades any failure to a WARN log.
- `src/tools/Sync-PendingAlbums.ps1` -- refactored to a thin console-adapter wrapper over `Invoke-RipperPendingSync` (was ~340 lines, now ~140).
- `src/lib/Config.psm1` -- `RetryPendingSyncOnStartup = $true` default.
- `config/config.template.json` -- new field with comment.
- `setup/New-RipperConfig.ps1` -- prompt + display row for the new field.
- `tests/Invoke-PendingSync.Tests.ps1` -- NEW, 13 tests (5 plan + 8 orchestrator) green against fully-mocked sync chain.

**Pester:** 413/0/1 green.

**Cross-references:** D-022 (sync framework), D-024 (NAS target). Phase 6.4 (WireGuard) will benefit from this directly -- "ripped while at the in-laws, sync on the way home" becomes "rips queue locally, VPN connects, retry-on-launch pushes the backlog."

## D-026 -- WireGuard auto-toggle for the NAS sync (Phase 6.4)

**Date:** 2026-04-29
**Phase:** 6.4
**Status:** Implemented.

### Problem
Phase 6.3 added the SynologyNAS sync target but assumed the share was reachable. The intended deployment is "parent rips a stack of CDs at a friend's / in-laws' house, family NAS lives at home behind a router with no port forwarding." The right answer is a VPN; the right VPN for a single-user home-lab tunnel is WireGuard. The question is **how much of the WireGuard plumbing should MusicRipper own?**

User constraint stated explicitly: *"if there was a way to do a wireguard VPN on-demand without having to install anything, that would be best, but I don't think that exists, does it?"* It doesn't -- a WireGuard tunnel needs the kernel-mode WinTun adapter, which needs a signed driver install. So the next-best option is "MusicRipper installs and manages it once, then runs UAC-free forever after."

### Decision
1. **Install WireGuard for Windows via winget** (`WireGuard.WireGuard`, added to `setup/Install-Dependencies.ps1`).
2. **Per-tunnel install + per-user grant** is done **once** during `setup/New-RipperConfig.ps1`. The setup script asks for a `.conf` path, then spawns a single elevated `pwsh` child that runs:
   - `wireguard.exe /installtunnelservice <conf>` -- creates the Windows service `WireGuardTunnel$<TunnelName>` running as LocalSystem.
   - `sc.exe sdset WireGuardTunnel$<Name> "<sd>"` -- adds an ACE granting the current user SDDL `LCRPWPLO` (query-status, start, stop, interrogate) on this one specific service.
   That is the **one** UAC prompt across the entire setup.
3. **Runtime is UAC-free.** Every subsequent rip calls `Start-Service` / `Stop-Service` against the named service; the SD widening from step 2 means no elevation is needed. We wrap this in `src/lib/Wireguard.psm1`:
   - `Test-RipperVpnTunnel -Name -Detailed` -> `NotInstalled` / `Stopped` / `Running`.
   - `Start-RipperVpnTunnel -Name -TimeoutSeconds`. Idempotent. Polls `Get-Service` until Running.
   - `Stop-RipperVpnTunnel -Name -TimeoutSeconds`. Idempotent.
   - `Install-RipperVpnTunnel -ConfPath` and `Grant-RipperVpnTunnelControl -Name -UserSid`. Setup-only. Both require elevation.
4. **Toggle hook** lives in `Sync-ToSynologyNAS.ps1`: before pre-flight #2 (UNC reachability), if `cfg.WireGuardAutoToggle` and `cfg.WireGuardTunnelName` are set, bring the tunnel up. If `Start` fails, fail the sync with a WG-specific diagnostic instead of the (misleading) "share not reachable" message.
5. **Tear down at session exit only.** `$script:RipperSession.WgStartedByUs = $true` is set the first time we bring the tunnel up. The exit hook at the bottom of `Start-Ripper.ps1` reads it and calls `Stop-RipperVpnTunnel` before `Stop-RipperLog`. We do **not** bounce the tunnel between discs in a stack -- the user is sitting there ripping, the VPN is presumably staying useful for the duration.

### Why the SDDL grant (vs. running rips elevated)
- A parent-friendly tool that pops UAC every rip is not parent-friendly. The shortcut already runs unelevated; we want to keep it that way.
- The grant is service-scoped: it does not weaken any other ACL on the machine. We grant the minimum bits a "start/stop the tunnel" caller needs (`LC` query-status, `RP` start, `WP` stop, `LO` interrogate) -- no config changes (`CC`/`DC`/`WD` not granted), no delete.
- The grant is per-user: tied to the SID of whoever ran setup. A different Windows user on the same machine will not get start/stop on this tunnel without re-running setup -- which is the right default.
- This is the standard Microsoft-documented approach (Service Security and Access Rights / `sc.exe sdset`); see also the Sysinternals "How can a non-admin user start a service?" guidance.

### Why install WireGuard unconditionally in `Install-Dependencies.ps1`
- Winget's repeat install is idempotent (returns the "already installed" exit code we already special-case).
- The binary is ~5 MB and ships as a quiet user-level install; not worth the complexity of conditional installs gated on "did the user later opt into NAS-over-WG?"
- Per-tunnel install is still **on-demand** -- nothing happens to the machine without a `.conf` and explicit user opt-in via `setup/New-RipperConfig.ps1`.

### Failure semantics (D-022 contract preserved)
- Tunnel won't come up -> `Sync-ToSynologyNAS` returns `Status='Failed'` with a WG-specific `Diagnostic` and the rip pipeline keeps going. Phase 6.5's startup retry catches the album the next time the user launches MusicRipper after the network situation is fixed.
- Wireguard module fails to load entirely -> `Sync-ToSynologyNAS` logs WARN and continues without auto-toggle (the share might already be reachable on the LAN).
- Tunnel start succeeds but the share is still unreachable -> the existing pre-flight #2 catches it with the existing "is not reachable" diagnostic.

### Idle-timeout (deferred)
The original plan included `cfg.WireGuardIdleTimeoutMinutes` so the tunnel could come down between discs after N minutes of no NAS traffic. Implementing that cleanly needs either a timer per disc cycle or a proxy that watches robocopy for the last byte transferred -- both add complexity for a problem nobody has yet (the parent ripping a stack at the in-laws' is going to be at the keyboard for the duration). **Deferred to a future phase if the need materialises.** The current "tear down on session exit" covers the realistic worst case (user closes the app, drives home, tunnel stays up for the train ride otherwise).

### Per-disc tunnel-failure dialog (deferred)
Originally agreed to add a small WPF info dialog when the tunnel can't come up mid-stack ("guest network blocking UDP -- NAS sync will be skipped, OneDrive still works"). On reflection, the existing log + Phase 6.5 startup-retry covers the case: the rip succeeds, the album lands in `sync-state.json` as Failed, the parent sees it on next launch. Adding a per-disc modal in the rip flow would interrupt the stack-rip flow for information that's already presented at the next-launch retry. **Reconsider if user feedback says otherwise.**

### Files changed
- `src/lib/Wireguard.psm1` + `Wireguard.psd1` -- NEW. `Test/Start/Stop/Install/Uninstall/Grant` + `Get-RipperVpnTunnelServiceName` helper.
- `src/sync/Sync-ToSynologyNAS.ps1` -- self-imports `Wireguard.psd1` (so callers don't need to remember -- D-025 lesson); auto-toggle hook before UNC pre-flight; sets `$script:RipperSession.WgStartedByUs` so exit hook can tear down.
- `src/Start-Ripper.ps1` -- adds `WgStartedByUs` to `$script:RipperSession`; exit hook calls `Stop-RipperVpnTunnel` if we started the tunnel.
- `src/lib/Config.psm1` -- `WireGuardTunnelName = $null`, `WireGuardAutoToggle = $true` defaults.
- `config/config.template.json` -- new fields with comments.
- `setup/New-RipperConfig.ps1` -- prompt for `.conf` path, spawn elevated child that runs Install + Grant in a single UAC prompt; persist `WireGuardTunnelName`/`WireGuardAutoToggle`.
- `setup/Install-Dependencies.ps1` -- adds `WireGuard.WireGuard` winget id.
- `tests/Wireguard.Tests.ps1` -- NEW, 21 tests (translation + Test/Start/Stop/Install + Sync-ToSynologyNAS hook), all mocked at `Get-Service`/`Start-Service`/`Stop-Service`/`Start-Process`.

**Pester:** 434/0/1 green (was 413/0/1; +21 new WG tests).

**Cross-references:** D-022 (sync framework), D-024 (NAS target), D-025 (startup pending-sync retry -- the safety net for tunnel-down rips).

### Amendment (Phase 6.4.1) -- refcounted lifecycle, tunnel up only during transfer

**Date:** 2026-04-29
**Phase:** 6.4.1
**Status:** Implemented.

**What changed.** The original D-026 design brought the tunnel up on the first sync attempt and held it open until session exit. After the 6.4 manual-verification round, the user pushed back on this: *"the tunnel should only be open during the NAS target copy. as soon as the copy is completed, the tunnel service should stop."* The right primitive is a **refcounted acquire/release** wrapper, not a one-shot start-and-leave-it-up flag.

**New module surface (`src/lib/Wireguard.psm1`).**
- `Add-RipperVpnTunnelRef -Name` -- on the 0->1 transition, calls `Test-RipperVpnTunnel` and either records `OwnedByUs=$false` (if already Running -- some other consumer is holding it) or `Start-RipperVpnTunnel` + `OwnedByUs=$true`. Returns `$false` if the service isn't installed or the start failed.
- `Remove-RipperVpnTunnelRef -Name` -- decrements; on the 1->0 transition stops the tunnel **iff `OwnedByUs`**. Defensive: a stray Remove without a paired Add is a WARN no-op, never tears down a tunnel some other consumer is still using.
- `Use-RipperVpnTunnel -Name -ScriptBlock` -- the convenience wrapper: Add, run, Remove in a finally. Throws if Add failed.
- `Enable-RipperVpnTunnelSessionKeepAlive -Name` / `Disable-RipperVpnTunnelSessionKeepAlive [-Name]` -- a session-scoped extra ref. When enabled, the tunnel survives across syncs in the session; when disabled (or at exit), the extra ref is released and the tunnel comes down with the last per-sync release. Coordinated across runspaces via `$env:MUSICRIPPER_WG_SESSION_REF` so the worker runspaces (rip-progress, pending-sync) and the main runspace all agree on whether keep-alive is in effect.

**Why refcounting (vs the old `RipperSession.WgStartedByUs` flag).** The flag was set in `$script:RipperSession`, which is per-runspace. The pending-sync worker runspace could not see the flag the main runspace set (and vice versa), so the exit hook missed teardowns when a sync started in a worker. Refcounting moves the lifecycle into the module's own state and makes each acquire/release pair self-contained -- no cross-runspace state needed for the per-sync case at all. The keep-alive case still needs cross-runspace coordination, but a single env var is enough (it answers exactly one yes/no question: "is anyone holding a session-scoped ref?").

**OwnedByUs invariant.** We never call `Stop-Service` on a tunnel we did not start. If the user has the tunnel up via the WireGuard tray app for unrelated reasons, our Add records `OwnedByUs=$false` and our Remove is a no-op. This makes MusicRipper a polite citizen on a machine where WireGuard might be doing other work.

**`Sync-ToSynologyNAS.ps1` rewrite.** The auto-toggle block is gone. The whole SMB-mount + robocopy + unmount section is now wrapped in `try { Add-RipperVpnTunnelRef ... } finally { Remove-RipperVpnTunnelRef ... }`. Credential decryption happens **before** the acquire because it doesn't need the tunnel. If `cfg.WireGuardKeepAliveBetweenDiscs` is `$true`, an extra `Enable-RipperVpnTunnelSessionKeepAlive` call before the per-sync Add bumps the refcount so the per-sync Remove never drops it to 0 -- the tunnel stays up across the whole stack and only comes down at exit.

**`Start-Ripper.ps1` exit hooks.** The `PowerShell.Exiting` engine event and the bottom-of-script teardown now both call `Disable-RipperVpnTunnelSessionKeepAlive` first (drops the keep-alive ref if any) and then defensively `Test-RipperVpnTunnel` + `Stop-RipperVpnTunnel` if the service is somehow still Running. The defensive stop logs a WARN when it actually had to do something, because reaching that path means a per-sync `finally` was bypassed by a hard crash and we want to know about it.

**New cfg knob.** `WireGuardKeepAliveBetweenDiscs` (default `$false`):
- `$false` (default, minimal exposure): the tunnel comes up at the start of each sync and is torn down at the end. Saves nothing but adds the WG handshake (~2-3s) per disc when ripping a stack. Right default for "parent rips one disc, walks away."
- `$true` (rip-a-stack mode): first sync's start pins the tunnel for the rest of the session; per-sync acquires/releases are no-ops; tunnel comes down at exit. Saves the per-disc handshake when ripping a multi-disc stack.

**Files changed.**
- `src/lib/Wireguard.psm1` -- appended ~190 lines: `$script:WgRefs`, `Get-RipperVpnTunnelRefState`, `Add/Remove-RipperVpnTunnelRef`, `Use-RipperVpnTunnel`, `Enable/Disable-RipperVpnTunnelSessionKeepAlive`.
- `src/lib/Wireguard.psd1` -- 6 new exports.
- `src/lib/Config.psm1` -- `WireGuardKeepAliveBetweenDiscs = $false` default.
- `config/config.template.json` -- new doc + field; `WireGuardAutoToggle` doc updated to "around each NAS sync."
- `src/sync/Sync-ToSynologyNAS.ps1` -- replaced `Start-RipperVpnTunnel`-then-set-flag block with `Add-RipperVpnTunnelRef` + outer `try/finally(Remove)`; optional `Enable-RipperVpnTunnelSessionKeepAlive` when `KeepAliveBetweenDiscs`. Removed `RipperSession.WgStartedByUs` writes.
- `src/Start-Ripper.ps1` -- removed `WgStartedByUs` from `$script:RipperSession`; exit hooks call `Disable-RipperVpnTunnelSessionKeepAlive` + defensive `Stop-RipperVpnTunnel`; env var renamed to `MUSICRIPPER_WG_SESSION_REF`.
- `tests/Wireguard.Tests.ps1` -- +6 tests for refcount + keep-alive (mocked at the `Test/Start/Stop-RipperVpnTunnel` wrapper layer, not `Get-Service`, since those primitives are unit-tested elsewhere in the same file).

**Pester:** 440/0/1 green (was 434/0/1; +6 new tests).
## D-027 -- Phase 7 polish + packaging (Phase 7)

**Status:** Accepted.

**Context.** Phase 7 closes out the parent-handoff backlog from plan.md: a one-shot installer (Install-MusicRipper.ps1), a top-level error handler that doesn't dump PowerShell stack traces in front of a parent, a tool to promote re-tagged albums out of _ReviewQueue/, and a polish pass on the between-discs loop. None of this changes the rip pipeline; it changes what the parent sees when something is the user-visible surface.

**Decisions.**

1. Top-level error handler is a script-scope 	rap in Start-Ripper.ps1, NOT a giant try/catch around the script body. The body is ~1000 lines spanning helpers, the resync block, the disc loop, and exit-time WG cleanup; a trap is a single-statement script-scope handler that fires on any uncaught script-terminating error, which is exactly the layer we want. The handler shows Show-RipperFatalErrorDialog (Copy-log-path button + Open-log-folder), logs full detail (exception type + message + ScriptStackTrace + CLR StackTrace), and exits 1 so callers can detect.

2. Move-FromReviewQueue.ps1 reads tags from track-1 of the source folder via metaflac --show-tag (same Get-MetaflacPath helper Write-Tags + Update-AlbumTags use), reuses Get-RipperLibraryTargetDir from Move-ToLibrary so the target layout is bit-identical, and best-effort seeds discids.json (Phase 5.8 cross-session duplicate-disc detection). Pure-logic helpers are exported for Pester (Resolve-RipperReviewSourceMetadata, Get-RipperReviewPromotionPlan, Read-RipperReviewTxtDiscId). 19 tests, mocked metaflac at the Read-RipperFlacTagValue layer + tempdir-based end-to-end walk.

3. Install-MusicRipper.ps1 has two modes: default (copy repo into %LOCALAPPDATA%\MusicRipper via robocopy then chain setup\Install-Dependencies + setup\Install-Shortcut) and -InPlace (skip the copy for engineers who cloned). robocopy was the right tool: handles long paths, idempotent, easy /XD /XF excludes (.git, .vs, .vscode, pester scratch, testResults.xml). Hands off to the Phase 6.6 WPF first-run flow on first shortcut launch -- no headless config wizard from the installer; that's now redundant with the WPF editor.

4. The 'rip another disc' loop polish was copy-only (Show-BetweenDiscsDialog): friendlier title (singular/plural CD count), friendlier headline ('Ready for the next CD!'), watch text rephrased as instruction not narration ('Pop the next CD into D: -- the rip will start automatically.'), Quit relabelled 'I'm done -- Quit'. Added a one-line tip about stack ripping. No behavioural changes -- the auto-detect DispatcherTimer + button wiring are unchanged from Phase 5.7.

**Files.**
- Install-MusicRipper.ps1 (new, repo root, 265 lines).
- src/tools/Move-FromReviewQueue.ps1 (new, 482 lines).
- 	ests/Move-FromReviewQueue.Tests.ps1 (new, 19 tests).
- src/ui/Show-FatalErrorDialog.ps1 (new, 220 lines, WPF + Copy-log-path + Open-log-folder).
- src/Start-Ripper.ps1 -- script-scope 	rap calling the dialog, dot-source the new dialog.
- src/ui/Show-BetweenDiscsDialog.ps1 -- copy polish only.
- docs/PARENTS-QUICKSTART.md -- full rewrite, 5-step parent walkthrough with [screenshot: ...] placeholders.
- docs/REVIEW-WORKFLOW.md -- documents Move-FromReviewQueue.ps1 above the manual hand-move recipe.

**Rejected alternatives.**
- *Big try/catch around Start-Ripper body*: 1000-line indent rewrite for no functional difference vs `trap`.
- *Silent error handler that just exits*: violates the plan's 'friendly dialog with Copy log path button' promise; parents need to be told something happened.
- *Drop -InPlace*: makes engineer dev loops painful (would have to run the copy on every test).
- *Do the screenshot capture in code*: requires a fresh PC; the [screenshot: ...] markers + suggested filenames let the engineer fill these in incrementally without blocking the rest of Phase 7 from merging.

---

## D-028 -- Visual identity assets: app logo and README hero (Phase 7 polish)

**Status:** Accepted.

**Context.** After Phase 7 packaging/polish, the project needed a real visual identity: an app icon for shortcuts/WPF chrome and a README hero suitable for the eventual GitHub repository. The concepts live in `assets/logo-concepts/` so they can be referenced later without mixing generated design work into docs prose.

**Canonical app mark.** `assets/logo-concepts/prompt-d-audiophile-disc-badge/prompt-d-variant-01.svg` is the source of truth for the MusicRipper mark. It is a flat-vector audiophile disc: charcoal puck, subtle radial highlight, three dark groove rings, cream center label with tan rings, crimson center dot, full cyan/violet/amber edge treatment, and a soft shadow. Later concepts embed this mark's primitives directly and only transform/place them; they do not redraw the disc.

**Current README hero favorite.** `assets/logo-concepts/readme-hero-logo-concepts/readme-hero-concept-14.svg` is the preferred README hero candidate. It combines concept 12's centered spacing and horizontal tan rules with concept 11's wording: `Secure CD ripping for a bit-perfect FLAC library`. Among the final 13-16 iteration set, concept 14 gives the logo the strongest presence while keeping the text clear of the disc.

**Iteration trail.**

- Prompts A-C explored generic icon directions and were superseded.
- Prompt D established the final disc mark; variant 01 became canonical.
- Prompts E-J2 explored wordmarks, horizontal lockups, stacked README heroes, disc-as-tittle treatments, and narrative banners. Useful reference, not selected.
- README hero concepts 01-16 explored GitHub-ready mastheads using the canonical disc mark.
- Concepts 08, 11, and 12 were the convergence point: centered masthead, tan horizontal rules, restrained geometric sans wordmark.
- Concepts 13-16 combined concept 12's spacing/rules with concept 11's tagline; concept 14 is the current favorite.

**Exported app assets.** The shipped app icon assets live under `assets/` (`musicripper.svg`, `musicripper.png`, `musicripper.ico`, per-size `musicripper-{N}.png`, and `musicripper-hero.*`). `setup/Build-Icon.ps1` generates the per-size PNGs and `.ico` from the source mark.

**Future rule.** New design explorations should land under `assets/logo-concepts/`. Promote only selected production assets to top-level `assets/`.


## D-027 follow-on -- Phase 7 manual-verification fixes (Phase 7)

**Status:** Accepted (most of the 33 commits on phase-7-polish are
these follow-ons; this entry is the consolidated rationale).

**Context.** End-to-end manual verification of the Phase 7 install +
uninstall flow surfaced a long string of small bugs and parent-UX
gaps that didn't make the original D-027 plan. Captured here so the
follow-on rationale isn't buried in commit messages.

**Cross-runspace logging.** Show-RipProgress and Show-PendingSyncProgress
run their work in [runspacefactory] worker runspaces; PowerShell
module state (incl. Logging's $script:LogPath) is per-runspace.
Worse, every Import-Module Logging.psd1 -Force re-runs the .psm1
and resets $script:LogPath = $null. Symptom: a real review-queue
rip produced an album folder with no ripper-session.log AND a per-
disc log that contained zero entries between 'Starting rip:' and
'Rip finished:'. Fix: new Set-RipperLogPath adopt helper +
parent passes Get-RipperLogPath through SessionStateProxy.SetVariable
+ worker re-adopts after dot-source chain. Same fix in pending-sync
worker. Memory note added: "Module $script: state is per-runspace
AND Import-Module -Force resets it."

**Move-FromReviewQueue sync wiring.** Promoting an album from
_ReviewQueue/ updated discids.json but never called the sync chain,
so promoted albums skipped OneDrive/NAS. Fix: after the move +
index seed, mirror what Invoke-RipperPostProcess does for normal
Library-routed rips (Invoke-RipperSync against cfg.SyncTargets, then
Invoke-RipperLibraryRetention). New -SkipSync switch for power
users who want discids.json-only behaviour.

**Uninstaller (Uninstall-MusicRipper.ps1).** Added per user request,
modelled on Wireguard.psm1's Invoke-RipperVpnTunnelElevatedInstall
(the working temp-helper elevation pattern in this codebase). Long
list of bugs found and fixed during verification:
  - Self-elevation via #Requires -RunAsAdministrator just bails;
    don't use it. Self-elevation via Start-Process -Verb RunAs of
    the same script with -NoExit doesn't work because explicit
    `exit N` mid-script terminates pwsh regardless of -NoExit.
  - Read-Host inside the elevated child returns EOF immediately
    (stdin not wired across UAC). Move confirmation to parent shell
    where Read-Host works; auto-pass -Force to the child.
  - Final shape: parent shell prompts, writes a temp .ps1 helper
    that calls back into THIS script with -ImAlreadyAdmin, launches
    via Start-Process -Verb RunAs -Wait. Helper's finally block does
    the Read-Host pause. Helper kept on failure for diagnosis.
  - Picard's Inno-Setup-style /VERYSILENT was the WRONG silent flag;
    Picard ships an NSIS installer (silent flag is /S). Fix: try
    QuietUninstallString first, then NSIS /S, then Inno
    /VERYSILENT /SUPPRESSMSGBOXES /NORESTART, then MSI /quiet
    /norestart. Verify success by polling InstallLocation
    disappearance, NOT by trusting the exit code (NSIS / Inno / MSI
    all self-elevate via UAC and return immediately with rc=1 while
    the real uninstall completes asynchronously in a forked child).
  - UninstallString parser was naive (took everything up to the
    first space). Picard's value 'C:\Program Files\MusicBrainz
    Picard\uninst.exe' parsed to 'C:\Program', $installDir became
    'C:\' (always exists), 'still present' check trivially passed.
    Fix: walk left-to-right looking for the first .exe substring
    whose path actually exists on disk. Plus use the registry's
    InstallLocation when present (much more reliable).
  - $scopesToTry = if (Picard) { @('user','machine',$null) } else
    { @($null) } collapsed to empty array under StrictMode 3.0
    (the powershell.md gotcha that bit Phase 6.1 too). Three
    packages got bogusly counted as failures every run. Fix:
    $scopesToTry = @(if ... { 'user','machine',$null } else
    { $null }).
  - Install-Dependencies.ps1 was leaking a non-zero $LASTEXITCODE
    from the last winget call (-1978335189 = ALREADY_INSTALLED) up
    to Install-MusicRipper.ps1's chain runner, which aborted the
    install. Fix: explicit $global:LASTEXITCODE = 0 at the end of
    the dependencies script + Invoke-SetupStep treats -1978335189
    as success too.

**Three shortcut surfaces.** Per parent-UX request: Desktop
'Rip a CD.lnk', repo-root 'Uninstall MusicRipper.lnk' (gitignored,
regenerated per-install since .lnks bake absolute paths), and Start
Menu 'MusicRipper - Rip a CD.lnk' / 'MusicRipper - Uninstall.lnk'
flat under Programs\ (Win11 doesn't render Start Menu subfolders).
Uninstaller cleans up all three.

**Hero banner.** assets/musicripper-hero.png referenced from README
H1. Logo session contributed 3 commits (icon assets + WPF icon
wiring); concept-exploration archive lives in assets/logo-concepts/.

**Quickstart screenshots.** 12 PNGs in docs/images/ wired into
PARENTS-QUICKSTART.md. Captured during a real fresh-install walk-
through.

**Pester:** 522/0/1 unchanged through all the follow-on fixes
(everything live-tested on real hardware; no test regressions).

---

## D-029 -- iTunes Search API throttle + attribution surfacing (Release prep)

**Choice:** Enforce a per-process minimum of 1500 ms between any two
iTunes Search API calls (~40 req/min). Apply in both call sites:
`src/core/metadata/Get-MetadataFromItunesSearch.ps1` (text-search modal)
and `src/core/coverart/Get-CoverArtFromItunesSearch.ps1` (per-rip cover-
art fallback). The CDN downloads (artworkUrl{N}x{N}.jpg) are NOT iTunes
API calls and remain unthrottled. Skip the throttle when a test seam
is supplied so the suite doesn't drag.

**Why 1500 ms (not the spec-strict 3000 ms = 20 req/min):** Apple's
published documentation cites a soft limit of 'around 20 calls per
minute,' but the documented behavior of their rate limiter is
4xx-blocking on sustained bursts, not per-call. 1500 ms keeps a typical
text-search round-trip (1 search + 5 lookups) at ~9 seconds end-to-end
rather than ~18, which materially improves the UX of the 'Search by
text...' modal a parent might reach when a disc is unidentifiable.
A single rip's cover-art fallback issues exactly one /search call per
album, so the throttle is invisible during normal use.

**Attribution.** Apple's Search API ToS requires attribution when album
metadata is surfaced to end users. We satisfy this in two places:
  1. `NOTICE.md` carries the verbatim attribution string under the
     iTunes Search API entry.
  2. `docs/THIRD-PARTY.md` mirrors it in the structured table.
MusicRipper is a CLI / WPF tool (no website, no UI banners); the docs-
level acknowledgement is appropriate for the form factor and matches
the pattern other CLI tools using the API follow.

**Alternatives considered:**
  - 3000 ms strict (==20 req/min): spec-conformant but doubles every
    text-search wall-clock time. Rejected.
  - 750 ms (~80 req/min): faster, but real risk of triggering Apple's
    burst limiter on a chatty session. Rejected.
  - Per-endpoint throttle (e.g. 3000 ms for /search, 1500 ms for
    /lookup): more code, marginal benefit, kicks the question of
    per-endpoint policy down the road. Rejected.

**Implementation note.** Each provider file owns its own per-process`r
`script:LastItunes*RequestTicks` counter rather than sharing a global
(test-seam isolation, simpler reasoning). The two providers don't fire
concurrently in practice -- the cover-art chain runs synchronously
during post-process; the text-search modal blocks the WPF UI thread.

---

## D-030 -- Deezer API ToS investigation (Release prep)

**Status:** Investigation complete; no code changes this round.
**Verdict:** Compliant for MusicRipper's documented use case
(personal/family CD ripping, MIT-licensed, no monetization).

**ToU snapshot reviewed:** developers.deezer.com/termsofuse, Dec 2024
capture via web.archive.org (Deezer's live site renders client-side
and resists static fetch).

**Endpoints exercised** (all unauthenticated public reads, no API key):
  - `GET https://api.deezer.com/search/album?q=...` -- both the
    metadata text-search fallback (`Get-MetadataFromDeezer.ps1`) and
    the cover-art fallback (`Get-CoverArtFromDeezer.ps1`).
  - `GET https://api.deezer.com/album/{id}` -- per-hit detail fetch
    during text search.
  - `GET <cover_xl URL>` -- direct CDN download (not an API call).

**Volume per rip:**
  - Cover-art: 0-1 `/search/album` calls + 0-1 image download (only
    fires if CAA + iTunes both come back empty).
  - Metadata text-search: only fires on the no-match modal's
    explicit "Search" click; 1 + N detail calls (N=DetailLimit, default 5).

**Critical clauses:**

  1. **Section IV -- Non-commercial / family scope** is the load-
     bearing one. *"The use of the Content is limited to a strictly
     private use within a family scope."* That maps cleanly to
     MusicRipper's stated mission ("family music-digitization
     project" per README). MIT-licensed open source with no
     monetization satisfies the non-commercial environment language.

  2. **Section VII -- IP** declares cover-art images as Deezer's
     property. The Section IV carve-out is the legal basis for
     embedding them in the user's local FLAC files. **A user
     repurposing MusicRipper for paid work (DJ catalog / music-
     licensing prep / commercial archive) would NOT be covered.**
     Surfaced this caveat in NOTICE.md + THIRD-PARTY.md.

  3. **Auth.** Deezer's ToU formally requires Developer-account
     acceptance, but the listed endpoints are served openly. We
     don't bypass any auth check, so we're operating within the
     access controls Deezer themselves chose to publish.

  4. **No explicit attribution clause** (vs. Apple's Search API
     ToS which requires the verbatim "Album metadata provided in
     part by..." line). NOTICE.md still acknowledges Deezer because
     it's polite + matches the pattern for every other dep.

  5. **No documented rate limit in the ToU.** The "50 req/sec/IP"
     figure baked into the existing code comment is community lore;
     not a ToU obligation.

**Followups parked (not in this round):**
  - Set an identifying `User-Agent` on Deezer requests (parallel to
    MB / CTDB / GnuDB). Pure good-citizenship; no compliance gain.
  - Surface the non-commercial caveat in user-facing docs (README /
    SETUP / TROUBLESHOOTING) so a future user with a commercial use
    case understands they should disable the Deezer provider.
  - Honor 50 req/sec/IP with an explicit throttle if a future
    feature (e.g. batch re-tag) changes call patterns.

**Why no code changes this round:** the spec is explicit ("Do not
change code, config, or NOTICE wording for Deezer in this round,
regardless of the finding"). The caveat surfacing is a doc change
only, which the spec does want.

