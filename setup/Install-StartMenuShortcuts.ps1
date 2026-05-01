<#
.SYNOPSIS
    Create a per-user Start Menu folder "MusicRipper" containing
    "Rip a CD.lnk" + "Uninstall MusicRipper.lnk".

.DESCRIPTION
    Drops the two shortcuts under
    %APPDATA%\Microsoft\Windows\Start Menu\Programs\MusicRipper\ so
    they show up in the Windows Start menu (and Search) when the user
    types "MusicRipper" or "Rip a CD". Per-user, no admin required.

    Mirrors the layout / RunAsAdmin flags / WindowStyle of the
    Desktop versions:
      - Rip a CD       : RunAsAdministrator flag set (byte 21 of the
                         SHLLINK structure), WindowStyle=Minimized.
                         CUETools' SCSI driver needs admin to open
                         the optical drive.
      - Uninstall      : NO RunAsAdministrator flag, WindowStyle=Normal.
                         Uninstall-MusicRipper.ps1 self-elevates AFTER
                         the parent shell prompts; pre-elevating would
                         pop UAC before the friendly "Proceed?" question.

    Idempotent: re-run any time to refresh both shortcuts (handles
    install dir moves, pwsh path changes, etc.).

.NOTES
    The Start Menu folder is per-user (%APPDATA%, not %ProgramData%)
    so we don't need admin to create or remove it. Uninstall-
    MusicRipper.ps1 deletes the entire folder when run.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh     = (Get-Command pwsh -ErrorAction Stop).Source

$startMenuRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\MusicRipper'
if (-not (Test-Path -LiteralPath $startMenuRoot)) {
    New-Item -ItemType Directory -Path $startMenuRoot -Force | Out-Null
    Write-Host "Created Start Menu folder: $startMenuRoot" -ForegroundColor Green
}

# Optional MusicRipper icon (assets may not exist on every install).
$iconPath = Join-Path $repoRoot 'assets\musicripper.ico'

$shell = New-Object -ComObject WScript.Shell

# --- 1. "Rip a CD" -------------------------------------------------------
$ripScript = Join-Path $repoRoot 'src\Start-Ripper.ps1'
if (-not (Test-Path -LiteralPath $ripScript -PathType Leaf)) {
    throw "Start-Ripper.ps1 not found at '$ripScript'."
}
$ripLnk = Join-Path $startMenuRoot 'Rip a CD.lnk'
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

# --- 2. "Uninstall MusicRipper" -----------------------------------------
$uninstallScript = Join-Path $repoRoot 'Uninstall-MusicRipper.ps1'
if (-not (Test-Path -LiteralPath $uninstallScript -PathType Leaf)) {
    throw "Uninstall-MusicRipper.ps1 not found at '$uninstallScript'."
}
$uninstallLnk = Join-Path $startMenuRoot 'Uninstall MusicRipper.lnk'
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
