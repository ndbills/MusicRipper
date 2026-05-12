# Contributing to MusicRipper

Thanks for your interest. This is a personal project (a parent-friendly
CD ripper for one specific family use case), so a few up-front notes:

- **No SLA on review.** PRs are welcome but I reply when I have time.
  Don't be offended if a small change sits for a few weeks.
- **Scope is intentionally narrow.** MusicRipper rips Audio CDs to a
  bit-perfect FLAC library on Windows + PowerShell 7. Anything outside
  that loop -- a Linux port, a web UI, FLAC-to-mp3 transcoding, etc. --
  is unlikely to land. See [docs/DECISIONS.md](docs/DECISIONS.md) for
  the architectural decisions and the reasoning behind them.

## Dev setup

You need:

- **Windows 10 1809+ or Windows 11.** WPF + Win32 + winget + DPAPI.
- **PowerShell 7+.** `Set-StrictMode -Version 3.0`, the ternary
  operator, `?.`, and `?:` are all in use across the source.
- **Pester 5+** for the test suite:
  ```powershell
  Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
  ```
- An optical drive helps but isn't required for the test suite -- the
  drive-touching paths are mocked in Pester. See `tests/manual/` for
  the small set of disc-touching repros (`Repro-RipProgress.ps1`,
  `Repro-VerifyContact.ps1`).

Clone, then:

```powershell
cd C:\bin\MusicRipper        # or wherever you cloned
Invoke-Pester ./tests        # baseline ~525 tests, ~30s on a normal machine
```

The same suite runs on every push and PR via
[`.github/workflows/pester.yml`](.github/workflows/pester.yml). Expect
the CI badge in [README.md](README.md) to be green before opening a PR.

## Coding conventions

- **Comment-based help on every public function.** `.SYNOPSIS`,
  `.DESCRIPTION`, `.PARAMETER` for each param, `.EXAMPLE` where it
  helps. Inline `#` comments on anything that looks weird. Future-you
  will thank present-you.
- **File-header block on every script and module.** Top-of-file
  `<# .SYNOPSIS / .DESCRIPTION / .NOTES #>` summarising what the file
  is and where it fits in the pipeline. See `src/core/Invoke-Rip.ps1`
  or `src/sync/Sync-ToOneDrive.ps1` for the shape.
- **Conventional Commits** for commit messages: `feat(scope): ...`,
  `fix(scope): ...`, `docs: ...`, `chore: ...`, `refactor: ...`,
  `test: ...`, `ci: ...`. Each commit should leave the suite green.
- **Pester tests for any pure-logic code.** Anything that could be
  written as a function returning a value gets a `tests/<thing>.Tests.ps1`.
  WPF / disc-touching code goes in the manual-verification list at
  the end of the relevant phase note in DECISIONS.md.
- **No new runtime dependencies.** PowerShell 7 + WPF + the existing
  CLI deps (CUETools, FLAC tools, Picard, WireGuard) are the entire
  surface. New `Add-Type` references against existing system DLLs are
  fine; new `winget` packages need a discussion in an issue first.
- **DPAPI for every secret.** `Export-Clixml` against a PSCredential,
  never plaintext, never base64. See `src/lib/Config.psm1` for the
  established round-trip pattern.
- **`Join-Path` for every path.** Sanitize user-derived path
  components via `ConvertTo-SafeWindowsPathSegment`
  (`src/lib/Common.psm1`) before joining.
- **Logging** via the `Logging` module (`Write-RipperLog INFO|WARN|ERR
  '<source>' '<message>'`). Don't `Write-Host` from production code
  paths -- it doesn't reach the per-session log file.

## What goes where

- `src/core/` -- disc-id, metadata, rip, tag, library-layout planning.
  Pure-logic code; testable.
- `src/ui/` -- WPF dialogs. Inline XAML, not a separate `.xaml` file.
  See gotchas in DECISIONS.md before touching the dispatcher /
  cross-runspace plumbing.
- `src/sync/` -- per-album sync targets + retention. New built-in
  targets land here as `Sync-To<Name>.ps1` exporting an
  `Invoke-RipperSyncTo<Name>` function with the contract documented
  in `src/sync/Invoke-RipperSync.ps1`.
- `src/lib/` -- shared modules. `Common.psm1` for path / version /
  asset helpers, `Config.psm1` for config + DPAPI, `Logging.psm1`
  for the per-session log file, `Wireguard.psm1` for tunnel
  lifecycle, `DriveRegistration.psm1` for AccurateRip lookup.
- `src/tools/` -- one-off CLI tools the user invokes directly.
  `Move-FromReviewQueue.ps1`, `Sync-PendingAlbums.ps1`,
  `Show-RipperConfig.ps1`, `Test-SynologySync.ps1`.
- `setup/` -- install / uninstall chain steps. `Install-*.ps1` scripts
  invoked by the top-level `Install-MusicRipper.ps1`.
- `tests/` -- Pester. `tests/fixtures/` for reference data,
  `tests/manual/` for disc-touching repros that don't run in CI.
- `docs/` -- end-user + contributor docs. `DECISIONS.md` is the
  canonical record of architectural choices and the reasoning behind
  them; check it before proposing anything that contradicts an
  existing decision.

## Pull request flow

1. Fork + branch (`feature/<short-slug>` or `fix/<short-slug>`).
2. Make your change. Conventional Commits, one logical unit per commit.
3. Add / update Pester tests for any pure-logic code touched.
4. Run `Invoke-Pester ./tests` locally; confirm the count went up
   (or stayed flat for non-test changes) and zero failures.
5. Open the PR. CI runs automatically; expect it green before review.
6. If your change has a UX consequence the suite can't catch (a new
   WPF dialog, a new sync target, a config-field addition), include a
   short manual-verification recipe in the PR description so the
   maintainer can re-run it locally.

## Cutting a release

After a merge that should reach the parents' install via the
auto-updater (`Update-MusicRipper.ps1`), bump
`$script:RipperVersion` in [src/lib/Common.psm1](src/lib/Common.psm1)
and run `gh release create vX.Y --title "..." --notes "..."`. The
notes body is shown verbatim in the parent's update dialog, so write
it for that audience. Full workflow + rationale (and what happens if
you skip the Release tag) lives in
[docs/SETUP.md](docs/SETUP.md#cutting-a-release-engineer-side-phase-8--d-032).

That's it. Thanks for reading.
