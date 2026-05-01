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

# Require an elevated pwsh. Two reasons:
#   1. WireGuard tunnel uninstall (`/uninstalltunnelservice`) needs admin
#      -- it touches the Service Control Manager.
#   2. Several winget packages (esp. WireGuard.WireGuard) ship MSI / Inno
#      uninstallers that prompt for elevation per-package; pre-elevating
#      means the user gets ONE UAC prompt at launch instead of
#      one-per-package mid-run.
#
# Self-elevation: instead of #Requires -RunAsAdministrator (which just
# bails with a stack-trace-y error), if we detect we're not admin we
# Start-Process pwsh.exe -Verb RunAs and forward every parameter the
# user supplied. UAC prompt fires once, the elevated child runs the
# whole flow, the original (non-elevated) parent exits with the
# child's exit code so $LASTEXITCODE is preserved for callers.

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ShortcutName    = 'Rip a CD',
    [switch] $KeepDependencies,
    [switch] $KeepUserData,
    [switch] $KeepShortcut,
    [switch] $Force,

    # Internal: set by the self-elevation hand-off so the elevated
    # child (which opens in its own console window that would close
    # the moment the script returns) pauses on the final summary so
    # the user can read it. Not documented for human callers.
    [Parameter(DontShow)]
    [switch] $LaunchedFromElevation
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

function Exit-WithPause {
    # Convenience wrapper for clarity at exit sites. The actual pause-
    # before-window-closes happens in the script-scope `finally` block
    # at the bottom (so it covers `exit N`, throws, parser errors,
    # everything). Keeping this helper as a thin pass-through so the
    # exit sites still read clearly.
    param([Parameter(Mandatory)] [int] $Code)
    exit $Code
}


# --- Self-elevate if not admin -------------------------------------------
# Skip if this IS the elevated child (defensive: the child should always
# be admin, but if Start-Process -Verb RunAs landed us in a weird state,
# don't loop trying to re-elevate forever).
if (-not (Test-IsAdministrator) -and -not $LaunchedFromElevation) {
    Write-Host ''
    Write-Host 'MusicRipper uninstaller needs admin -- relaunching elevated...' -ForegroundColor Yellow
    Write-Host '(A UAC prompt will appear. Approve it to continue.)' -ForegroundColor DarkGray

    # Rebuild the original command line so the elevated child runs the
    # same invocation the user typed. $PSBoundParameters captures every
    # explicitly-supplied parameter (defaults are NOT in the dict, so
    # we don't accidentally re-pass them).
    $forwarded = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $name = $kv.Key
        $val  = $kv.Value
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $forwarded += "-$name" }
        } elseif ($val -is [bool]) {
            $forwarded += @("-$name", $(if ($val) { '$true' } else { '$false' }))
        } else {
            # String values containing spaces need to survive the
            # ArgumentList round-trip. Wrap in single quotes (PowerShell
            # parser keeps them literal) and double-up any embedded
            # single quotes per PS quoting rules.
            $escaped = ([string]$val) -replace "'", "''"
            $forwarded += @("-$name", "'$escaped'")
        }
    }
    # Honour -WhatIf even though it's not in $PSBoundParameters when set
    # via $WhatIfPreference (which would happen if the user did
    # 'Set-PSDebug -WhatIf' or imported it). For our use case this is
    # belt-and-suspenders -- the parent's $WhatIfPreference doesn't
    # cross the process boundary.
    if ($WhatIfPreference -and -not $PSBoundParameters.ContainsKey('WhatIf')) {
        $forwarded += '-WhatIf'
    }

    # Quote the script path in case the install dir has spaces.
    $scriptArg = "'$($PSCommandPath -replace "'", "''")'"
    # Tack on -LaunchedFromElevation so the child knows to pause for
    # Read-Host at the end (otherwise the new console window vanishes
    # before the user can read the summary).
    $startArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptArg) + $forwarded + @('-LaunchedFromElevation')

    try {
        # Use pwsh.exe (PS7) explicitly; the script's pipeline expects PS7.
        $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
        $proc = Start-Process -FilePath $pwshExe `
                              -ArgumentList $startArgs `
                              -Verb RunAs `
                              -PassThru `
                              -Wait `
                              -ErrorAction Stop
        # Propagate the elevated child's exit code back to the original
        # caller so scripts wrapping us see the right $LASTEXITCODE.
        # ExitCode can be unreadable for elevated children (the parent
        # doesn't always have rights to query it). Guard via PSObject.
        $rc = 0
        if ($proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
            $rc = [int]$proc.ExitCode
        }
        exit $rc
    } catch [System.ComponentModel.Win32Exception] {
        # Win32 error 1223 = "The operation was canceled by the user"
        # (UAC prompt declined). Tell the user clearly what happened.
        if ($_.Exception.NativeErrorCode -eq 1223) {
            Write-Host ''
            Write-Host 'UAC elevation declined; uninstall aborted.' -ForegroundColor Red
            exit 2
        }
        Write-Host ''
        Write-Host "Could not relaunch elevated: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Open an elevated pwsh manually and re-run this script.' -ForegroundColor DarkGray
        exit 3
    } catch {
        Write-Host ''
        Write-Host "Could not relaunch elevated: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Open an elevated pwsh manually and re-run this script.' -ForegroundColor DarkGray
        exit 3
    }
}


# --- 0. Resolve repo root + lay out paths --------------------------------
# Wrap the entire script body in try/finally so the elevated child
# always pauses before its (auto-launched) console window closes,
# regardless of how it exits -- clean exit, Exit-WithPause, throw,
# uncaught error in winget call, etc. No-op when the script is run
# from an already-elevated shell (the user's terminal stays open
# anyway).
try {
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
    Exit-WithPause -Code 0
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
        Exit-WithPause -Code 0
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

if ($failures -gt 0) { Exit-WithPause -Code 1 } else { Exit-WithPause -Code 0 }
}
finally {
    # Pause-before-window-closes for self-elevated runs. Runs after
    # `exit N` (PowerShell honors finally blocks on exit), after
    # uncaught throws, even after parser errors that happen mid-body.
    # The user always gets to read the success/failure summary.
    if ($LaunchedFromElevation) {
        Write-Host ''
        Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray
        try {
            Read-Host 'Press Enter to close this window'
        } catch {
            # If Read-Host itself throws (rare -- e.g. host doesn't
            # support it) fall back to a sleep so the user still gets
            # a few seconds to read the summary.
            Start-Sleep -Seconds 10
        }
    }
}
