<#
.SYNOPSIS
    Create / refresh "Uninstall MusicRipper.lnk" at the repo root.

.DESCRIPTION
    Mirrors setup/Install-Shortcut.ps1, but for the uninstaller. Why
    a sibling script and not a one-liner: .lnk files store ABSOLUTE
    paths, so a .lnk committed to git is broken on any machine whose
    repo path differs from the one that created it. This script
    regenerates the .lnk against the path it actually lives at, so
    the shortcut Just Works after a `git clone <wherever>`.

    Idempotent: run it any time to refresh the shortcut.

    Notes vs the desktop "Rip a CD" shortcut:
      - This .lnk does NOT set the RunAsAdministrator flag at byte 21
        of the SHLLINK structure. Uninstall-MusicRipper.ps1 already
        self-elevates internally (parent shell prompts the user FIRST,
        then writes a temp helper that fires UAC for the admin work).
        Pre-elevating the shortcut would just produce an extra UAC
        prompt before the friendly "Proceed?" question is even shown.
      - WindowStyle stays Normal (1) so the parent shell is visible
        for the "Proceed? Type yes" prompt. Hiding it would defeat
        the whole confirm flow.

.EXAMPLE
    PS> ./setup/Install-UninstallShortcut.ps1

.NOTES
    Run this once after `git clone` (or have Install-MusicRipper.ps1
    chain it). The .lnk is also re-created automatically every time
    this script is run.
#>

[CmdletBinding()]
param(
    [string]$ShortcutName = 'Uninstall MusicRipper'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$target   = (Get-Command pwsh -ErrorAction Stop).Source
$script   = Join-Path $repoRoot 'Uninstall-MusicRipper.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "Uninstall-MusicRipper.ps1 not found at '$script'."
}
$lnkPath  = Join-Path $repoRoot "$ShortcutName.lnk"

# Use the MusicRipper icon if assets are deployed; fall back to pwsh's.
$iconPath = Join-Path $repoRoot 'assets\musicripper.ico'

$shell = New-Object -ComObject WScript.Shell
$lnk   = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath       = $target
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$lnk.WorkingDirectory = $repoRoot
$lnk.Description      = 'Uninstall MusicRipper (self-elevates for the admin steps)'
$lnk.IconLocation     = if (Test-Path -LiteralPath $iconPath) { $iconPath } else { "$target,0" }
# WindowStyle 1 = Normal. We WANT the parent pwsh visible so the user
# can read + answer the "Proceed? Type yes to continue" prompt; only
# the elevated child needs to do its work behind a UAC prompt and
# that's handled inside the script via Start-Process -Verb RunAs.
$lnk.WindowStyle      = 1
$lnk.Save()

Write-Host "Created shortcut: $lnkPath" -ForegroundColor Green
