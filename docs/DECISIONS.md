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
