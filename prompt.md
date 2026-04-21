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

[Paste the full contents of `plan.md` here when running this prompt — everything from "# Plan: MusicRipper" through the end of "Further considerations". The plan is the authoritative spec; this prompt is just the operating rules around it.]

---

## Start here

1. Acknowledge you've read the plan and these rules.
2. Confirm your understanding of the phase order and the per-phase definition of done.
3. Begin **Phase 1 — Foundations & setup**. Initialize the repo, create the directory scaffold, set up the root `README.md` with a "Current status" table showing all 7 phases (Phase 1: in progress; rest: not started), then proceed with the Phase 1 work items in order.

When you finish Phase 1, stop and report. Wait for my approval before starting Phase 2.