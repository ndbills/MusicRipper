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

