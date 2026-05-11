<#
.SYNOPSIS
    Drop "MusicRipper - Rip a CD.lnk", "MusicRipper - Settings.lnk",
    "MusicRipper - Update.lnk", and "MusicRipper - Uninstall.lnk"
    directly into the per-user Start Menu Programs folder so they
    show up in Search and the All apps list.

.DESCRIPTION
    Per-user, no admin required. All shortcuts go directly under
    %APPDATA%\Microsoft\Windows\Start Menu\Programs\ -- NOT into a
    MusicRipper\ subfolder, because Win11's flat 'All apps' list
    doesn't render Start Menu subfolders the way Win10 did. The
    'MusicRipper - ' prefix on each filename is what groups them
    visually in Search and the alphabetic All-apps list.

    Mirrors the layout / RunAsAdmin flags / WindowStyle of the
    Desktop versions:
      - Rip a CD       : RunAsAdministrator flag set (byte 21 of the
                         SHLLINK structure), WindowStyle=Minimized.
                         CUETools' SCSI driver needs admin to open
                         the optical drive.
      - Settings       : F-6 / Phase 8. NO RunAsAdministrator flag
                         (config edits don't touch the optical drive),
                         WindowStyle=Minimized so the WPF editor is
                         the user-visible surface and not the pwsh
                         console. Targets src\tools\Show-RipperConfig.ps1.
      - Update         : Phase 8 / D-032. NO RunAsAdministrator flag.
                         Updater downloads + applies new sources from
                         GitHub; only the post-apply re-run of
                         Install-Dependencies.ps1 needs UAC, and
                         winget self-elevates per-package as needed.
                         WindowStyle=Minimized so the WPF dialog is
                         the user-visible surface. Targets the
                         repo-root Update-MusicRipper.ps1 (sibling to
                         Install-MusicRipper.ps1 / Uninstall-MusicRipper.ps1).
      - Uninstall      : NO RunAsAdministrator flag, WindowStyle=Normal.
                         Uninstall-MusicRipper.ps1 self-elevates AFTER
                         the parent shell prompts; pre-elevating would
                         pop UAC before the friendly "Proceed?" question.

    Idempotent: re-run any time to refresh all shortcuts. Cleans up
    any legacy MusicRipper\ subfolder from older installs.

.NOTES
    Per-user (%APPDATA%, not %ProgramData%) so we don't need admin
    to create or remove. Uninstall-MusicRipper.ps1 deletes all
    shortcuts (and any legacy MusicRipper\ subfolder) when run.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh     = (Get-Command pwsh -ErrorAction Stop).Source

$startMenuRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
if (-not (Test-Path -LiteralPath $startMenuRoot)) {
    # Should always exist on Windows, but defensive: create if not.
    New-Item -ItemType Directory -Path $startMenuRoot -Force | Out-Null
}

# Clean up the legacy MusicRipper\ subfolder from older installs.
# Win10 / pre-flatten layout dropped both shortcuts in a subfolder;
# Win11's All apps list hides subfolders so we now place the .lnks
# directly in Programs\. If the subfolder still exists from a prior
# install, nuke it so we don't end up with stale duplicates.
$legacyFolder = Join-Path $startMenuRoot 'MusicRipper'
if (Test-Path -LiteralPath $legacyFolder -PathType Container) {
    try {
        Remove-Item -LiteralPath $legacyFolder -Recurse -Force
        Write-Host "Removed legacy Start Menu folder: $legacyFolder" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Couldn't remove legacy Start Menu folder '$legacyFolder': $($_.Exception.Message)"
    }
}

# Optional MusicRipper icon (assets may not exist on every install).
$iconPath = Join-Path $repoRoot 'assets\musicripper.ico'

$shell = New-Object -ComObject WScript.Shell

# --- 1. "MusicRipper - Rip a CD" ---------------------------------------
$ripScript = Join-Path $repoRoot 'src\Start-Ripper.ps1'
if (-not (Test-Path -LiteralPath $ripScript -PathType Leaf)) {
    throw "Start-Ripper.ps1 not found at '$ripScript'."
}
# 'MusicRipper - ' prefix groups the two shortcuts together in the
# alphabetic All apps list. Search by 'musicripper', 'rip a cd',
# or 'uninstall' all surface them.
$ripLnk = Join-Path $startMenuRoot 'MusicRipper - Rip a CD.lnk'
$lnk = $shell.CreateShortcut($ripLnk)
$lnk.TargetPath       = $pwsh
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$ripScript`""
$lnk.WorkingDirectory = Split-Path -Parent $ripScript
$lnk.Description      = 'MusicRipper - rip an Audio CD to FLAC'
$lnk.IconLocation     = if (Test-Path -LiteralPath $iconPath) { $iconPath } else { "$pwsh,0" }
# Minimized so the WPF dialogs are the user-visible surface, not the
# pwsh console. Same as setup/Install-Shortcut.ps1 (the desktop one).
$lnk.WindowStyle      = 7
$lnk.Save()

# Patch byte 21 (0x15) bit 0x20 = RunAsAdministrator. WScript.Shell
# can't set this directly; we tweak the binary like Install-Shortcut.ps1
# does for the Desktop "Rip a CD" .lnk. CUETools' SCSI driver
# (CDDriveReader.Open) needs admin to open the optical drive.
$bytes = [System.IO.File]::ReadAllBytes($ripLnk)
$bytes[21] = $bytes[21] -bor 0x20
[System.IO.File]::WriteAllBytes($ripLnk, $bytes)
Write-Host "Created shortcut: $ripLnk  (will request elevation on launch)" -ForegroundColor Green

# --- 2. "MusicRipper - Settings" (F-6, Phase 8) -------------------------
# Standalone entry point for the Phase 6.6 WPF config editor so a
# parent can change LibraryRoot, sync targets, creds, etc. without
# launching a rip session. NOT elevated -- config edits don't touch
# the optical drive, and avoiding UAC keeps the parent flow friction-
# less. WindowStyle=Minimized so the WPF dialog is the user-visible
# surface, not the pwsh console (same idiom as Rip a CD).
$settingsScript = Join-Path $repoRoot 'src\tools\Show-RipperConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsScript -PathType Leaf)) {
    throw "Show-RipperConfig.ps1 not found at '$settingsScript'."
}
$settingsLnk = Join-Path $startMenuRoot 'MusicRipper - Settings.lnk'
$lnk = $shell.CreateShortcut($settingsLnk)
$lnk.TargetPath       = $pwsh
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$settingsScript`""
$lnk.WorkingDirectory = Split-Path -Parent $settingsScript
$lnk.Description      = 'MusicRipper - edit settings (applies the next time MusicRipper runs)'
$lnk.IconLocation     = if (Test-Path -LiteralPath $iconPath) { $iconPath } else { "$pwsh,0" }
$lnk.WindowStyle      = 7
$lnk.Save()
Write-Host "Created shortcut: $settingsLnk" -ForegroundColor Green

# --- 3. "MusicRipper - Update" (Phase 8 / D-032) -----------------------
# Standalone entry point for the self-update WPF dialog so a parent
# can pull the latest GitHub Release without an engineer-driven copy
# step. NOT elevated -- the source-zip download / extract runs as the
# parent's user; only the post-apply re-run of Install-Dependencies
# touches winget which self-elevates per-package as needed.
# WindowStyle=Minimized so the WPF dialog is the user-visible surface.
$updateScript = Join-Path $repoRoot 'Update-MusicRipper.ps1'
if (-not (Test-Path -LiteralPath $updateScript -PathType Leaf)) {
    throw "Update-MusicRipper.ps1 not found at '$updateScript'."
}
$updateLnk = Join-Path $startMenuRoot 'MusicRipper - Update.lnk'
$lnk = $shell.CreateShortcut($updateLnk)
$lnk.TargetPath       = $pwsh
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`""
$lnk.WorkingDirectory = Split-Path -Parent $updateScript
$lnk.Description      = 'MusicRipper - check for and apply updates'
$lnk.IconLocation     = if (Test-Path -LiteralPath $iconPath) { $iconPath } else { "$pwsh,0" }
$lnk.WindowStyle      = 7
$lnk.Save()
Write-Host "Created shortcut: $updateLnk" -ForegroundColor Green

# --- 4. "MusicRipper - Uninstall" ---------------------------------------
$uninstallScript = Join-Path $repoRoot 'Uninstall-MusicRipper.ps1'
if (-not (Test-Path -LiteralPath $uninstallScript -PathType Leaf)) {
    throw "Uninstall-MusicRipper.ps1 not found at '$uninstallScript'."
}
$uninstallLnk = Join-Path $startMenuRoot 'MusicRipper - Uninstall.lnk'
$lnk = $shell.CreateShortcut($uninstallLnk)
$lnk.TargetPath       = $pwsh
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`""
$lnk.WorkingDirectory = $repoRoot
$lnk.Description      = 'Uninstall MusicRipper (self-elevates for the admin steps)'
$lnk.IconLocation     = if (Test-Path -LiteralPath $iconPath) { $iconPath } else { "$pwsh,0" }
# Normal window so the parent shell is visible for the "Proceed? Type
# yes" confirmation prompt. The elevated child runs behind UAC; we
# don't want to pre-elevate the shortcut itself (would just produce
# an extra UAC popup before the friendly prompt).
$lnk.WindowStyle      = 1
$lnk.Save()
Write-Host "Created shortcut: $uninstallLnk" -ForegroundColor Green
