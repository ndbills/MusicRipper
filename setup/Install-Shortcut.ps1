<#
.SYNOPSIS
    Create a Desktop shortcut "MusicRipper - Rip a CD" that launches
    Start-Ripper.ps1 in PS7.

.DESCRIPTION
    Pipeline position:
        Setup script #4. Run after the others. Creates the one-click entry
        point parents will use.

    Implementation: WScript.Shell COM object — present on all Windows by
    default, no extra runtime, lets us set the icon. The shortcut points at
    `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Start-Ripper.ps1`
    so it runs in PS7 regardless of the user's default association.

    Naming: matches the Start Menu shortcut name ("MusicRipper - Rip a CD")
    so a parent searching the Start Menu sees the same label as on the
    Desktop. Earlier installs used the bare "Rip a CD" name; the legacy
    shortcut is auto-deleted at install time so re-running this script (or
    letting the auto-updater's setup-chain re-run handle it) cleans up.

.EXAMPLE
    PS> ./setup/Install-Shortcut.ps1

.NOTES
    Why -NoProfile: parents' machines might have a slow profile (corporate,
    big modules) and we want the dialog up fast. Also avoids surprise
    behavior from $PROFILE customizations.

    Why elevation: CUETools' SCSI driver (used by Get-RipperDiscId) requires
    Administrator privileges to open the optical drive. The shortcut sets
    the SHLLINK RunAsAdministrator flag so users get one UAC prompt per
    launch instead of a confusing "drive open failed" error.
#>

[CmdletBinding()]
param(
    [string]$ShortcutName = 'MusicRipper - Rip a CD'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$target   = Join-Path $repoRoot 'src\Start-Ripper.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Start-Ripper.ps1 not found at '$target'. Has the repo been laid out correctly?"
}

# Locate pwsh.exe explicitly — `where.exe pwsh` is more reliable than relying
# on the COM shortcut to resolve %PATH% at click time.
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

$desktop      = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop "$ShortcutName.lnk"

# Clean up legacy Desktop shortcut from pre-rename installs (the
# bare "Rip a CD.lnk" before we matched the Start Menu naming).
# Only when the new name actually differs from the legacy one --
# defends against a deliberate -ShortcutName 'Rip a CD' override
# nuking its own about-to-be-created file.
$legacyDesktopLnk = Join-Path $desktop 'Rip a CD.lnk'
if (($ShortcutName -ne 'Rip a CD') -and (Test-Path -LiteralPath $legacyDesktopLnk)) {
    try {
        Remove-Item -LiteralPath $legacyDesktopLnk -Force
        Write-Host "Removed legacy Desktop shortcut: $legacyDesktopLnk" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Couldn't remove legacy shortcut '$legacyDesktopLnk': $($_.Exception.Message). Delete it manually if it's still there after install completes."
    }
}

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($shortcutPath)
$lnk.TargetPath       = $pwsh
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$target`""
$lnk.WorkingDirectory = Split-Path -Parent $target
$lnk.Description      = 'MusicRipper — rip an Audio CD to FLAC'

# Project icon -- shipped at <repo>\assets\musicripper.ico (multi-resolution
# .ico generated from assets\musicripper.png by setup\Build-Icon.ps1).
# Fall back to pwsh's icon only if the asset is somehow missing.
$icon = Join-Path $repoRoot 'assets\musicripper.ico'
$lnk.IconLocation = if (Test-Path -LiteralPath $icon) { $icon } else { "$pwsh,0" }

# Launch the console minimized so the WPF dialogs are the user-visible
# surface; the pwsh window is just a log tail. WScript.Shell window styles:
# 1=Normal, 3=Maximized, 7=Minimized. (Elevated launches don't always
# honour this -- Start-Ripper.ps1 also self-minimizes its own console as
# a belt-and-suspenders fallback.)
$lnk.WindowStyle = 7

$lnk.Save()

# WScript.Shell can't set the "Run as administrator" flag on a .lnk, so we
# patch byte 21 (0x15) of the binary directly: bit 0x20 in that byte is the
# documented RunAsAdministrator flag in the Microsoft-MS-SHLLINK spec.
# We need elevation because CUETools' SCSI driver (CDDriveReader.Open) needs
# Administrator privileges to open the optical drive — without it the call
# fails with E_ACCESSDENIED (or, confusingly, "0x80070000 success").
# Spec: https://learn.microsoft.com/openspecs/windows_protocols/ms-shllink/16cb4ca1-9339-4d0c-a68d-bf1d6cc0f943
$bytes = [System.IO.File]::ReadAllBytes($shortcutPath)
$bytes[21] = $bytes[21] -bor 0x20
[System.IO.File]::WriteAllBytes($shortcutPath, $bytes)

Write-Host "Created shortcut: $shortcutPath  (will request elevation on launch)" -ForegroundColor Green
