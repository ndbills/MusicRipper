<#
.SYNOPSIS
    Phase 7: uninstall MusicRipper. Removes everything Install-MusicRipper.ps1
    + Install-Dependencies.ps1 + Install-Shortcut.ps1 set up, plus the
    user-data files (config.json, credentials.clixml, logs\). Does NOT
    touch the library root, and (by user request) leaves PowerShell 7
    installed.

.DESCRIPTION
    Two-phase elevation pattern (modeled on
    src/lib/Wireguard.psm1 :: Invoke-RipperVpnTunnelElevatedInstall,
    which is the proven recipe in this codebase):

      Phase 1 (parent shell, NOT elevated):
        Read config.json, build the planned-actions list, prompt the
        user to confirm. If they say yes, write a small temp .ps1
        helper that re-invokes THIS script with -ImAlreadyAdmin
        -Force plus all the original switches forwarded, then launch
        the helper via Start-Process -Verb RunAs -Wait. The helper
        ends with Read-Host 'Press Enter to close this window' in a
        finally block, so the elevated console window can never
        vanish silently regardless of what happens inside.

      Phase 2 (elevated child, started by the helper):
        Detects -ImAlreadyAdmin and skips the elevation block.
        Runs the actual uninstall steps. Exits via `return` so the
        helper's pause+exit can run.

    Why this shape:
      - The user's existing terminal handles the confirm prompt
        (Read-Host across the UAC boundary is unreliable -- stdin
        can be EOF immediately).
      - The helper's Read-Host runs in a freshly-launched -File
        pwsh that DOES have working stdin (matches the WG install
        flow that's been in production since Phase 6.6.F).
      - The script body uses `return` instead of `exit N` so the
        elevated child never terminates pwsh prematurely; the
        helper's finally{} is what controls when the window closes.

    What gets removed (in order):

      1. WireGuard tunnel service (per-tunnel service installed via
         wireguard.exe /installtunnelservice). Reads
         cfg.WireGuardTunnelName before step 5 nukes the config.

      2. Desktop shortcut "Rip a CD" (or whatever name was used at
         install time, via -ShortcutName override).

      3. Winget packages: gchudov.CUETools, Xiph.FLAC,
         MusicBrainz.Picard, WireGuard.WireGuard. Skipped under
         -KeepDependencies. Microsoft.PowerShell is intentionally
         NEVER touched -- the user explicitly wants it to stay.
         Picard's Inno Setup uninstaller gets --override
         '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' because winget's
         --silent doesn't translate to Inno's silent flags.

      4. $env:LOCALAPPDATA\MusicRipper\ recursively. Covers the
         parent-mode install dir AND the user-data files
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
        C:\bin\MusicRipper\).
      - PowerShell 7 (winget package Microsoft.PowerShell).

    Idempotent: re-running on an already-clean machine is a quiet
    no-op for each step.

.PARAMETER ShortcutName
    Override the Desktop shortcut name. Defaults to "Rip a CD"
    (matches Install-Shortcut.ps1's default).

.PARAMETER KeepDependencies
    Skip the winget uninstall step.

.PARAMETER KeepUserData
    Leave $env:LOCALAPPDATA\MusicRipper\ alone.

.PARAMETER KeepShortcut
    Leave the Desktop shortcut in place.

.PARAMETER Force
    Skip the "are you sure?" confirmation prompt.

.PARAMETER ImAlreadyAdmin
    INTERNAL: set by the temp helper that the parent shell launches
    under UAC. Tells this script "skip the elevation handshake; I'm
    the elevated child now." Not for human callers.

.EXAMPLE
    PS> .\Uninstall-MusicRipper.ps1
    Interactive run. Prompts in the parent shell, then UAC,
    elevated console runs the uninstall and stays open at a
    "Press Enter to close" prompt.

.EXAMPLE
    PS> .\Uninstall-MusicRipper.ps1 -KeepDependencies -Force
    Skip the parent-shell prompt and skip the winget uninstall.
    Still self-elevates for the WG tunnel + folder delete.

.NOTES
    Library root is sacred. If you typed it into Settings, the
    uninstaller never touches it. Period.

    Exit codes:
        0  every step completed (or was skipped cleanly)
        1  one or more steps failed (see message log)
        2  UAC elevation declined / aborted by user
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ShortcutName    = 'Rip a CD',
    [switch] $KeepDependencies,
    [switch] $KeepUserData,
    [switch] $KeepShortcut,
    [switch] $Force,

    [Parameter(DontShow)]
    [switch] $ImAlreadyAdmin
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# --- helpers --------------------------------------------------------------

function Write-Step { param([string]$M) Write-Host ''; Write-Host "==> $M" -ForegroundColor Cyan }
function Write-Ok   { param([string]$M) Write-Host "[ok]   $M" -ForegroundColor Green }
function Write-Skip { param([string]$M) Write-Host "[skip] $M" -ForegroundColor DarkGray }
function Write-Warn { param([string]$M) Write-Host "[warn] $M" -ForegroundColor Yellow }
function Write-Fail { param([string]$M) Write-Host "[fail] $M" -ForegroundColor Red }

function Test-IsAdministrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [System.Security.Principal.WindowsPrincipal]::new($id)
    $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-RipperWindowsUninstaller {
<#
.SYNOPSIS
    Find the standard Programs-and-Features uninstaller string for an
    installed app whose DisplayName matches a wildcard.

.DESCRIPTION
    Used as a fallback when winget claims a package is "not installed"
    but the binary clearly is on disk -- typically because the user
    installed it via the vendor's own MSI / Inno Setup installer rather
    than via winget, OR winget lost the package association after an
    auto-update.

    Walks the four standard registry roots:
      HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\
      HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\  (32-bit on 64-bit)
      HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\
      HKCU\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\

    Returns a hashtable @{ DisplayName; UninstallString;
    QuietUninstallString } for the first match, or $null if none.
    Caller picks QuietUninstallString if present (Inno Setup populates
    this with the silent flags built in), else parses UninstallString
    and appends silent flags.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$DisplayNameLike
    )
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            $matches = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
                       ForEach-Object {
                           try {
                               $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                               if ($p -and $p.DisplayName -and $p.DisplayName -like $DisplayNameLike) { $p }
                           } catch { }
                       } |
                       Select-Object -First 1
            if ($matches) {
                return @{
                    DisplayName          = [string]$matches.DisplayName
                    UninstallString      = [string]$matches.UninstallString
                    QuietUninstallString = if ($matches.PSObject.Properties['QuietUninstallString']) { [string]$matches.QuietUninstallString } else { $null }
                }
            }
        } catch { }
    }
    return $null
}


# --- Common path layout (used by both phases) ----------------------------
$repoRoot       = $PSScriptRoot
$ripperDataRoot = Join-Path $env:LOCALAPPDATA 'MusicRipper'
$configPath     = Join-Path $ripperDataRoot 'config.json'
$desktopPath    = [Environment]::GetFolderPath('Desktop')
$shortcutPath   = Join-Path $desktopPath "$ShortcutName.lnk"


# =========================================================================
# Phase 1: parent shell -- prompt + relaunch elevated via temp helper.
# =========================================================================
if (-not $ImAlreadyAdmin -and -not (Test-IsAdministrator)) {

    # Read WG tunnel name now (config.json may be deleted by step 4).
    $wgTunnelName = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $cfgPre = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($cfgPre.PSObject.Properties['WireGuardTunnelName'] -and $cfgPre.WireGuardTunnelName) {
                $wgTunnelName = [string]$cfgPre.WireGuardTunnelName
            }
        } catch { }
    }

    Write-Host ''
    Write-Host '================================================================' -ForegroundColor DarkCyan
    Write-Host ' MusicRipper uninstaller' -ForegroundColor DarkCyan
    Write-Host '================================================================' -ForegroundColor DarkCyan
    Write-Host "Data root      : $ripperDataRoot"
    Write-Host "Desktop shortcut: $shortcutPath"

    $plan = @()
    if (-not $KeepDependencies) { $plan += 'uninstall CUETools, Xiph.FLAC, MusicBrainz.Picard, WireGuard.WireGuard via winget' }
    if ($wgTunnelName)          { $plan += "uninstall WireGuard tunnel service '$wgTunnelName'" }
    if (-not $KeepShortcut)     { $plan += "remove Desktop shortcut '$ShortcutName.lnk'" }
    if (-not $KeepShortcut)     { $plan += "remove Start Menu shortcuts (Rip a CD + Uninstall)" }
    if (-not $KeepUserData)     { $plan += "delete $ripperDataRoot (config + credentials + logs)" }

    if ($plan.Count -eq 0) {
        Write-Host ''
        Write-Warn 'Every step disabled by switches; nothing to do.'
        exit 0
    }

    Write-Host ''
    Write-Host 'Planned actions:' -ForegroundColor Yellow
    foreach ($p in $plan) { Write-Host "  - $p" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'Will NOT touch: your music library, <LibraryRoot>\.musicripper\, or PowerShell 7.' -ForegroundColor Green

    if (-not $Force -and -not $WhatIfPreference) {
        Write-Host ''
        $answer = Read-Host 'Proceed? Type "yes" to continue, anything else to abort'
        if ($answer -ne 'yes') {
            Write-Host ''
            Write-Skip 'Aborted at confirmation prompt.'
            exit 0
        }
    }

    Write-Host ''
    Write-Host 'Relaunching elevated...' -ForegroundColor Yellow
    Write-Host '(A UAC prompt will appear. Approve it to continue.)' -ForegroundColor DarkGray

    # ---- Build the temp helper script ----------------------------------
    # The helper re-invokes us with -ImAlreadyAdmin (skips elevation)
    # plus -Force (parent already prompted) plus every switch the user
    # originally passed. ALWAYS Read-Host on the way out in a finally
    # block so the elevated console can't vanish silently.
    #
    # Single-quoted strings inside the helper for path literals so
    # backslashes don't get re-parsed; backtick-escape `$ everywhere
    # we DO want runtime interpolation in the elevated child.

    # Reconstruct the user's switches (minus -ImAlreadyAdmin which we add).
    $forwardedSwitches = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $name = $kv.Key
        if ($name -eq 'ImAlreadyAdmin') { continue }   # internal, never re-pass
        $val  = $kv.Value
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $forwardedSwitches += "-$name" }
        } elseif ($val -is [bool]) {
            $forwardedSwitches += @("-$name", $(if ($val) { '$true' } else { '$false' }))
        } else {
            $escaped = ([string]$val) -replace "'", "''"
            $forwardedSwitches += @("-$name", "'$escaped'")
        }
    }
    if ($WhatIfPreference -and -not $PSBoundParameters.ContainsKey('WhatIf')) {
        $forwardedSwitches += '-WhatIf'
    }
    # -Force in the elevated child so its prompt path is never reached
    # (defensive even though -ImAlreadyAdmin already implies "skip prompt").
    if (-not $PSBoundParameters.ContainsKey('Force') -and -not $WhatIfPreference) {
        $forwardedSwitches += '-Force'
    }
    $forwardedJoined = ($forwardedSwitches -join ' ')

    $scriptPathLiteral = $PSCommandPath -replace "'", "''"
    $helperPath = Join-Path ([System.IO.Path]::GetTempPath()) `
                  ("musicripper-uninstall-$([guid]::NewGuid().Guid.Substring(0,8)).ps1")

    $helperBody = @"
Set-StrictMode -Version 3.0
`$ErrorActionPreference = 'Continue'   # let the script handle its own errors
`$exitCode = 0
try {
    & '$scriptPathLiteral' -ImAlreadyAdmin $forwardedJoined
    if (`$null -ne `$LASTEXITCODE) { `$exitCode = [int]`$LASTEXITCODE }
} catch {
    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Red
    Write-Host 'Uninstall threw an unhandled error:' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    if (`$_.ScriptStackTrace) {
        Write-Host ''
        Write-Host 'Stack trace:' -ForegroundColor DarkRed
        Write-Host `$_.ScriptStackTrace -ForegroundColor DarkRed
    }
    Write-Host '======================================================================' -ForegroundColor Red
    `$exitCode = 99
} finally {
    Write-Host ''
    Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray
    Read-Host 'Press Enter to close this window'
}
exit `$exitCode
"@

    Set-Content -LiteralPath $helperPath -Value $helperBody -Encoding UTF8

    try {
        $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
        $proc = Start-Process -FilePath $pwshExe `
                              -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helperPath) `
                              -Verb RunAs `
                              -Wait `
                              -PassThru `
                              -ErrorAction Stop
        # Helper exited cleanly -- delete the temp file. (We KEEP it on
        # failure for diagnosis: helper script + its echoed errors are
        # the engineer's only forensic artifact for the elevated run.)
        $rc = 0
        if ($proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
            $rc = [int]$proc.ExitCode
        }
        if ($rc -eq 0) {
            Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host ''
            Write-Warn "Elevated uninstaller exited with code $rc."
            Write-Warn "Helper script kept at: $helperPath"
        }
        exit $rc
    } catch [System.ComponentModel.Win32Exception] {
        # Win32 1223 = UAC declined.
        if ($_.Exception.NativeErrorCode -eq 1223) {
            Write-Host ''
            Write-Host 'UAC elevation declined; uninstall aborted.' -ForegroundColor Red
            Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
            exit 2
        }
        Write-Host ''
        Write-Host "Could not relaunch elevated: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Helper script kept at: $helperPath" -ForegroundColor DarkGray
        exit 3
    } catch {
        Write-Host ''
        Write-Host "Could not relaunch elevated: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Helper script kept at: $helperPath" -ForegroundColor DarkGray
        exit 3
    }
}


# =========================================================================
# Phase 2: elevated child -- the actual uninstall work.
# Reached when:
#   (a) -ImAlreadyAdmin was passed (normal path: temp helper called us), OR
#   (b) the user already had an elevated pwsh and ran us directly.
# In both cases Test-IsAdministrator is true. Use `return` instead of
# `exit N` so the temp helper's finally{} block can run -- pwsh exits
# the running script via return + the helper's `exit $exitCode` does
# the actual process exit AFTER the Read-Host pause.
# =========================================================================

# Refresh the WG tunnel name in case Phase 1 didn't run (i.e. user
# already had elevated pwsh).
if (-not (Get-Variable -Name wgTunnelName -Scope Local -ErrorAction SilentlyContinue)) {
    $wgTunnelName = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($cfg.PSObject.Properties['WireGuardTunnelName'] -and $cfg.WireGuardTunnelName) {
                $wgTunnelName = [string]$cfg.WireGuardTunnelName
            }
        } catch {
            Write-Warn "Couldn't parse config.json (non-fatal): $($_.Exception.Message)"
        }
    }
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor DarkCyan
Write-Host ' MusicRipper uninstaller (elevated)' -ForegroundColor DarkCyan
Write-Host '================================================================' -ForegroundColor DarkCyan
Write-Host "Data root      : $ripperDataRoot"
Write-Host "Desktop shortcut: $shortcutPath"
if ($wgTunnelName) { Write-Host "WG tunnel       : $wgTunnelName  (from config.json)" }

# Build the plan list (used for the no-op short-circuit in the rare
# case that all the -Keep* switches are set + -Force).
$plan = @()
if (-not $KeepDependencies) { $plan += 'winget' }
if ($wgTunnelName)          { $plan += 'wg-tunnel' }
if (-not $KeepShortcut)     { $plan += 'shortcut' }
if (-not $KeepUserData)     { $plan += 'user-data' }
if ($plan.Count -eq 0) {
    Write-Host ''
    Write-Warn 'Every step disabled by switches; nothing to do.'
    $global:LASTEXITCODE = 0
    return
}

# Confirmation should already have happened in Phase 1, but if a user
# ran us directly from an elevated shell without -Force, prompt now.
if (-not $Force -and -not $WhatIfPreference -and -not $ImAlreadyAdmin) {
    Write-Host ''
    Write-Host 'Will NOT touch: your music library, <LibraryRoot>\.musicripper\, or PowerShell 7.' -ForegroundColor Green
    Write-Host ''
    $answer = Read-Host 'Proceed? Type "yes" to continue, anything else to abort'
    if ($answer -ne 'yes') {
        Write-Host ''
        Write-Skip 'Aborted at confirmation prompt.'
        $global:LASTEXITCODE = 0
        return
    }
}

$failures = 0


# --- Step 1: WireGuard tunnel service -----------------------------------
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


# --- Step 2: Desktop shortcut -------------------------------------------
if ($KeepShortcut) {
    Write-Step 'Desktop shortcut'
    Write-Skip '-KeepShortcut set; leaving in place.'
} elseif (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    Write-Step 'Desktop shortcut'
    Write-Skip "Not found: $shortcutPath  (already gone, or never installed)."
} elseif ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove desktop shortcut')) {
    Write-Step 'Removing desktop shortcut'
    try {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Ok "Removed: $shortcutPath"
    } catch {
        Write-Fail "Couldn't remove shortcut: $($_.Exception.Message)"
        $failures++
    }
}


# --- Step 2b: Start Menu shortcuts --------------------------------------
# Two .lnks installed by setup\Install-StartMenuShortcuts.ps1 directly
# in %APPDATA%\Microsoft\Windows\Start Menu\Programs\ (no subfolder --
# Win11's flat All-apps list hides subfolders). Also clean up any
# legacy MusicRipper\ subfolder from older installs that used the
# pre-flatten layout.
$startMenuProgs   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$startMenuLnks    = @(
    (Join-Path $startMenuProgs 'MusicRipper - Rip a CD.lnk'),
    (Join-Path $startMenuProgs 'MusicRipper - Uninstall.lnk')
)
$startMenuLegacy  = Join-Path $startMenuProgs 'MusicRipper'
if ($KeepShortcut) {
    Write-Step 'Start Menu shortcuts'
    Write-Skip '-KeepShortcut set; leaving in place.'
} else {
    Write-Step 'Removing Start Menu shortcuts'
    $anyFound = $false
    foreach ($lnk in $startMenuLnks) {
        if (-not (Test-Path -LiteralPath $lnk -PathType Leaf)) { continue }
        $anyFound = $true
        if ($PSCmdlet.ShouldProcess($lnk, 'Remove Start Menu shortcut')) {
            try {
                Remove-Item -LiteralPath $lnk -Force
                Write-Ok "Removed: $lnk"
            } catch {
                Write-Fail "Couldn't remove '$lnk': $($_.Exception.Message)"
                $failures++
            }
        }
    }
    # Legacy subfolder cleanup (pre-flatten installs).
    if (Test-Path -LiteralPath $startMenuLegacy -PathType Container) {
        $anyFound = $true
        if ($PSCmdlet.ShouldProcess($startMenuLegacy, 'Remove legacy Start Menu folder')) {
            try {
                Remove-Item -LiteralPath $startMenuLegacy -Recurse -Force
                Write-Ok "Removed legacy folder: $startMenuLegacy"
            } catch {
                Write-Fail "Couldn't remove legacy folder: $($_.Exception.Message)"
                $failures++
            }
        }
    }
    if (-not $anyFound) {
        Write-Skip 'No Start Menu shortcuts found (already gone, or never installed).'
    }
}


# --- Step 3: Winget packages --------------------------------------------
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
        $failures++
    } else {
        foreach ($id in $packages) {
            $desc = "winget uninstall --exact --id $id"
            Write-Step $desc
            if (-not $PSCmdlet.ShouldProcess($id, 'winget uninstall')) { continue }

            # Picard is typically installed at user scope (Inno Setup
            # default). Try user scope first, then fall back to
            # machine scope. Other packages skip the dance and let
            # winget pick the right scope automatically.
            $scopesToTry = if ($id -eq 'MusicBrainz.Picard') { @('user', 'machine', $null) } else { @($null) }

            $finalRc = $null
            foreach ($scope in $scopesToTry) {
                try {
                    $wingetArgs = @(
                        'uninstall', '--exact', '--id', $id,
                        '--accept-source-agreements', '--silent', '--disable-interactivity'
                    )
                    if ($scope) { $wingetArgs += @('--scope', $scope) }
                    & winget @wingetArgs 2>&1 | Out-Null
                    $finalRc = $LASTEXITCODE
                    # Treat 0 / not-installed / already-target-state as
                    # success-or-better; anything else, try next scope.
                    if ($finalRc -eq 0 -or
                        $finalRc -eq -1978335212 -or       # 0x8A150014 NO_APPLICABLE_INSTALLER
                        $finalRc -eq -1978335189) {        # 0x8A150049 already in target state
                        break
                    }
                } catch {
                    Write-Warn "winget threw for ${id} (scope=$scope): $($_.Exception.Message)"
                    $finalRc = -1
                }
            }

            switch ($finalRc) {
                0           { Write-Ok "$id uninstalled." }
                -1978335212 {
                    # winget says NO_APPLICABLE_INSTALLER. Either it's
                    # genuinely not installed, OR it was installed via
                    # the vendor's own installer (not winget) and
                    # winget can't see the package row. Probe the
                    # standard Programs registry as a fallback.
                    $regHit = $null
                    if ($id -eq 'MusicBrainz.Picard') {
                        $regHit = Find-RipperWindowsUninstaller -DisplayNameLike 'MusicBrainz Picard*'
                    } elseif ($id -eq 'gchudov.CUETools') {
                        $regHit = Find-RipperWindowsUninstaller -DisplayNameLike 'CUETools*'
                    } elseif ($id -eq 'WireGuard.WireGuard') {
                        $regHit = Find-RipperWindowsUninstaller -DisplayNameLike 'WireGuard*'
                    } elseif ($id -eq 'Xiph.FLAC') {
                        $regHit = Find-RipperWindowsUninstaller -DisplayNameLike 'FLAC*'
                    }

                    if (-not $regHit) {
                        Write-Skip "$id was not installed."
                        break
                    }

                    Write-Warn "$id not tracked by winget but found in Programs: '$($regHit.DisplayName)'."
                    # Prefer QuietUninstallString (Inno Setup populates
                    # this with /VERYSILENT etc); fall back to UninstallString.
                    $cmdLine = if ($regHit.QuietUninstallString) {
                        $regHit.QuietUninstallString
                    } else {
                        # Append common silent flags for Inno Setup
                        # (Picard) and MSI. Harmless if the installer
                        # ignores them.
                        "$($regHit.UninstallString) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /quiet"
                    }
                    Write-Step "Running registry uninstaller: $cmdLine"
                    try {
                        # cmd /c so we can pass an entire command line
                        # (UninstallString may include its own quoted args).
                        $regProc = Start-Process -FilePath 'cmd.exe' `
                                                 -ArgumentList @('/c', $cmdLine) `
                                                 -Wait -PassThru -WindowStyle Hidden `
                                                 -ErrorAction Stop
                        $regRc = if ($regProc -and $regProc.PSObject.Properties['ExitCode']) { [int]$regProc.ExitCode } else { 0 }
                        if ($regRc -eq 0) {
                            Write-Ok "$id uninstalled via registry uninstaller."
                        } else {
                            Write-Warn "Registry uninstaller exited $regRc for '$($regHit.DisplayName)'."
                            Write-Warn '  Open Settings -> Apps -> Installed apps to remove by hand if needed.'
                            $failures++
                        }
                    } catch {
                        Write-Fail "Registry uninstaller threw: $($_.Exception.Message)"
                        Write-Warn '  Open Settings -> Apps -> Installed apps to remove by hand.'
                        $failures++
                    }
                }
                -1978335189 { Write-Skip "$id was already in target state." }
                -1978335230 {
                    # 0x8A150042 INSTALLER_PROHIBITS_ELEVATION -- the
                    # per-user installer refuses to run under our
                    # elevated context. Tell the user how to finish.
                    Write-Warn "$id refused to uninstall under elevation (winget rc $finalRc)."
                    Write-Warn "  Open Settings -> Apps -> Installed apps and remove '$id' by hand,"
                    Write-Warn '  or run from a non-elevated pwsh: ' -NoNewline
                    Write-Host  "winget uninstall --exact --id $id --silent" -ForegroundColor White
                    $failures++
                }
                default {
                    Write-Warn "winget exited with code $finalRc for $id (continuing)."
                    $failures++
                }
            }
        }
    }
}


# --- Step 4: User data + parent-mode install dir ------------------------
if ($KeepUserData) {
    Write-Step "User data + install dir ($ripperDataRoot)"
    Write-Skip '-KeepUserData set; leaving in place.'
} elseif (-not (Test-Path -LiteralPath $ripperDataRoot)) {
    Write-Step 'User data + install dir'
    Write-Skip "Not found: $ripperDataRoot  (already gone)."
} else {
    # Self-protection: NEVER delete the directory the running script
    # lives in. That'd yank the rug out from under our own pwsh.
    $repoFull = (Resolve-Path -LiteralPath $repoRoot).ProviderPath.TrimEnd('\').ToLowerInvariant()
    $dataFull = (Resolve-Path -LiteralPath $ripperDataRoot).ProviderPath.TrimEnd('\').ToLowerInvariant()
    if ($repoFull -eq $dataFull -or $repoFull.StartsWith("$dataFull\")) {
        Write-Step "User data + install dir ($ripperDataRoot)"
        Write-Warn "This script is running from '$repoRoot', under the install dir."
        Write-Warn '  Copy Uninstall-MusicRipper.ps1 elsewhere (e.g. your Desktop) and re-run from there.'
        $failures++
    } elseif ($PSCmdlet.ShouldProcess($ripperDataRoot, 'Recursively delete')) {
        Write-Step "Deleting $ripperDataRoot"
        try {
            Remove-Item -LiteralPath $ripperDataRoot -Recurse -Force
            Write-Ok "Removed: $ripperDataRoot"
        } catch {
            Write-Fail "Delete failed: $($_.Exception.Message)"
            Write-Warn "  Some files may be locked (open log file, running pwsh in that tree)."
            $failures++
        }
    }
}


# --- Final summary -------------------------------------------------------
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

# return (NOT exit) so the temp helper's finally{} -> Read-Host -> exit
# sequence can run. When run directly from an already-elevated shell,
# returning to an interactive prompt is also the right behaviour.
if ($failures -gt 0) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
return
