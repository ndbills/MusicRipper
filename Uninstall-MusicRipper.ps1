<#
.SYNOPSIS
    Phase 7: uninstall MusicRipper. Removes everything Install-MusicRipper.ps1
    + Install-Dependencies.ps1 + Install-Shortcut.ps1 set up, plus the
    user-data files (config.json, credentials.clixml, logs\). Does NOT
    touch the library root, and (by user request) leaves PowerShell 7
    installed.

.DESCRIPTION
    Uninstall steps (in order, each independently best-effort):

      1. Try to read $env:LOCALAPPDATA\MusicRipper\config.json so we can
         pick up cfg.WireGuardTunnelName (needed for the per-tunnel
         service uninstall) before the next step deletes it.

      2. WireGuard tunnel (per-tunnel service installed via
         wireguard.exe /installtunnelservice). REQUIRES ELEVATION --
         skipped with a warning if not running as admin. Uses
         Uninstall-RipperVpnTunnel from src/lib/Wireguard.psm1.

      3. Desktop shortcut "Rip a CD" (or whatever name was used at
         install time, via -ShortcutName override).

      4. Winget packages: gchudov.CUETools, Xiph.FLAC,
         MusicBrainz.Picard, WireGuard.WireGuard. Skipped under
         -KeepDependencies. Microsoft.PowerShell is intentionally
         NEVER touched -- the user explicitly wants it to stay.

      5. $env:LOCALAPPDATA\MusicRipper\ recursively. This covers BOTH
         (a) the parent-mode install dir copied here by
         Install-MusicRipper.ps1, AND (b) the user-data files
         (config.json, credentials.clixml, logs\). Skipped under
         -KeepUserData.

    What this script intentionally does NOT remove:
      - The library root (cfg.LibraryRoot). Music files stay where
        they are. The user pointed at this folder once and we are
        never going to surprise-delete it.
      - <LibraryRoot>\.musicripper\discids.json + sync-state.json.
        These are library data, not MusicRipper installation data.
        If you want them gone, delete the folder by hand.
      - The repo itself (when this script lives at, e.g.,
        C:\bin\MusicRipper\). The script never deletes its own
        parent directory -- that would yank the rug out from under
        a still-running pwsh process.
      - PowerShell 7 (winget package Microsoft.PowerShell).

    Idempotent: re-running on an already-clean machine is a quiet
    no-op for each step.

.PARAMETER ShortcutName
    Override the Desktop shortcut name. Defaults to "Rip a CD"
    (matches Install-Shortcut.ps1's default).

.PARAMETER KeepDependencies
    Skip the winget uninstall step. Useful when CUETools / FLAC /
    Picard are also used by other tools on the machine and you don't
    want to nuke them.

.PARAMETER KeepUserData
    Leave $env:LOCALAPPDATA\MusicRipper\ alone. Removes the shortcut,
    WG tunnel, and dependencies, but preserves the parent's settings
    so a re-install picks up where they left off.

.PARAMETER KeepShortcut
    Leave the Desktop shortcut in place. Mostly useful in combination
    with -KeepUserData for "downgrade to data-only" weirdness.

.PARAMETER Force
    Skip the "are you sure?" confirmation prompt. Required for
    unattended runs.

.EXAMPLE
    PS> .\Uninstall-MusicRipper.ps1
    Interactive run -- prompts once before the destructive steps,
    then walks through every uninstall step.

.EXAMPLE
    PS> .\Uninstall-MusicRipper.ps1 -KeepDependencies -Force
    Strip MusicRipper itself but leave CUETools / FLAC / Picard /
    WireGuard installed. No prompt.

.EXAMPLE
    PS> .\Uninstall-MusicRipper.ps1 -WhatIf
    Show every action that would be taken, touch nothing.

.NOTES
    Library root is sacred. If you typed it into Settings, the
    uninstaller never touches it. Period.

    The WireGuard tunnel uninstall is the only step that strictly
    needs elevation; everything else works under a normal user
    context (winget elevates itself per package as needed).

    Exit codes:
        0  every step completed (or was skipped cleanly)
        1  one or more steps failed (see message log)
#>

# Require an elevated pwsh up-front. Two reasons:
#   1. WireGuard tunnel uninstall (`/uninstalltunnelservice`) needs admin
#      -- it touches the Service Control Manager.
#   2. Several winget packages (esp. WireGuard.WireGuard) ship MSI / Inno
#      uninstallers that prompt for elevation per-package; pre-elevating
#      means the user gets ONE UAC prompt at launch (when they double-click
#      this script) instead of one-per-package mid-run.
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ShortcutName    = 'Rip a CD',
    [switch] $KeepDependencies,
    [switch] $KeepUserData,
    [switch] $KeepShortcut,
    [switch] $Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# --- helpers --------------------------------------------------------------

function Write-Step { param([string]$M) Write-Host ''; Write-Host "==> $M" -ForegroundColor Cyan }
function Write-Ok   { param([string]$M) Write-Host "[ok]   $M" -ForegroundColor Green }
function Write-Skip { param([string]$M) Write-Host "[skip] $M" -ForegroundColor DarkGray }
function Write-Warn { param([string]$M) Write-Host "[warn] $M" -ForegroundColor Yellow }
function Write-Fail { param([string]$M) Write-Host "[fail] $M" -ForegroundColor Red }


# --- 0. Resolve repo root + lay out paths --------------------------------
$repoRoot       = $PSScriptRoot
$ripperDataRoot = Join-Path $env:LOCALAPPDATA 'MusicRipper'
$configPath     = Join-Path $ripperDataRoot 'config.json'
$desktopPath    = [Environment]::GetFolderPath('Desktop')
$shortcutPath   = Join-Path $desktopPath "$ShortcutName.lnk"

Write-Host ''
Write-Host '================================================================' -ForegroundColor DarkCyan
Write-Host ' MusicRipper uninstaller' -ForegroundColor DarkCyan
Write-Host '================================================================' -ForegroundColor DarkCyan
Write-Host "Data root      : $ripperDataRoot"
Write-Host "Desktop shortcut: $shortcutPath"
Write-Host "Repo (this dir): $repoRoot"

# --- 1. Read config for WireGuardTunnelName before we delete it ---------
$wgTunnelName = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties['WireGuardTunnelName'] -and $cfg.WireGuardTunnelName) {
            $wgTunnelName = [string]$cfg.WireGuardTunnelName
            Write-Host "WG tunnel       : $wgTunnelName  (from config.json)"
        }
    } catch {
        Write-Warn "Couldn't parse config.json (non-fatal): $($_.Exception.Message)"
    }
}

# --- 2. Confirm with the user --------------------------------------------
$plan = @()
if (-not $KeepDependencies)                    { $plan += 'uninstall CUETools, Xiph.FLAC, MusicBrainz.Picard, WireGuard.WireGuard via winget' }
if ($wgTunnelName)                             { $plan += "uninstall WireGuard tunnel service '$wgTunnelName'" }
if (-not $KeepShortcut)                        { $plan += "remove Desktop shortcut '$ShortcutName.lnk'" }
if (-not $KeepUserData)                        { $plan += "delete $ripperDataRoot (config + credentials + logs)" }

if ($plan.Count -eq 0) {
    Write-Host ''
    Write-Warn 'Every step disabled by switches; nothing to do.'
    exit 0
}

Write-Host ''
Write-Host 'Planned actions:' -ForegroundColor Yellow
foreach ($p in $plan) { Write-Host "  - $p" -ForegroundColor Yellow }
Write-Host ''
Write-Host "Will NOT touch: your library root (cfg.LibraryRoot), <LibraryRoot>\.musicripper\, or PowerShell 7." -ForegroundColor Green

if (-not $Force -and -not $WhatIfPreference) {
    $answer = Read-Host 'Proceed? Type "yes" to continue, anything else to abort'
    if ($answer -ne 'yes') {
        Write-Host ''
        Write-Skip 'Aborted at confirmation prompt.'
        exit 0
    }
}

$failures = 0


# --- 3. WireGuard tunnel service ----------------------------------------
if ($wgTunnelName) {
    if ($PSCmdlet.ShouldProcess("WireGuard tunnel service '$wgTunnelName'", 'Uninstall')) {
        Write-Step "Uninstalling WireGuard tunnel service '$wgTunnelName'"
        try {
            Import-Module (Join-Path $repoRoot 'src\lib\Wireguard.psd1') -Force -ErrorAction Stop
            $ok = Uninstall-RipperVpnTunnel -Name $wgTunnelName
            if ($ok) {
                Write-Ok "Tunnel '$wgTunnelName' uninstalled."
            } else {
                Write-Warn "Uninstall-RipperVpnTunnel returned `$false; check %LOCALAPPDATA%\MusicRipper\logs\."
                $failures++
            }
        } catch {
            Write-Fail "WG tunnel uninstall threw: $($_.Exception.Message)"
            $failures++
        }
    }
} else {
    Write-Step 'WireGuard tunnel service'
    Write-Skip 'No WireGuardTunnelName in config (or no config); nothing to uninstall.'
}


# --- 4. Desktop shortcut --------------------------------------------------
if ($KeepShortcut) {
    Write-Step "Desktop shortcut"
    Write-Skip '-KeepShortcut set; leaving in place.'
} elseif (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    Write-Step "Desktop shortcut"
    Write-Skip "Not found: $shortcutPath  (already gone, or never installed)."
} elseif ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove desktop shortcut')) {
    Write-Step "Removing desktop shortcut"
    try {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Ok "Removed: $shortcutPath"
    } catch {
        Write-Fail "Couldn't remove shortcut: $($_.Exception.Message)"
        $failures++
    }
}


# --- 5. Winget packages ---------------------------------------------------
if ($KeepDependencies) {
    Write-Step 'Dependency packages (winget)'
    Write-Skip '-KeepDependencies set; not touching winget packages.'
} else {
    # Microsoft.PowerShell deliberately omitted -- the user wants PS7 to stay.
    $packages = @(
        'gchudov.CUETools',
        'Xiph.FLAC',
        'MusicBrainz.Picard',
        'WireGuard.WireGuard'
    )
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Step 'Dependency packages (winget)'
        Write-Warn "winget not found; can't uninstall: $($packages -join ', ')."
        Write-Warn 'Remove these by hand from Settings -> Apps -> Installed apps if you want them gone.'
        $failures++
    } else {
        foreach ($id in $packages) {
            $desc = "winget uninstall --exact --id $id"
            Write-Step $desc
            if (-not $PSCmdlet.ShouldProcess($id, 'winget uninstall')) { continue }
            try {
                # winget uninstall exit codes:
                #   0           : uninstalled
                #   -1978335212 : 0x8A150014 NO_APPLICABLE_INSTALLER (i.e. not installed)
                #   -1978335189 : 0x8A150049 already in target state
                # All three are "success for our purposes."
                #
                # Per-package overrides for installers that ignore winget's
                # --silent and pop a window anyway:
                #   - MusicBrainz.Picard ships an Inno Setup installer; its
                #     silent flag is /VERYSILENT /SUPPRESSMSGBOXES /NORESTART.
                #     Without --override the uninstall wizard pops a GUI even
                #     under --silent --disable-interactivity. (Observed 1 May 2026.)
                $wingetArgs = @(
                    'uninstall', '--exact', '--id', $id,
                    '--accept-source-agreements', '--silent', '--disable-interactivity'
                )
                if ($id -eq 'MusicBrainz.Picard') {
                    $wingetArgs += @('--override', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART')
                }
                & winget @wingetArgs 2>&1 | Out-Null
                $rc = $LASTEXITCODE
                switch ($rc) {
                    0           { Write-Ok "$id uninstalled." }
                    -1978335212 { Write-Skip "$id was not installed." }
                    -1978335189 { Write-Skip "$id was already in target state." }
                    default     {
                        Write-Warn "winget exited with code $rc for $id (continuing)."
                        $failures++
                    }
                }
            } catch {
                Write-Fail "winget threw for ${id}: $($_.Exception.Message)"
                $failures++
            }
        }
    }
}


# --- 6. User data + parent-mode install dir ------------------------------
# %LOCALAPPDATA%\MusicRipper\ houses both:
#   (a) the parent-mode install copy (Install-MusicRipper.ps1's default
#       target -- src\, setup\, assets\, etc.), AND
#   (b) the user-data files (config.json, credentials.clixml, logs\).
# Both get nuked together. Engineer/in-place users still keep their
# repo (e.g. C:\bin\MusicRipper\) -- we never delete the script's own
# parent.
if ($KeepUserData) {
    Write-Step "User data + install dir ($ripperDataRoot)"
    Write-Skip '-KeepUserData set; leaving in place.'
} elseif (-not (Test-Path -LiteralPath $ripperDataRoot)) {
    Write-Step "User data + install dir"
    Write-Skip "Not found: $ripperDataRoot  (already gone)."
} else {
    # Safety: NEVER delete the directory the running script lives in.
    # Compare normalized paths.
    $repoFull = (Resolve-Path -LiteralPath $repoRoot).ProviderPath.TrimEnd('\').ToLowerInvariant()
    $dataFull = (Resolve-Path -LiteralPath $ripperDataRoot).ProviderPath.TrimEnd('\').ToLowerInvariant()
    $isRunningFromTarget = $repoFull -eq $dataFull -or $repoFull.StartsWith("$dataFull\")
    if ($isRunningFromTarget) {
        Write-Step "User data + install dir ($ripperDataRoot)"
        Write-Warn "This script is running FROM '$repoRoot', which lives under the install dir."
        Write-Warn '  Copy Uninstall-MusicRipper.ps1 to a different folder (e.g. your Desktop) and re-run from there.'
        Write-Warn '  Skipping deletion to avoid yanking the rug out from under the running pwsh process.'
        $failures++
    } elseif ($PSCmdlet.ShouldProcess($ripperDataRoot, 'Recursively delete')) {
        Write-Step "Deleting $ripperDataRoot"
        try {
            Remove-Item -LiteralPath $ripperDataRoot -Recurse -Force
            Write-Ok "Removed: $ripperDataRoot"
        } catch {
            Write-Fail "Delete failed: $($_.Exception.Message)"
            Write-Warn "  Some files may be locked (open log file, running pwsh in that tree, etc.)."
            Write-Warn "  Close any open handles to '$ripperDataRoot' and re-run."
            $failures++
        }
    }
}


# --- 7. Final summary ----------------------------------------------------
Write-Host ''
Write-Host '================================================================' -ForegroundColor DarkCyan
if ($failures -eq 0) {
    Write-Host ' MusicRipper uninstall complete.' -ForegroundColor Green
} else {
    Write-Host " MusicRipper uninstall completed with $failures issue(s) -- see messages above." -ForegroundColor Yellow
}
Write-Host '================================================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host 'Untouched (intentionally):'
Write-Host '  - Your music library (cfg.LibraryRoot).'
Write-Host '  - <LibraryRoot>\.musicripper\discids.json + sync-state.json.'
Write-Host '  - PowerShell 7.'
Write-Host ''

if ($failures -gt 0) { exit 1 } else { exit 0 }
