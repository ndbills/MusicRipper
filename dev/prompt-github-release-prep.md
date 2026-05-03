# Task: Prepare MusicRipper for public GitHub release as `MusicRipper`

You are working in the MusicRipper repository at `c:\bin\MusicRipper`. The repo is functionally complete and needs licensing, third-party acknowledgements, sensitive-content cleanup, and basic GitHub scaffolding before being pushed as a **public** repo. Work through the phases below in order. Stop and report at the end of each phase; wait for my approval before starting the next phase.

## Operating rules

1. **One phase at a time, in order.** Stop after each phase, report what you did, and wait for my "go" before the next.
2. **Read before you write.** Inspect existing files (especially `README.md`, `config.template.json`, `setup/Register-Drive.ps1`, `Install-MusicRipper.ps1`, all of `src/`) before editing. Do not assume — verify.
3. **Conventional Commits**, one logical change per commit (`docs:`, `chore:`, `feat:`, `fix:`, `refactor:`). Each commit must leave the repo working.
4. **Ask before destructive actions.** Specifically: do not rewrite git history, do not force-push, do not delete files outside the explicit list in Phase C without confirming, do not run `gh repo create` or `git push` (those are Phase E and require explicit approval).
5. **Surface findings, don't hide them.** If an audit turns up something unexpected (extra secrets, undocumented dependency, wording that implies endorsement), stop and ask.
6. **No scope creep.** Implement only what each phase specifies. No refactoring "while we're in there."

## Inputs you will need from me

Ask me for these at the start of Phase A; don't guess:

- **Copyright holder name** for the LICENSE file (e.g., "Nathan LastName" or just "Nathan")
- **MusicBrainz contact-string preference** for the wizard's prompt help text (no actual email goes in the repo — just confirm the wording)
- **Any additional repo topics** I want beyond the defaults

---

# PHASE A — License & legal foundation

A1. **Create `LICENSE`** at repo root with the verbatim **MIT License** text. Copyright line: `Copyright (c) 2026 <name I provide>`.

A2. **Create `NOTICE.md`** at repo root with formal acknowledgements for every third-party dependency. Use this exact list (verify each against the actual code first; flag discrepancies):
   - **CUETools / CUERipper** — Grigory Chudov; freely redistributable; we invoke via CLI, do not bundle. https://cue.tools/
   - **FLAC tools (`flac.exe`, `metaflac.exe`)** — Xiph.Org Foundation; GPLv2 binaries / BSD-style libFLAC; invoked via CLI. https://xiph.org/flac/
   - **MusicBrainz Picard** — MetaBrainz Foundation; GPLv2; invoked via CLI. https://picard.musicbrainz.org/
   - **WireGuard** — Jason A. Donenfeld; GPLv2. *Trademark notice:* WireGuard is a registered trademark of Jason A. Donenfeld; this project is not affiliated with or endorsed by the WireGuard project. https://www.wireguard.com/
   - **MusicBrainz Web Service** — MetaBrainz Foundation; data CC0 (core) / CC-BY-NC-SA (some derived). User supplies a contact string in their local config; rate-limited to ≤1 req/sec; User-Agent identifies MusicRipper. https://musicbrainz.org/doc/MusicBrainz_API
   - **Cover Art Archive** — Internet Archive / MetaBrainz; per-image rights vary; downloads go to user's local library only. https://coverartarchive.org/
   - **AccurateRip drive offset list** — © Illustrate (Spoon); proprietary. We fetch live from `accuraterip.com/driveoffsets.htm` at install time; we do not redistribute the data.
   - **iTunes Search API** — © Apple Inc.; per Apple's API ToS — attribution: *"Album metadata provided in part by the iTunes Search API, © Apple Inc."* https://performance-partners.apple.com/search-api
   - **Deezer API** — © Deezer; usage subject to Deezer's API ToS. *(See Phase B3 for compliance investigation status.)*

A3. **Create `docs/THIRD-PARTY.md`** — companion to NOTICE.md with a structured table for contributors/auditors. Columns: Name | Version pinned (if any) | License | How we use it | Bundled? | Link. One row per dependency from A2.

A4. **Update `README.md`:**
   - Add a **License** section at the bottom linking to `LICENSE` and naming MIT.
   - Add an **Acknowledgements** section linking to `NOTICE.md`.
   - Add a top-of-file disclaimer: *"MusicRipper is not affiliated with or endorsed by Plex, MusicBrainz, the CUETools project, the WireGuard project, Apple, Deezer, or Illustrate (AccurateRip / dBpoweramp). Trademarks belong to their respective owners."*
   - Audit existing README text for "official," "endorsed," "powered by," "in partnership with" wording; soften to neutral phrasing ("uses," "built on," "calls").

**Stop and report.** Show me a diff summary and the new files for review.

---

# PHASE B — API compliance and config hardening

B1. **MusicBrainz User-Agent — refactor to runtime construction from config.**
   - Find where the User-Agent string is currently built and where any contact info is sourced. Report what you find before making changes.
   - Refactor: User-Agent is constructed at runtime as `MusicRipper/<version> ( <contactEmail-or-contactUrl-from-config> )`.
   - Add `contactEmail` and `contactUrl` fields to `config.template.json` (both empty strings, with annotated comments — at least one is required for MusicBrainz calls).
   - **No email address (yours, mine, or any default) appears anywhere in committed source** — including templates, fixtures, comments, tests. Grep the repo to verify. If you find any, flag them.
   - Update `setup/New-RipperConfig.ps1` (the wizard) to prompt for the contact string with this explanatory help text: *"MusicBrainz requires a contact address per their API terms (https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting). It is sent only with requests to musicbrainz.org and stays on your machine in `config.json`. An email address or a URL (e.g., your GitHub profile) both work."*
   - If `contactEmail` and `contactUrl` are both empty when the tool tries to call MusicBrainz, fail with a clear error pointing the user back at the wizard. **Do not** fall back to anonymous requests.
   - Confirm `config.json` is gitignored (per existing `.gitignore`).

B2. **iTunes Search API audit.** Locate the iTunes Search call sites; confirm: (a) rate limit ≤20 req/min is enforced; (b) the Apple attribution string from A2 is surfaced to the user *somewhere* (NOTICE.md probably suffices for a CLI tool but verify against Apple's ToS and document the rationale in `docs/DECISIONS.md`).

B3. **Deezer — ToS investigation only, no code changes.**
   - Locate every Deezer call site. Report: which endpoint(s), auth or unauthenticated, applied rate limit, average requests per rip.
   - Read https://developers.deezer.com/api and Deezer's API ToS. Specifically determine: (a) is there an unauthenticated public read tier? (b) does the cover-art endpoint specifically require auth? (c) are there clauses against caching cover images locally for the user's own library? (d) attribution requirements?
   - **Write the finding** in `docs/THIRD-PARTY.md` (under the Deezer entry) and a summary in `docs/DECISIONS.md`: endpoints used, request volume, applicable ToS clauses, conclusion (compliant / non-compliant / ambiguous), recommended next action if any.
   - **Do not** change code, config, or NOTICE wording for Deezer in this round, regardless of the finding. We'll plan a follow-up if needed.

**Stop and report.** Surface each audit finding before moving on.

---

# PHASE C — Repository cleanup

C1. **Move dev artifacts to `dev/`.** Create `dev/` and `git mv`:
   - `prompt.md` → `dev/prompt.md`
   - `plan.md` → `dev/plan.md`
   - `probe.ps1` → `dev/probe.ps1`
   - `results.txt` → `dev/results.txt`

   **Delete** (don't move): `Uninstall MusicRipper.lnk` — it's a generated artifact.

   Create `dev/README.md` with one paragraph: *"This folder contains development-time artifacts (planning docs, ad-hoc probes, captured outputs) preserved as project history. Not required to use or build MusicRipper."*

C2. **Remove the AccurateRip cache from the repo.**
   - `git rm data/driveoffsets.cached.json`
   - Add `data/driveoffsets.cached.json` to `.gitignore`
   - Modify `Install-MusicRipper.ps1` to perform a **one-time live fetch** of the offset list at install time so first-run UX is unchanged for users with internet. The runtime "live fetch + cached fallback" path stays as-is.
   - Update `docs/SETUP.md` to mention internet is required at install time.
   - The NOTICE entry from A2 already covers the redistribution stance — no NOTICE change here.

C3. **Update `.gitignore`:**
   - Add: `*.lnk`, `data/driveoffsets.cached.json`
   - Verify existing entries still cover: `config.json`, `credentials.clixml`, `*.clixml`, `testResults.xml`, `pester-result.txt`, `*.log`, `logs/`, `tmp/`, `temp/`, `out/`, `dist/`, audio extensions
   - Report any gaps.

C4. **Sensitive-content audit (full repo, current working tree).** Grep for and report findings on:
   - Email addresses (any `@` in non-binary files)
   - IPv4 addresses (`\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}`), excluding obviously-public examples like `0.0.0.0` / `127.0.0.1`
   - Hostnames suggesting personal infra (anything ending `.local`, `.lan`, `.synology.me`, dynamic-DNS hostnames)
   - UNC paths (`\\\\[^\\]+\\`)
   - WireGuard config snippets (`PrivateKey =`, `PublicKey =`, `PresharedKey =`, `Endpoint =`)
   - Token-shaped strings: `Bearer `, `apikey`, `api_key`, `secret`, `password`, `token`, hex strings ≥32 chars, base64 strings ≥40 chars
   - Hardcoded user paths under `C:\Users\<name>\` other than env-relative paths

   For each hit: file, line, context. Decide redact / parameterize / leave-with-justification. **Stop and ask me about anything ambiguous before making changes.**

C5. **Git history audit.** Run the same patterns from C4 against the full git history (`git log --all --full-history -p` piped through your patterns). Report findings only — **do not rewrite history without explicit approval from me.** If anything is found, propose a remediation plan (e.g., `git filter-repo` invocation) and wait.

**Stop and report** with a clear "clean to push" or "needs decisions" verdict.

---

# PHASE D — Standard GitHub repo files

D1. **`.github/workflows/pester.yml`** — minimal CI:
   - Triggers: `push` to `main`, `pull_request`
   - Runs on: `windows-latest`
   - Steps: checkout → install Pester 5.x (`Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck`) → `Invoke-Pester ./tests -CI -Output Detailed -PassThru` with NUnit XML output → upload test results as a workflow artifact
   - Job name: `pester-tests`
   - Add the corresponding status badge near the top of `README.md`

D2. **`.github/ISSUE_TEMPLATE/`** — two templates:
   - `bug_report.md` — fields: PowerShell version (`$PSVersionTable`), Windows version, optical drive model, relevant log excerpt from `%LOCALAPPDATA%\MusicRipper\logs\`, repro steps, expected vs actual
   - `feature_request.md` — problem, proposed solution, alternatives considered

D3. **`SECURITY.md`** — short policy:
   - How to report vulnerabilities (use GitHub's private Security Advisories; don't open public issues for security)
   - "Supported version: latest `main`"
   - Note about the DPAPI-encrypted credential store: what's stored locally, what never leaves the machine, what gets sent to MusicBrainz/iTunes/Cover Art Archive

D4. **`CONTRIBUTING.md`** — short:
   - Dev setup: PowerShell 7+, Pester 5+, run `Invoke-Pester ./tests` before submitting
   - Coding conventions: comment-based help on public functions, conventional commits, point at `docs/DECISIONS.md` for the why-behind-the-what
   - "This is a personal project — PRs welcome but no SLA on review"

D5. **README polish:**
   - Add badges row near the top: License (MIT), CI status (Pester workflow from D1), PowerShell version (7+)
   - Verify the "Current status" table reflects the actual completion state (ask me to confirm if unsure)
   - Quickstart block: `git clone` → `./Install-MusicRipper.ps1` → "Rip a CD" desktop shortcut
   - Confirm the file renders cleanly in VS Code's markdown preview

**Stop and report.** Show me the new files and the updated README.

---

# PHASE E — Push to GitHub (requires my explicit approval per step)

E1. **Pre-push checklist (you run, I review):**
   - `git status` clean
   - `Invoke-Pester ./tests` all passing
   - `git log --oneline -30` reviewed for commit messages with personal info
   - LICENSE / NOTICE.md / README.md render correctly in VS Code preview
   - All Phase C audit findings resolved or explicitly accepted

   Report results. **Wait for my approval to proceed to E2.**

E2. **Create the GitHub repo and push.** After my approval, run:
   ```powershell
   gh repo create MusicRipper --public --source . --remote origin --description "Family-friendly Audio CD to FLAC ripping tool with AccurateRip verification, MusicBrainz tagging, and Plex-ready library layout. Windows + PowerShell 7."
   git push -u origin main
   ```
   If `gh` is not authenticated, stop and tell me to run `gh auth login`.

E3. **Post-push verification:**
   - Open the repo URL in a browser (`gh repo view --web`); confirm README renders, LICENSE is detected by the GitHub license badge, NOTICE.md renders.
   - Set repo topics: `cd-ripping`, `flac`, `accuraterip`, `musicbrainz`, `plex`, `powershell`, `windows` (plus any extras I provide in Phase A)
   - Enable Dependabot alerts (Settings → Code security; or `gh api` if available)
   - Confirm the Pester workflow ran on the initial push and went green; if it failed, stop and report.

**Stop and report.** Hand back the repo URL and a one-paragraph summary of everything done across all phases.

---

## Out of scope

- CHANGELOG.md or release notes
- Tagging a v1.0.0 release
- GitHub Pages
- Translations
- Manual Dependabot version configuration (the default alerts are fine; we have no package manifests anyway)
- Any code refactoring beyond what's explicitly required by Phase B

## Begin

Acknowledge you've read this prompt, list the inputs you need from me to start Phase A, then wait for my answers before doing anything.