<#
.SYNOPSIS
    Entry point parents click. Phases 1-5: config check, disc-id read,
    MusicBrainz lookup, confirmation dialog, secure rip, quality gate,
    tag + ReplayGain, library/_ReviewQueue placement.

.DESCRIPTION
    Pipeline position:
        Top of the daily-flow sequence:
            ... -> Show-MetadataDialog -> Invoke-Rip ->
            Test-RipQuality -> Write-Tags (library only) ->
            Move-ToLibrary -> Write-RipperReviewTxt +
            New-RipperReviewImage (review queue only) -> eject.

    Current behavior:
        - Loads config; aborts gracefully if missing.
        - If a disc is in the configured drive, reads its TOC
          (Get-RipperDiscId) and queries MusicBrainz
          (Get-RipperDiscMetadata).
        - Pops the Phase 3 confirmation dialog
          (Show-RipperMetadataDialog) so the user can review/edit
          metadata. "Re-search MusicBrainz" wires straight back into
          Get-RipperDiscMetadata.
        - Action='Rip'    -> Phase 4 stub message (no rip yet).
        - Action='Review' -> Phase 5 stub message + ejects.
        - Action='Cancel' -> ejects and exits cleanly.
        - On no-disc / no-match / offline, surfaces the status and
          (where useful) still pops the dialog so the user can choose
          "Send to Review".

.EXAMPLE
    PS> ./src/Start-Ripper.ps1

.NOTES
    Designed to be safe to run with no disc inserted — that path just
    reports "no disc" instead of throwing.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Phase 5.11: minimize the host pwsh window so the WPF dialogs are the
# only user-visible surface. Belt-and-suspenders: the Desktop shortcut
# also sets WindowStyle=7 (Minimized), but elevated launches don't always
# honour it, so we self-minimize here as well. Best-effort -- if the
# Win32 P/Invoke or window handle isn't available (ISE, redirected
# console, future hosts) we just continue.
try {
    if (-not ('MusicRipper.Win32' -as [type])) {
        Add-Type -Namespace MusicRipper -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
'@ | Out-Null
    }
    $hwnd = [MusicRipper.Win32]::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        [void][MusicRipper.Win32]::ShowWindow($hwnd, 6)   # 6 = SW_MINIMIZE
    }
} catch {}

Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force

# Dot-source the Phase 2/3/4/5 core scripts and dialogs so their functions
# are in scope.
. (Join-Path $repoRoot 'src\core\Get-DiscId.ps1')
. (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
. (Join-Path $repoRoot 'src\core\Search-DiscMetadataByText.ps1')
. (Join-Path $repoRoot 'src\core\Invoke-Rip.ps1')
. (Join-Path $repoRoot 'src\core\Test-RipQuality.ps1')
. (Join-Path $repoRoot 'src\core\Write-Tags.ps1')
. (Join-Path $repoRoot 'src\core\Move-ToLibrary.ps1')
. (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')
. (Join-Path $repoRoot 'src\core\New-ReviewQueueArtifacts.ps1')
. (Join-Path $repoRoot 'src\core\Invoke-PostProcess.ps1')
. (Join-Path $repoRoot 'src\core\Resume.ps1')
. (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
. (Join-Path $repoRoot 'src\sync\Invoke-RipperSync.ps1')
. (Join-Path $repoRoot 'src\sync\Sync-ToOneDrive.ps1')
. (Join-Path $repoRoot 'src\sync\Sync-ToSynologyNAS.ps1')
. (Join-Path $repoRoot 'src\sync\Invoke-LibraryRetention.ps1')
. (Join-Path $repoRoot 'src\ui\Show-MetadataDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-RipProgress.ps1')
. (Join-Path $repoRoot 'src\ui\Show-BetweenDiscsDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-DuplicateDiscDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-TargetExistsDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-CredentialDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-RegisterDriveDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-RipperConfigDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-FatalErrorDialog.ps1')

$logPath = Start-RipperLog -Context 'start-ripper'
Write-RipperLog INFO 'Start-Ripper' 'Phase 5 entry: config + disc-id + metadata + confirm + rip + quality/tag/move.'

# Phase 7: top-level safety net. Per-disc errors are caught inside
# Invoke-RipperOneDiscCycle and surfaced via plain MessageBox so the
# rip loop continues. This `trap` catches anything that escapes that
# layer -- startup wiring problems, the resync flow, between-discs
# polish, the WireGuard cleanup blocks, anything in helper-function
# bodies that wasn't try/catch'd. The trap shows the friendly fatal-
# error dialog (Copy-log-path button + Open-log-folder), logs the
# full exception detail, then exits with non-zero so an outer caller
# (Install-MusicRipper, scheduled task, future GUI launcher) can tell
# something went wrong.
#
# Why `trap` instead of a giant try/catch around the script body:
# the body is ~1000 lines spanning helpers, the resync block, the
# disc loop, and exit-time WG cleanup. A trap is a single-statement
# script-scope handler that fires on any uncaught script-terminating
# error, which is exactly the layer we want to handle.
trap {
    $err = $_
    $exception = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { [Exception]$err }
    try {
        Write-RipperLog ERROR 'Start-Ripper' "FATAL: $($exception.GetType().FullName): $($exception.Message)"
        if ($err.ScriptStackTrace) {
            Write-RipperLog ERROR 'Start-Ripper' "Stack: $($err.ScriptStackTrace)"
        }
        if ($exception.StackTrace) {
            Write-RipperLog ERROR 'Start-Ripper' "CLR Stack: $($exception.StackTrace)"
        }
    } catch {
        # Logging itself failed (probably never started). Fall through
        # to the dialog regardless so the user sees something.
    }
    try {
        $activeLog = $null
        try { $activeLog = Get-RipperLogPath } catch {}
        Show-RipperFatalErrorDialog -Exception $exception -LogPath $activeLog
    } catch {
        # WPF dialog itself failed (broken pwsh, missing PresentationFramework).
        # Last-ditch fallback so the parent gets *something*.
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            [System.Windows.Forms.MessageBox]::Show(
                "MusicRipper hit an unrecoverable error and the friendly dialog also failed:`n`n  $($exception.Message)`n`nPlease share %LOCALAPPDATA%\MusicRipper\logs\ with the maintainer.",
                'MusicRipper - fatal error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } catch {}
    }
    try { Stop-RipperLog } catch {}
    exit 1
}

# Phase 5.7: session-scoped state shared across continuous-mode iterations.
# Reset implicitly each Start-Ripper launch (script-scope locals).
#   DiscCount   - 1-based count of disc cycles attempted this session.
#   RippedDiscs - hashtable keyed by DiscId. Value is a human-readable
#                 label ("Artist - Album") captured at end of the rip
#                 cycle, so the duplicate-disc prompt and skip-summary
#                 line can show the album name instead of the opaque
#                 DiscId. Used to prompt "you already ripped this disc
#                 -- rip again or skip?" if the parent re-inserts the
#                 same CD.
#   LastSummary - human-readable outcome of the previous cycle, fed to
#                 the between-discs dialog so the parent can see it
#                 without flipping back to the success message box.
$script:RipperSession = [pscustomobject]@{
    DiscCount   = 0
    RippedDiscs = @{}
    LastSummary = ''
}

# --- Helpers ---------------------------------------------------------------
function Show-RipperInfo([string]$msg, [string]$title = 'MusicRipper', [string]$icon = 'Information') {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($msg, $title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$icon) | Out-Null
}

function Invoke-RipperEject {
    # Best-effort eject of the configured drive. Failure is non-fatal —
    # we just log it and move on (the user can pop it manually).
    if (-not $cfg.DriveLetter) { return }
    try {
        $shell = New-Object -ComObject Shell.Application
        $drive = $shell.Namespace(17).ParseName($cfg.DriveLetter)
        if ($drive) {
            $drive.InvokeVerb('Eject') | Out-Null
            Write-RipperLog INFO 'Start-Ripper' "Ejected $($cfg.DriveLetter)."
        }
    } catch {
        Write-RipperLog WARN 'Start-Ripper' "Eject failed: $($_.Exception.Message)"
    }
}

function Close-RipperTray {
    # Best-effort close of an open tray on the configured drive. Used before
    # the disc-id read so a parent who left the tray hanging open doesn't
    # immediately get a "no disc" error.
    #
    # Why MCI and not Shell.Application: the shell's "Close" verb is
    # unreliable across Windows versions (sometimes hidden, sometimes named
    # differently per locale). `mciSendString` is the Win32-supported way to
    # drive the tray and works regardless of locale.
    #
    # Drive selection: MCI's `!<drive>` selector wants the bare letter (e.g.
    # "D"), not "D:". We strip the colon if present.
    if (-not $cfg.DriveLetter) { return }
    $letter = ($cfg.DriveLetter -replace '[:\\]','').ToUpperInvariant()
    if ($letter.Length -ne 1) { return }

    # Phase 6.5 fix: short-circuit when a disc is already loaded. On some
    # drives, opening the MCI CDAudio device while media is present
    # triggers a re-init that ejects the tray ("door must be closed to
    # begin reading TOC" -> driver helpfully eject-and-recloses). The
    # whole point of Close-RipperTray is to recover from a left-open
    # tray; if [IO.DriveInfo]::IsReady is true we're already past that
    # state and have nothing to do.
    try {
        $di = [System.IO.DriveInfo]::new("${letter}:")
        if ($di.IsReady) {
            Write-RipperLog INFO 'Start-Ripper' "Drive ${letter}: already has a disc loaded; skipping tray-close."
            return
        }
    } catch {
        # Fall through to MCI -- IsReady can throw on weird drive states.
    }

    if (-not ('MusicRipper.Mci' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @'
using System.Runtime.InteropServices;
namespace MusicRipper {
    public static class Mci {
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int mciSendString(
            string lpstrCommand, System.Text.StringBuilder lpstrReturnString,
            int uReturnLength, System.IntPtr hwndCallback);
    }
}
'@
    }

    $alias = "ripper_cd_$letter"
    $rb    = [System.Text.StringBuilder]::new(128)
    try {
        # Open the device (idempotent if already open under another alias).
        [void][MusicRipper.Mci]::mciSendString(
            "open $($cfg.DriveLetter) type CDAudio alias $alias", $rb, 128, [System.IntPtr]::Zero)
        $rc = [MusicRipper.Mci]::mciSendString(
            "set $alias door closed wait", $rb, 128, [System.IntPtr]::Zero)
        [void][MusicRipper.Mci]::mciSendString(
            "close $alias", $rb, 128, [System.IntPtr]::Zero)
        if ($rc -eq 0) {
            Write-RipperLog INFO 'Start-Ripper' "Closed tray on $($cfg.DriveLetter) (or it was already closed)."
        } else {
            Write-RipperLog INFO 'Start-Ripper' "Tray-close on $($cfg.DriveLetter) returned MCI rc=$rc (non-fatal)."
        }
    } catch {
        Write-RipperLog WARN 'Start-Ripper' "Tray-close failed: $($_.Exception.Message)"
    }
}

# --- Config check ----------------------------------------------------------
$configPath = Get-RipperConfigPath
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-RipperLog INFO 'Start-Ripper' "No config at '$configPath' -- launching first-run config editor."
    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    $saved = Show-RipperConfigDialog -FirstRun -ConfigPath $configPath
    if (-not $saved -or -not (Test-Path -LiteralPath $configPath)) {
        Show-RipperInfo "Setup cancelled. MusicRipper needs a config to run.`n`nRe-launch when you're ready to finish setup, or run setup\New-RipperConfig.ps1 from a terminal." `
            'MusicRipper' 'Warning'
        Stop-RipperLog
        return
    }
    Write-RipperLog INFO 'Start-Ripper' "First-run config saved to '$configPath'."
}
$cfg = Import-RipperConfig

# --- Drive check ----------------------------------------------------------
# Phase 6.6.E: if no drive is registered (fresh first-run config, or a
# parent re-saved config without ever picking the drive), pop the config
# editor instead of dumping the user into the rip queue with a "no
# DriveLetter" error every cycle. Re-load $cfg if they save.
#
# Phase 6.6.F.2: don't make a missing drive fatal. A user with no
# optical drive (e.g. a test laptop, a NAS-only retry session) still
# needs to reach the pending-sync flow. If they decline registration
# OR save without picking a drive, we fall through with $skipRipLoop=$true
# -- the startup resync still runs, but the disc loop is skipped.
$skipRipLoop = $false
if (-not $cfg.DriveLetter -or $null -eq $cfg.DriveOffset) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Write-RipperLog INFO 'Start-Ripper' 'No DriveLetter/DriveOffset in config -- prompting to register.'
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "MusicRipper hasn't registered an optical drive yet.`n`n" +
        "  Yes  - open Settings to register one now`n" +
        "  No   - skip for now (you can still re-sync pending albums; ripping will be unavailable)`n" +
        "  Cancel - quit MusicRipper",
        'MusicRipper - drive not configured',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    switch ($ans) {
        ([System.Windows.Forms.DialogResult]::Cancel) {
            Write-RipperLog INFO 'Start-Ripper' 'User cancelled at drive prompt; exiting.'
            Stop-RipperLog
            return
        }
        ([System.Windows.Forms.DialogResult]::No) {
            Write-RipperLog INFO 'Start-Ripper' 'User skipped drive registration; entering no-drive mode (pending-sync only).'
            $skipRipLoop = $true
        }
        ([System.Windows.Forms.DialogResult]::Yes) {
            $saved = $null
            try {
                $saved = Show-RipperConfigDialog -Config $cfg -ConfigPath $configPath
            } catch {
                Write-RipperLog ERROR 'Start-Ripper' "Show-RipperConfigDialog threw: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
                if ($_.ScriptStackTrace) { Write-RipperLog ERROR 'Start-Ripper' "Stack: $($_.ScriptStackTrace)" }
                Show-RipperInfo "The settings editor failed to open:`n`n  $($_.Exception.Message)`n`nSee the log for details." `
                    'MusicRipper' 'Error'
                Stop-RipperLog
                return
            }
            if ($saved) {
                $cfg = Import-RipperConfig
            }
            if (-not $cfg.DriveLetter -or $null -eq $cfg.DriveOffset) {
                Write-RipperLog INFO 'Start-Ripper' 'Still no drive after Settings; entering no-drive mode (pending-sync only).'
                Show-RipperInfo "No drive was registered.`n`nMusicRipper will run in pending-sync mode only -- ripping will be unavailable until a drive is registered." `
                    'MusicRipper' 'Information'
                $skipRipLoop = $true
            } else {
                Write-RipperLog INFO 'Start-Ripper' "Drive registered: $($cfg.DriveLetter) (offset=$($cfg.DriveOffset))."
            }
        }
    }
}

# --- Phase 6.4.1: WireGuard exit-time safety net --------------------------
# Sync-ToSynologyNAS now refcounts the tunnel via Use-RipperVpnTunnel /
# Add-/Remove-RipperVpnTunnelRef, so under normal flow the tunnel is up
# only for the duration of each NAS sync and torn down by the per-sync
# finally. Two things still need a session-exit hook:
#   1. cfg.WireGuardKeepAliveBetweenDiscs=true: we held an extra session
#      ref via Enable-RipperVpnTunnelSessionKeepAlive (env var
#      $env:MUSICRIPPER_WG_SESSION_REF). Drop it on exit.
#   2. Hard crash mid-sync (the per-sync finally never ran): the env
#      var sentinel will still name the tunnel; we stop it defensively.
# Both layers (PowerShell.Exiting engine event + bottom-of-script hook)
# call the same idempotent Disable-RipperVpnTunnelSessionKeepAlive, so
# double-firing is harmless. Window close / Ctrl+C / Quit / clean exit
# all hit at least one of them.
$wgConfName = $null
if ($cfg.PSObject.Properties['WireGuardTunnelName'] -and $cfg.WireGuardTunnelName) {
    $wgConfName = [string]$cfg.WireGuardTunnelName
}
$wgAutoToggle = $true
if ($cfg.PSObject.Properties['WireGuardAutoToggle']) {
    $wgAutoToggle = [bool]$cfg.WireGuardAutoToggle
}
if ($wgAutoToggle -and $wgConfName) {
    # Clear any stale sentinel from a prior session so we only act on
    # tunnels brought up THIS session.
    $env:MUSICRIPPER_WG_SESSION_REF = $null
    # Bake the module path into the engine-event action via string
    # interpolation -- $using: is not supported in
    # Register-EngineEvent -Action and the event runs in its own
    # runspace where $script:repoRoot won't exist.
    $wgModulePath = (Join-Path $repoRoot 'src\lib\Wireguard.psd1') -replace "'", "''"
    $wgActionSrc  = @"
try {
    `$sentinel = `$env:MUSICRIPPER_WG_SESSION_REF
    if (-not [string]::IsNullOrWhiteSpace(`$sentinel)) {
        Import-Module '$wgModulePath' -Force -ErrorAction Stop
        [void](Disable-RipperVpnTunnelSessionKeepAlive -Name `$sentinel)
        # Defensive double-check in case keep-alive was on but no per-
        # sync release ran (hard crash mid-sync) -- stop the service
        # if it's still Running.
        if (Test-RipperVpnTunnel -Name `$sentinel) {
            [void](Stop-RipperVpnTunnel -Name `$sentinel)
        }
        `$env:MUSICRIPPER_WG_SESSION_REF = `$null
    }
} catch {
    # Engine-event handlers can't write to the rip log (it's already
    # torn down); best-effort and swallow.
}
"@
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action ([scriptblock]::Create($wgActionSrc))
}

# --- Dependency check -----------------------------------------------------
# We do this BEFORE any disc work because a missing metaflac.exe would
# only surface AFTER the rip (Phase 5 needs it for tagging + ReplayGain),
# wasting an 11-minute rip. Idempotent flow: if anything is missing,
# offer to run setup/Install-Dependencies.ps1 in-place, then ask the
# user to relaunch. A subsequent launch finds everything and proceeds.
$deps = Test-RipperDependencies
if (-not $deps.Ok) {
    $list   = ($deps.Missing | ForEach-Object { "  - $($_.Name)  (winget id: $($_.WingetId))" }) -join "`n"
    $names  = ($deps.Missing.Name) -join ', '
    Write-RipperLog WARN 'Start-Ripper' "Missing dependencies: $names"

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $rc = [System.Windows.Forms.MessageBox]::Show(
        "MusicRipper needs the following tools, which aren't installed yet:`n`n$list`n`nInstall them now via winget? (you may see an admin elevation prompt)",
        'MusicRipper - Missing Dependencies',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)

    if ($rc -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-RipperLog WARN 'Start-Ripper' 'User declined dependency install.'
        Show-RipperInfo "MusicRipper can't continue without those tools.`n`nRun setup\Install-Dependencies.ps1 manually when ready, then re-launch." `
            'MusicRipper' 'Information'
        Stop-RipperLog
        return
    }

    $installScript = Join-Path $repoRoot 'setup\Install-Dependencies.ps1'
    Write-RipperLog INFO 'Start-Ripper' "Running $installScript"
    try {
        & $installScript
    } catch {
        Write-RipperLog ERROR 'Start-Ripper' "Install-Dependencies failed: $($_.Exception.Message)"
        Show-RipperInfo "Dependency install failed:`n`n  $($_.Exception.Message)`n`nSee log:`n  $logPath" `
            'MusicRipper - Install Failed' 'Error'
        Stop-RipperLog
        return
    }

    Write-RipperLog INFO 'Start-Ripper' 'Dependency installer finished. Asking user to relaunch.'
    Show-RipperInfo "Dependencies installed.`n`nPlease re-launch MusicRipper to continue." `
        'MusicRipper' 'Information'
    Stop-RipperLog
    return
}

# --- Resume orphaned rips --------------------------------------------------
# Any folder under <LibraryRoot>\_inbox\ that still has _ripper-state.json
# is a rip whose post-process never finished (crash, power loss, manual exit
# between Invoke-Rip and Invoke-RipperPostProcess, or a "target already
# exists" throw that left the rip stranded). Offer to finish them now
# before touching the drive — running the disc-id step would be wasted work
# if the user wants to bail out and recover by hand instead.
#
# Phase 5.11: factored into Invoke-RipperResumeOrphans so the continuous-
# mode loop can re-run it between cycles (a stranded rip from cycle N
# should be offered for resume before cycle N+1 starts, not held until
# the next launch).
function Invoke-RipperResumeOrphans {
    [CmdletBinding()]
    [OutputType([string])]   # returns 'Continue' or 'Quit'
    param([switch]$Quiet)

    $orphans = @(Find-RipperOrphanedRips -LibraryRoot $cfg.LibraryRoot)
    if ($orphans.Count -eq 0) {
        if (-not $Quiet) { Write-RipperLog INFO 'Start-Ripper' 'No orphaned rips found.' }
        return 'Continue'
    }

    $names = ($orphans | ForEach-Object { "  - $(Split-Path -Leaf $_.Folder)" }) -join "`n"
    Write-RipperLog INFO 'Start-Ripper' "Found $($orphans.Count) orphaned rip(s)."

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $rc = [System.Windows.Forms.MessageBox]::Show(
        "MusicRipper found $($orphans.Count) unfinished rip(s) in your inbox:`n`n$names`n`nFinish them now? (Tag, ReplayGain, and move to your library / review queue.)`n`nYes = process them all`nNo  = skip and continue with today's disc`nCancel = quit",
        'MusicRipper - Resume Unfinished Rips',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)

    if ($rc -eq [System.Windows.Forms.DialogResult]::Cancel) {
        Write-RipperLog INFO 'Start-Ripper' 'User cancelled at orphan-resume prompt.'
        return 'Quit'
    }
    if ($rc -eq [System.Windows.Forms.DialogResult]::Yes) {
        $resumeFails = @()
        foreach ($orphan in $orphans) {
            try {
                $rpp = Resume-RipperOrphan -RipFolder $orphan.Folder -LibraryRoot $cfg.LibraryRoot -Config $cfg
                Write-RipperLog INFO 'Start-Ripper' "Resumed orphan -> $($rpp.Target)"
            } catch {
                # Phase 5.11: detect "target already exists" so the user
                # can interactively recover (Keep both / Review / Discard /
                # Leave) instead of getting a passive warning. PowerShell's
                # `throw` rewraps the IOException as RuntimeException and
                # drops .Data, so we match on the (stable) message text and
                # parse the path off it -- falling back to the Data marker
                # for direct callers that managed to preserve it.
                $msg            = [string]$_.Exception.Message
                $existingTarget = $null
                $cur = $_.Exception
                while ($cur) {
                    if ($cur.Data -and $cur.Data.Contains('TargetExists')) {
                        $existingTarget = [string]$cur.Data['TargetExists']; break
                    }
                    $cur = $cur.InnerException
                }
                if (-not $existingTarget -and $msg -match '^Target directory already exists\b.*?:\s*(.+)$') {
                    $existingTarget = $matches[1].Trim()
                }

                if ($existingTarget) {
                    Write-RipperLog WARN 'Start-Ripper' "Orphan resume blocked: target exists at '$existingTarget'. Prompting user."
                    $orphanLabel = Split-Path -Leaf $orphan.Folder
                    try {
                        $st = Read-RipperRipState -RipFolder $orphan.Folder
                        if ($st -and $st.Metadata) {
                            $orphanLabel = "$($st.Metadata.AlbumArtist) - $($st.Metadata.Album)"
                        }
                    } catch {}

                    $oChoice = Show-RipperTargetExistsDialog `
                        -AlbumLabel       $orphanLabel `
                        -ExistingPath     $existingTarget `
                        -StrandedRipPath  $orphan.Folder
                    Write-RipperLog INFO 'Start-Ripper' "Orphan target-exists dialog: Action=$($oChoice.Action)"

                    switch ($oChoice.Action) {
                        { $_ -in 'SideBySide','Review' } {
                            try {
                                $rpp = Resume-RipperOrphan `
                                    -RipFolder         $orphan.Folder `
                                    -LibraryRoot       $cfg.LibraryRoot `
                                    -AllowSideBySide:($oChoice.Action -eq 'SideBySide') `
                                    -ForceReviewQueue:($oChoice.Action -eq 'Review') `
                                    -Config            $cfg
                                Write-RipperLog INFO 'Start-Ripper' "Orphan recovery succeeded ($($oChoice.Action)) -> $($rpp.Target)"
                            } catch {
                                Write-RipperLog ERROR 'Start-Ripper' "Orphan recovery ($($oChoice.Action)) failed: $($_.Exception.Message)"
                                $resumeFails += [pscustomobject]@{ Folder = $orphan.Folder; Error = $_.Exception.Message }
                            }
                        }
                        'Discard' {
                            try {
                                Move-RipperFolderToRecycleBin -Path $orphan.Folder
                                Write-RipperLog INFO 'Start-Ripper' "Discarded orphan to Recycle Bin: $($orphan.Folder)"
                            } catch {
                                Write-RipperLog ERROR 'Start-Ripper' "Orphan discard failed: $($_.Exception.Message)"
                                $resumeFails += [pscustomobject]@{ Folder = $orphan.Folder; Error = "Discard failed: $($_.Exception.Message)" }
                            }
                        }
                        default {
                            Write-RipperLog INFO 'Start-Ripper' "Left orphan in inbox: $($orphan.Folder)"
                        }
                    }
                } else {
                    Write-RipperLog ERROR 'Start-Ripper' "Resume failed for $($orphan.Folder): $($_.Exception.Message)"
                    $resumeFails += [pscustomobject]@{ Folder = $orphan.Folder; Error = $_.Exception.Message }
                }
            }
        }
        if ($resumeFails.Count -gt 0) {
            $failList = ($resumeFails | ForEach-Object { "  - $(Split-Path -Leaf $_.Folder): $($_.Error)" }) -join "`n"
            Show-RipperInfo "Some orphan rips could not be finished:`n`n$failList`n`nThe sidecars are still in place — try again next disc / launch, or use src\tools\Complete-OrphanedRip.ps1." `
                'MusicRipper - Resume Issues' 'Warning'
        }
    } else {
        Write-RipperLog INFO 'Start-Ripper' 'User chose to skip orphan resume.'
    }
    return 'Continue'
}

if ((Invoke-RipperResumeOrphans) -eq 'Quit') {
    Stop-RipperLog
    return
}

# --- Per-disc cycle (Phase 5.7) -------------------------------------------
# Returns a [pscustomobject] with:
#   Outcome  -- 'Completed' | 'Cancelled' | 'NoDisc' | 'Failed' | 'Skipped'
#   Summary  -- short multi-line summary fed to the between-discs dialog
# Never throws; per-disc failures end with a message box and return so the
# outer loop can show the next-disc prompt instead of the script crashing.
function Invoke-RipperOneDiscCycle {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $script:RipperSession.DiscCount++
    $cycleNum = $script:RipperSession.DiscCount

    function _result([string]$Outcome, [string]$Summary) {
        [pscustomobject]@{ Outcome = $Outcome; Summary = $Summary }
    }

    function _maybeEject($Choice) {
        # Honour the per-rip eject decision the user just made in the dialog
        # (seeded from cfg.EjectAfterRip but flippable via the checkbox).
        if ($Choice -and $Choice.PSObject.Properties['EjectAfterRip'] -and -not $Choice.EjectAfterRip) {
            Write-RipperLog INFO 'Start-Ripper' 'Skipping eject (per-rip checkbox unchecked).'
            return
        }
        Invoke-RipperEject
    }

    # --- Read disc ---------------------------------------------------------
    # If the tray was left open, close it first so the user doesn't get an
    # immediate "no disc" error. After a close, the drive needs a beat to spin
    # up and report the TOC, so we retry a few times on transient "not ready"
    # errors before giving up.
    Close-RipperTray

    $disc          = $null
    $lastDiscError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $disc = Get-RipperDiscId
            break
        } catch {
            $lastDiscError = $_
            $msg = $_.Exception.Message
            if ($msg -match 'not ready|medium not present|tray open|no disc') {
                Write-RipperLog INFO 'Start-Ripper' "Drive not ready (attempt $attempt/5); waiting for spin-up."
                Start-Sleep -Seconds 2
                continue
            }
            # Non-transient error: don't burn retries on it.
            break
        }
    }

    if (-not $disc) {
        $errMsg = if ($lastDiscError) { $lastDiscError.Exception.Message } else { 'unknown' }
        Write-RipperLog WARN 'Start-Ripper' "Disc-id failed: $errMsg"
        Show-RipperInfo "No disc / drive error:`n`n  $errMsg`n`nInsert a CD and try again." `
            'MusicRipper' 'Warning'
        return _result 'NoDisc' "Disc ${cycleNum}: no disc / drive error -- $errMsg"
    }

    # --- Already-in-library check (Phase 5.8) ----------------------------
    # Look the disc up in the durable cross-session DiscId index FIRST. If
    # we find a hit (and the recorded folder still exists), give the parent
    # a polished three-way prompt instead of silently re-ripping or
    # crashing later in Move-RipToLibrary's "target exists" throw. The
    # library dialog supersedes the in-session Yes/No prompt below: a
    # library hit always implies an in-session hit (if the user already
    # ripped it this session), and the library dialog is strictly more
    # informative (Open folder, RippedAt, side-by-side option).
    #
    # If they choose 'RipAgain' we set $allowSideBySide so post-process
    # routes the new copy to '<Album> (<Year>) [rip 2]' instead of
    # colliding with the original.
    $allowSideBySide = $false
    try {
        $libDup = Find-RipperLibraryDiscIndexEntry -LibraryRoot $cfg.LibraryRoot -DiscId $disc.DiscId
    } catch {
        Write-RipperLog WARN 'Start-Ripper' "DiscId index lookup failed (advisory): $($_.Exception.Message)"
        $libDup = $null
    }
    if ($libDup) {
        $libLabel = if ($libDup.PSObject.Properties['Label'] -and $libDup.Label) { [string]$libDup.Label } else { "DiscId $($disc.DiscId)" }
        $libPath  = [string]$libDup.Path
        $libRipAt = if ($libDup.PSObject.Properties['RippedAt']) { $libDup.RippedAt } else { $null }
        $libSrc   = if ($libDup.PSObject.Properties['Source']) { [string]$libDup.Source } else { 'library' }
        # When the recorded path no longer exists on disk (recycled by
        # LocalRetention, OR the user manually moved/deleted the album
        # after sync vouched for it -- D-022) suppress the path line
        # and Open-folder button. The dialog shows a small note instead.
        $dialogPath = if (Test-Path -LiteralPath $libPath) { $libPath } else { '' }
        Write-RipperLog INFO 'Start-Ripper' "DiscId $($disc.DiscId) already in library: $libLabel ($libPath, source=$libSrc)."
        $dup = Show-RipperDuplicateDiscDialog -AlbumLabel $libLabel -AlbumPath $dialogPath -RippedAt $libRipAt
        switch ($dup.Action) {
            'Skip' {
                Write-RipperLog INFO 'Start-Ripper' "User skipped already-in-library disc: $libLabel."
                Invoke-RipperEject
                return _result 'Skipped' "Disc ${cycleNum}: skipped (already in library: $libLabel)"
            }
            'RipAgain' {
                Write-RipperLog INFO 'Start-Ripper' "User chose to re-rip already-in-library disc side-by-side: $libLabel."
                $allowSideBySide = $true
            }
            default {
                # Defensive: future actions land here. Treat as Skip.
                Write-RipperLog WARN 'Start-Ripper' "Duplicate-disc dialog returned unknown action '$($dup.Action)'; treating as Skip."
                Invoke-RipperEject
                return _result 'Skipped' "Disc ${cycleNum}: skipped (already in library: $libLabel)"
            }
        }
    }

    # --- Already-ripped-this-session fallback (Phase 5.7) ----------------
    # Library check above is the primary duplicate guard. This fallback
    # catches discs ripped this session that never made it to the library
    # (e.g., routed to ReviewQueue, or move-to-library failed) and so are
    # absent from the DiscId index. Skip if the library dialog already
    # handled this disc.
    if (-not $libDup -and $script:RipperSession.RippedDiscs.ContainsKey($disc.DiscId)) {
        $priorLabel = $script:RipperSession.RippedDiscs[$disc.DiscId]
        # Old sessions stored $true; treat any non-string as unknown.
        if (-not ($priorLabel -is [string]) -or [string]::IsNullOrWhiteSpace($priorLabel)) {
            $priorLabel = "DiscId $($disc.DiscId)"
        }
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $rc = [System.Windows.Forms.MessageBox]::Show(
            "You already ripped this disc earlier in this session.`n`n  $priorLabel`n`nRip it again? (Yes = re-rip, No = skip and return to the disc-insert prompt.)",
            'MusicRipper - Already Ripped This Session',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($rc -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-RipperLog INFO 'Start-Ripper' "Skipping re-rip of already-seen disc: $priorLabel (DiscId $($disc.DiscId))."
            Invoke-RipperEject
            return _result 'Skipped' "Disc ${cycleNum}: skipped (already ripped this session: $priorLabel)"
        }
        Write-RipperLog INFO 'Start-Ripper' "User chose to re-rip already-seen disc: $priorLabel (DiscId $($disc.DiscId))."
    }

    # --- Metadata lookup ---------------------------------------------------
    try {
        $meta = Get-RipperDiscMetadata -DiscIdInfo $disc
    } catch {
        Write-RipperLog WARN 'Start-Ripper' "Metadata failed: $($_.Exception.Message)"
        # Synthesize an Offline-style result so the dialog still comes up and
        # the user can route to Review.
        $meta = [pscustomobject]@{
            DiscId     = $disc.DiscId
            Status     = 'Offline'
            BestMatch  = $null
            Candidates = @()
        }
    }

    # --- Phase 3: confirmation dialog -------------------------------------
    $onResearch = {
        Write-RipperLog INFO 'Start-Ripper' "Re-search MusicBrainz requested for $($disc.DiscId)."
        Get-RipperDiscMetadata -DiscIdInfo $disc
    }.GetNewClosure()

    # Pull the cover-art chain across each text-search hit so the dialog
    # can render an image once the user picks one. Failures are non-fatal
    # (same convention as the disc-id flow): the picked candidate just
    # shows up without a cover.
    #
    # Two-tier strategy:
    #   1. iTunes/Deezer text-search candidates carry an .ArtworkUrl from
    #      their original metadata response (the same response that gave us
    #      the artist/album/tracks). One HTTP GET fetches the bytes -- no
    #      AlbumArtist+Album guesswork needed, which is critical for
    #      compilations and multi-artist titles where the re-query would
    #      miss.
    #   2. Anything without an .ArtworkUrl (MusicBrainz, GnuDB) falls
    #      through to the full Get-RipperBestCoverArt provider chain.
    $onTextSearch = {
        param($payload)
        Write-RipperLog INFO 'Start-Ripper' "Text-search requested: artist='$($payload.Artist)' album='$($payload.Album)' year=$($payload.Year) providers=$(@($payload.Providers) -join ',')"
        $r = Search-RipperMetadataByText `
                -Artist    $payload.Artist `
                -Album     $payload.Album `
                -Year      $payload.Year `
                -Providers @($payload.Providers)
        if ($r -and $r.Candidates) {
            foreach ($c in @($r.Candidates)) {
                $bytes = $null
                $directUrl = if (($c.PSObject.Properties.Name -contains 'ArtworkUrl') -and $c.ArtworkUrl) {
                    [string]$c.ArtworkUrl
                } else { $null }
                if ($directUrl) {
                    try {
                        $tmp = [System.IO.Path]::GetTempFileName()
                        try {
                            Invoke-WebRequest -Uri $directUrl -OutFile $tmp -TimeoutSec 30 -UseBasicParsing | Out-Null
                            $bytes = [System.IO.File]::ReadAllBytes($tmp)
                            Write-RipperLog INFO 'Start-Ripper' "Cover-art (direct, $($c.Source)): $($bytes.Length) bytes from $directUrl"
                        } finally {
                            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-RipperLog WARN 'Start-Ripper' "Cover-art direct fetch failed for $($c.Source) '$($c.Album)': $($_.Exception.Message)"
                        $bytes = $null
                    }
                }
                if (-not $bytes) {
                    try {
                        $bytes = Get-RipperBestCoverArt -Candidate $c
                    } catch {
                        $bytes = $null
                    }
                }
                $c | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue $bytes -Force
            }
        }
        $r
    }

    $textSearchProviders = @(Get-RipperTextSearchProviderNames)

    # Phase 5.3: "Change cover..." picker. Runs every configured provider
    # (not short-circuit like Get-RipperBestCoverArt) so the user can
    # compare all available images side-by-side.
    $onPickCover = {
        param($candidate)
        Write-RipperLog INFO 'Start-Ripper' "Cover-picker requested for '$($candidate.AlbumArtist) / $($candidate.Album)'."
        Get-RipperCoverArtCandidates -Candidate $candidate
    }

    $choice = Show-RipperMetadataDialog `
                -Metadata             $meta `
                -OnResearch           $onResearch `
                -OnTextSearch         $onTextSearch `
                -TextSearchProviders  $textSearchProviders `
                -OnPickCover          $onPickCover `
                -EjectAfterRip        ($(if ($cfg.PSObject.Properties['EjectAfterRip']) { [bool]$cfg.EjectAfterRip } else { $true }))

    Write-RipperLog INFO 'Start-Ripper' "User chose: $($choice.Action) (eject=$($choice.EjectAfterRip))."

    switch ($choice.Action) {
        { $_ -in 'Rip','Review' } {
            $m = $choice.Metadata

            # Phase 5.9: 'Review' runs the full rip pipeline but routes the
            # finished folder into _ReviewQueue\ regardless of rip quality
            # (and skips library tagging) so the user can fix metadata in
            # Picard before promoting it. The route is just a flag passed
            # to Invoke-RipperPostProcess; everything else (rip, sidecar,
            # eject, summary dialog, in-session tracking) is identical.
            $forceReviewQueue = ($choice.Action -eq 'Review')
            if ($forceReviewQueue) {
                Write-RipperLog INFO 'Start-Ripper' "User chose Send to Review: $($m.AlbumArtist) - $($m.Album)"
            }

            # Phase 4 rips land in <LibraryRoot>\_inbox\<AlbumArtist> - <Album>\.
            # Phase 5's Move-ToLibrary will relocate from there to the Plex
            # layout (or _ReviewQueue\) once rip quality is known. Keeping the
            # staging area under LibraryRoot keeps everything on one volume so
            # the move is a rename (fast), not a copy.
            $inboxRoot = Join-Path $cfg.LibraryRoot '_inbox'
            if (-not (Test-Path -LiteralPath $inboxRoot)) {
                New-Item -ItemType Directory -Path $inboxRoot -Force | Out-Null
            }

            Write-RipperLog INFO 'Start-Ripper' `
                "Starting rip: $($m.AlbumArtist) - $($m.Album) -> $inboxRoot"

            # Phase 6.2.C: bundle the happy-path post-process call into
            # a scriptblock that runs INSIDE the rip-progress window's
            # background runspace. The window stays open and surfaces a
            # live status line ("Tagging FLAC files...", "Syncing to
            # OneDrive...") to the parent-user even while the host is
            # minimized. Recovery paths (TargetExists, post-process
            # failure) keep their existing synchronous flow below --
            # they're rare and need user dialogs anyway.
            $ppContext = @{
                LibraryRoot      = $cfg.LibraryRoot
                Metadata         = $m
                DiscId           = $disc.DiscId
                AllowSideBySide  = [bool]$allowSideBySide
                ForceReviewQueue = [bool]$forceReviewQueue
                Config           = $cfg
                RepoRoot         = $repoRoot
            }
            $ppAction = {
                param($state, $rip, $ctx)
                Set-StrictMode -Version 3.0
                $ErrorActionPreference = 'Stop'
                # Re-import in this runspace -- the parent runspace's
                # function table doesn't follow scriptblocks across the
                # boundary (see Show-RipProgress header note).
                . (Join-Path $ctx.RepoRoot 'src\sync\Get-LibrarySyncState.ps1')
                . (Join-Path $ctx.RepoRoot 'src\sync\Invoke-RipperSync.ps1')
                . (Join-Path $ctx.RepoRoot 'src\sync\Sync-ToOneDrive.ps1')
                . (Join-Path $ctx.RepoRoot 'src\sync\Sync-ToSynologyNAS.ps1')
                . (Join-Path $ctx.RepoRoot 'src\sync\Invoke-LibraryRetention.ps1')
                . (Join-Path $ctx.RepoRoot 'src\core\Test-RipQuality.ps1')
                . (Join-Path $ctx.RepoRoot 'src\core\Write-Tags.ps1')
                . (Join-Path $ctx.RepoRoot 'src\core\Move-ToLibrary.ps1')
                . (Join-Path $ctx.RepoRoot 'src\core\Get-LibraryDiscIndex.ps1')
                . (Join-Path $ctx.RepoRoot 'src\core\New-ReviewQueueArtifacts.ps1')
                . (Join-Path $ctx.RepoRoot 'src\core\Invoke-PostProcess.ps1')
                . (Join-Path $ctx.RepoRoot 'src\core\Resume.ps1')
                # Drop the resume sidecar BEFORE running post-process so
                # a crash mid-tag leaves the next launch enough
                # breadcrumbs to finish the job. Best-effort.
                $state['PostProcessStatus'] = 'Writing resume sidecar...'
                try {
                    $coverLeaf = if ($rip.CoverArtFile) { Split-Path -Leaf $rip.CoverArtFile } else { $null }
                    Write-RipperRipState `
                        -RipFolder        $rip.OutputDir `
                        -DiscId           $ctx.DiscId `
                        -Metadata         $ctx.Metadata `
                        -LogFileName      (Split-Path -Leaf $rip.LogFile) `
                        -CoverArtFileName $coverLeaf | Out-Null
                } catch {
                    # Swallow -- sidecar is advisory; post-process is the
                    # source of truth.
                }
                $cb = { param([string]$msg) $state['PostProcessStatus'] = $msg }.GetNewClosure()
                $progCb = {
                    param([double]$frac, [int]$tagCur, [int]$tagTot)
                    $state['PostProcessOverallFraction'] = $frac
                    $state['PostProcessTagCurrent']      = $tagCur
                    $state['PostProcessTagTotal']        = $tagTot
                }.GetNewClosure()
                Invoke-RipperPostProcess `
                    -RipFolder         $rip.OutputDir `
                    -LogFile           $rip.LogFile `
                    -Metadata          $ctx.Metadata `
                    -DiscId            $ctx.DiscId `
                    -LibraryRoot       $ctx.LibraryRoot `
                    -CoverArtFile      $rip.CoverArtFile `
                    -AllowSideBySide:$ctx.AllowSideBySide `
                    -ForceReviewQueue:$ctx.ForceReviewQueue `
                    -Config            $ctx.Config `
                    -StatusCallback    $cb `
                    -ProgressCallback  $progCb
            }

            try {
                $progressOut = Show-RipperRipProgress `
                    -DiscIdInfo $disc `
                    -Metadata $m `
                    -OutputRoot $inboxRoot `
                    -ContactNetwork $true `
                    -PostProcessAction $ppAction `
                    -PostProcessContext $ppContext
            } catch {
                Write-RipperLog ERROR 'Start-Ripper' "Rip threw: $($_.Exception.Message)"
                Show-RipperInfo "Rip failed:`n`n  $($_.Exception.Message)`n`nSee log:`n  $(Get-RipperLogPath)" `
                    'MusicRipper - Rip Failed' 'Error'
                _maybeEject $choice
                return _result 'Failed' "Disc ${cycleNum}: $($m.AlbumArtist) - $($m.Album) -- rip threw: $($_.Exception.Message)"
            }

            if (-not $progressOut) {
                # Progress window closed before the rip started -- rare but
                # survivable. Treat like a cancel.
                Write-RipperLog WARN 'Start-Ripper' 'Rip returned $null (window closed early).'
                _maybeEject $choice
                return _result 'Cancelled' "Disc ${cycleNum}: $($m.AlbumArtist) - $($m.Album) -- progress window closed early"
            }

            # Show-RipperRipProgress returns either the bare rip result
            # (legacy callers, no -PostProcessAction) or
            # @{ Rip = ...; PostProcess = ...; PostProcessError = ... }.
            # We always pass -PostProcessAction so destructure the latter.
            if ($progressOut -is [hashtable] -or $progressOut -is [pscustomobject]) {
                if ($progressOut.PSObject.Properties['Rip']) {
                    $result          = $progressOut.Rip
                    $ppFromProgress  = $progressOut.PostProcess
                    $ppErrFromWindow = $progressOut.PostProcessError
                } else {
                    $result          = $progressOut
                    $ppFromProgress  = $null
                    $ppErrFromWindow = $null
                }
            } else {
                $result          = $progressOut
                $ppFromProgress  = $null
                $ppErrFromWindow = $null
            }

            Write-RipperLog INFO 'Start-Ripper' `
                "Rip finished: Status=$($result.Status) FailedSectors=$($result.FailedSectors) Output=$($result.OutputDir)"

            # --- Phase 5: quality gate -> tag -> move -> review artifacts -
            # Only run the post-rip pipeline on rips that actually produced
            # output. Cancelled/Failed rips fall through to the user dialog
            # without further processing.
            $phase5Target  = $null
            $phase5Quality = $null
            if ($result.Status -ne 'Cancelled' -and $result.Status -ne 'Failed') {
                # Phase 6.2.C: post-process (sidecar + Invoke-RipperPostProcess)
                # already ran inside Show-RipperRipProgress's runspace so
                # the user saw live status. Outcomes:
                #   $ppFromProgress  != $null   -- happy path; same shape
                #                                  Invoke-RipperPostProcess returns.
                #   $ppErrFromWindow != $null   -- post-process threw;
                #                                  re-enter the same recovery
                #                                  flow that has always handled
                #                                  TargetExists / generic errors.
                #   both null                   -- shouldn't happen for a
                #                                  Verified/ProbablyGood rip,
                #                                  but treat as generic failure.
                if ($ppFromProgress -and -not $ppErrFromWindow) {
                    $pp = $ppFromProgress
                    $phase5Quality = $pp.Quality
                    $phase5Target  = $pp.Target
                    try { Remove-RipperRipState -RipFolder $pp.Target } catch {
                        Write-RipperLog WARN 'Start-Ripper' "Sidecar cleanup failed: $($_.Exception.Message)"
                    }
                } else {
                    # Synthesize the same throw-and-catch shape the legacy
                    # path used so the recovery code below stays untouched.
                    try {
                        if ($ppErrFromWindow) { throw $ppErrFromWindow } else {
                            throw "Post-process did not run (window closed early?)"
                        }
                    } catch {
                    # Phase 5.11: detect "target already exists" so we can
                    # offer the user an interactive recovery dialog instead
                    # of dumping the stranded rip in _inbox\.
                    #
                    # Move-RipToLibrary tags Exception.Data['TargetExists']
                    # with the resolved target path, but PowerShell's `throw`
                    # rewraps script-thrown exceptions as RuntimeException and
                    # drops .Data / .InnerException. We therefore detect via
                    # the (stable) message text and parse the path off it,
                    # falling back to the Data marker for direct callers.
                    $msg            = [string]$_.Exception.Message
                    $existingTarget = $null
                    $cur = $_.Exception
                    while ($cur) {
                        if ($cur.Data -and $cur.Data.Contains('TargetExists')) {
                            $existingTarget = [string]$cur.Data['TargetExists']; break
                        }
                        $cur = $cur.InnerException
                    }
                    if (-not $existingTarget -and $msg -match '^Target directory already exists\b.*?:\s*(.+)$') {
                        $existingTarget = $matches[1].Trim()
                    }

                    if ($existingTarget) {
                        Write-RipperLog WARN 'Start-Ripper' "Move blocked: target exists at '$existingTarget'. Prompting user."
                        $albumLabel = "$($m.AlbumArtist) - $($m.Album)"
                        $choice2 = Show-RipperTargetExistsDialog `
                            -AlbumLabel       $albumLabel `
                            -ExistingPath     $existingTarget `
                            -StrandedRipPath  $result.OutputDir
                        Write-RipperLog INFO 'Start-Ripper' "Target-exists dialog: Action=$($choice2.Action)"

                        switch ($choice2.Action) {
                            { $_ -in 'SideBySide','Review' } {
                                # Re-run post-process with the appropriate
                                # override. Swallow a second "target exists"
                                # only for SideBySide (shouldn't happen --
                                # >= 99 copies); Review always lands in
                                # _ReviewQueue\ which uses unique disc-id-
                                # suffixed folders.
                                try {
                                    $pp = Invoke-RipperPostProcess `
                                        -RipFolder        $result.OutputDir `
                                        -LogFile          $result.LogFile `
                                        -Metadata         $m `
                                        -DiscId           $disc.DiscId `
                                        -LibraryRoot      $cfg.LibraryRoot `
                                        -CoverArtFile     $result.CoverArtFile `
                                        -AllowSideBySide:($choice2.Action -eq 'SideBySide') `
                                        -ForceReviewQueue:($choice2.Action -eq 'Review') `
                                        -Config           $cfg
                                    $phase5Quality = $pp.Quality
                                    $phase5Target  = $pp.Target
                                    try { Remove-RipperRipState -RipFolder $pp.Target } catch {
                                        Write-RipperLog WARN 'Start-Ripper' "Sidecar cleanup failed: $($_.Exception.Message)"
                                    }
                                    Write-RipperLog INFO 'Start-Ripper' "Recovery succeeded ($($choice2.Action)) -> $phase5Target"
                                } catch {
                                    Write-RipperLog ERROR 'Start-Ripper' "Recovery ($($choice2.Action)) failed: $($_.Exception.Message)"
                                    Show-RipperInfo "Recovery attempt failed:`n`n  $($_.Exception.Message)`n`nThe raw rip is still at:`n  $($result.OutputDir)`n`nMusicRipper will offer to resume it next disc / launch." `
                                        'MusicRipper - Recovery Failed' 'Warning'
                                    _maybeEject $choice
                                    return _result 'Failed' "Disc ${cycleNum}: $albumLabel -- recovery failed: $($_.Exception.Message)"
                                }
                            }
                            'Discard' {
                                try {
                                    Move-RipperFolderToRecycleBin -Path $result.OutputDir
                                    Write-RipperLog INFO 'Start-Ripper' "Discarded stranded rip to Recycle Bin: $($result.OutputDir)"
                                    Show-RipperInfo "The new rip was moved to the Recycle Bin.`n`nThe existing album in your library was not touched." `
                                        'MusicRipper' 'Information'
                                } catch {
                                    Write-RipperLog ERROR 'Start-Ripper' "Discard failed: $($_.Exception.Message)"
                                    Show-RipperInfo "Could not move the rip to the Recycle Bin:`n`n  $($_.Exception.Message)`n`nThe rip is still at:`n  $($result.OutputDir)" `
                                        'MusicRipper - Discard Failed' 'Warning'
                                }
                                _maybeEject $choice
                                return _result 'Skipped' "Disc ${cycleNum}: $albumLabel -- discarded (already in library)"
                            }
                            default {
                                # Leave: the sidecar is in place; orphan
                                # rescan (between cycles or next launch)
                                # will offer to resume.
                                Write-RipperLog INFO 'Start-Ripper' "Left stranded rip in inbox: $($result.OutputDir)"
                                Show-RipperInfo "The new rip is still at:`n`n  $($result.OutputDir)`n`nMusicRipper will offer to finish it before the next disc (or on next launch)." `
                                    'MusicRipper' 'Information'
                                _maybeEject $choice
                                return _result 'Skipped' "Disc ${cycleNum}: $albumLabel -- left in _inbox (already in library)"
                            }
                        }
                    } else {
                        Write-RipperLog ERROR 'Start-Ripper' "Phase 5 pipeline failed: $($_.Exception.Message)"
                        Show-RipperInfo "Rip succeeded but post-processing failed:`n`n  $($_.Exception.Message)`n`nThe raw rip is still at:`n  $($result.OutputDir)`n`nSee log:`n  $(Get-RipperLogPath)" `
                            'MusicRipper - Post-Processing Failed' 'Warning'
                        _maybeEject $choice
                        return _result 'Failed' "Disc ${cycleNum}: $($m.AlbumArtist) - $($m.Album) -- post-process failed: $($_.Exception.Message)"
                    }
                }
                }
            }

            switch ($result.Status) {
                'Cancelled' {
                    Show-RipperInfo "Rip cancelled. Partial files were removed." `
                        'MusicRipper' 'Information'
                    $summary = "Disc ${cycleNum}: $($m.AlbumArtist) - $($m.Album) -- cancelled"
                }
                'Failed' {
                    $err = ($result.Errors -join "`n  ")
                    Show-RipperInfo "Rip failed.`n`n  $err`n`nSee log:`n  $(Get-RipperLogPath)" `
                        'MusicRipper - Rip Failed' 'Error'
                    $summary = "Disc ${cycleNum}: $($m.AlbumArtist) - $($m.Album) -- failed: $err"
                }
                default {
                    $ar    = $result.AccurateRip
                    $ctdb  = $result.Ctdb
                    $destLine = if ($phase5Target) {
                        $kind = if ($phase5Quality -and $phase5Quality.Destination -eq 'ReviewQueue') { 'Review queue' } else { 'Library' }
                        "${kind}: $phase5Target"
                    } else {
                        "Output: $($result.OutputDir)"
                    }
                    $lines = @(
                        "Status: $($result.Status)"
                        ""
                        "  $($m.AlbumArtist) - $($m.Album)"
                        "  $($m.TrackCount) track(s) - $([int][Math]::Round($result.ElapsedSeconds / 60))m $([int]($result.ElapsedSeconds % 60))s"
                        ""
                        "AccurateRip: $($ar.Status)$(if ($null -ne $ar.MinConfidence) { " (min confidence $($ar.MinConfidence))" })"
                        "CTDB:        $($ctdb.Status)$(if ($null -ne $ctdb.MinConfidence) { " (confidence $($ctdb.MinConfidence))" })"
                        "Re-read sectors: $($result.FailedSectors)"
                        ""
                        $destLine
                    )
                    if ($result.HtoaWarning) { $lines += @("", "Note: $($result.HtoaWarning)") }
                    if ($result.Errors -and $result.Errors.Count -gt 0) {
                        $lines += @("", "Warnings:") + ($result.Errors | ForEach-Object { "  - $_" })
                    }
                    $icon = switch ($result.Status) {
                        'Verified'      { 'Information' }
                        'ProbablyGood'  { 'Information' }
                        default         { 'Warning' }
                    }
                    Show-RipperInfo ($lines -join "`n") 'MusicRipper - Rip Complete' $icon
                    $summary = ($lines -join "`n")
                    # Mark this disc as ripped so a re-insertion offers the
                    # skip prompt. Store a human-readable label rather than
                    # a bare $true so the prompt can show the album name
                    # instead of an opaque DiscId.
                    $priorLabel = if ($m -and $m.AlbumArtist -and $m.Album) {
                        "$($m.AlbumArtist) - $($m.Album)"
                    } else {
                        "DiscId $($disc.DiscId)"
                    }
                    $script:RipperSession.RippedDiscs[$disc.DiscId] = $priorLabel
                }
            }

            _maybeEject $choice
            return _result 'Completed' $summary
        }
        'Cancel' {
            Write-RipperLog INFO 'Start-Ripper' 'User cancelled at confirm dialog. Ejecting.'
            _maybeEject $choice
            return _result 'Cancelled' "Disc ${cycleNum}: cancelled at metadata confirmation"
        }
    }

    # Defensive default (shouldn't reach here -- every switch arm returns).
    return _result 'Cancelled' "Disc ${cycleNum}: unknown outcome"
}

# --- Outer continuous-mode loop (Phase 5.7) -------------------------------
# When ContinuousMode is true (default), we keep the application running
# between discs so the parent can rip a stack of CDs without re-launching
# (and re-answering the UAC prompt). After each per-disc cycle we show the
# Show-RipperBetweenDiscsDialog: it offers Rip Next / Quit and also auto-
# selects Rip Next if a new disc arrives via WMI volume-change events.
#
# Logging: each iteration calls Start-RipperLog with a fresh per-disc
# context, so %LOCALAPPDATA%\MusicRipper\logs\ gets one timestamped file
# per disc. Move-ToLibrary's existing Copy-RipperLog call sees whichever
# log was active at the moment it ran, so the album folder ends up with
# its own per-disc log copy. The session-level setup log started above
# remains valid until the loop's first iteration rotates it.
$continuousMode = if ($cfg.PSObject.Properties['ContinuousMode']) { [bool]$cfg.ContinuousMode } else { $true }
Write-RipperLog INFO 'Start-Ripper' "ContinuousMode = $continuousMode"

# Phase 6.5: catch up on any albums whose post-rip sync didn't finish
# (NAS off, OneDrive offline, transient network blip). Runs ONCE at
# startup, before the do/while disc loop. Skips silently if
# sync-state.json is empty / all targets OK / cfg.SyncTargets empty
# / cfg.RetryPendingSyncOnStartup=false. The dialog has its own
# Cancel button that returns Action='Cancelled', in which case we
# fall through to the normal rip flow without complaint.
$retryOnStartup = if ($cfg.PSObject.Properties['RetryPendingSyncOnStartup']) { [bool]$cfg.RetryPendingSyncOnStartup } else { $true }
# Phase 6.6.F.3: track whether the startup resync actually had work
# to do, so that no-drive mode can show a friendly "nothing to do"
# toast on exit instead of just vanishing.
$resyncDidWork = $false
if ($retryOnStartup) {
    try {
        . (Join-Path $repoRoot 'src\sync\Invoke-PendingSync.ps1')
        . (Join-Path $repoRoot 'src\ui\Show-PendingSyncProgress.ps1')
        $resync = Show-RipperPendingSyncProgress `
            -LibraryRoot $cfg.LibraryRoot `
            -Config      $cfg `
            -RepoRoot    $repoRoot
        if ($resync) {
            switch ($resync.Action) {
                'Done' {
                    if ($resync.Summary -and $resync.Summary.Total -gt 0) {
                        $resyncDidWork = $true
                        Write-RipperLog INFO 'Start-Ripper' `
                            "Startup resync: synced=$($resync.Summary.Synced)/$($resync.Summary.Total), still failing=$($resync.Summary.StillFailing), skipped=$($resync.Summary.Skipped)."
                    }
                }
                'Cancelled' {
                    $resyncDidWork = $true
                    Write-RipperLog INFO 'Start-Ripper' 'Startup resync cancelled by user; proceeding to disc loop.'
                }
                'Error' {
                    $resyncDidWork = $true
                    $msg = if ($resync.Error) { $resync.Error.Exception.Message } else { 'unknown' }
                    Write-RipperLog WARN 'Start-Ripper' "Startup resync errored (non-fatal): $msg"
                }
            }
        }
    } catch {
        # Belt-and-suspenders: never let a startup resync failure
        # prevent the user from ripping discs.
        Write-RipperLog WARN 'Start-Ripper' "Startup resync threw (non-fatal): $($_.Exception.Message)"
    }
}

# Phase 6.6.F.3: in no-drive mode, the startup resync IS the whole
# session. If there was nothing pending, the app would otherwise just
# vanish silently after the user clicked No / Save -- show a quick
# acknowledgement so they know it actually ran and decided there was
# no work to do.
if ($skipRipLoop -and -not $resyncDidWork) {
    Show-RipperInfo "No pending albums to sync.`n`nMusicRipper has nothing to do without a registered drive -- closing." `
        'MusicRipper' 'Information'
}

do {
    # Phase 6.6.F.2: no-drive mode -- the user declined to register a
    # drive (or saved without one). Pending-sync above already ran;
    # there's nothing for the disc loop to do, so bail out cleanly.
    if ($skipRipLoop) {
        Write-RipperLog INFO 'Start-Ripper' 'No-drive mode: skipping disc loop.'
        break
    }

    # Rotate the log: stop the previous (setup or per-disc) log and open a
    # fresh per-disc file. The per-disc log captures everything from disc-id
    # read through eject for THIS disc only -- great for forensic review.
    Stop-RipperLog
    $perDiscLog = Start-RipperLog -Context "rip-disc-$($script:RipperSession.DiscCount + 1)"
    Write-RipperLog INFO 'Start-Ripper' "Per-disc log rotated to: $perDiscLog"

    try {
        $cycle = Invoke-RipperOneDiscCycle
    } catch {
        # Last-ditch safety net. Per-disc errors are supposed to be caught
        # inside Invoke-RipperOneDiscCycle and surfaced via message box, so
        # reaching here means something genuinely unexpected escaped.
        Write-RipperLog ERROR 'Start-Ripper' "Unhandled per-disc exception: $($_.Exception.Message)"
        Show-RipperInfo "An unexpected error occurred:`n`n  $($_.Exception.Message)`n`nReturning to the disc-insert prompt." `
            'MusicRipper' 'Error'
        $cycle = [pscustomobject]@{
            Outcome = 'Failed'
            Summary = "Disc $($script:RipperSession.DiscCount): unhandled error -- $($_.Exception.Message)"
        }
    }
    $script:RipperSession.LastSummary = $cycle.Summary

    if (-not $continuousMode) {
        Write-RipperLog INFO 'Start-Ripper' 'ContinuousMode disabled -- exiting after one disc.'
        break
    }

    # Between-discs prompt. Auto-detects disc arrival via WMI; otherwise
    # waits for the parent to click Rip Next or Quit.
    $next = Show-RipperBetweenDiscsDialog `
                -DriveLetter    $cfg.DriveLetter `
                -LastRipSummary $script:RipperSession.LastSummary `
                -DiscCount      $script:RipperSession.DiscCount

    Write-RipperLog INFO 'Start-Ripper' "Between-discs decision: Action=$($next.Action) Trigger=$($next.Trigger)"
    if ($next.Action -ne 'RipNext') { break }

    # Phase 5.11: re-scan _inbox\ before the next cycle. If the previous
    # cycle stranded a rip (e.g. Move-RipToLibrary "target already exists"
    # threw and the post-process catch left it in place), the parent gets
    # the resume prompt now instead of having to relaunch the app.
    if ((Invoke-RipperResumeOrphans -Quiet) -eq 'Quit') { break }
} while ($true)

Write-RipperLog INFO 'Start-Ripper' "Session ending: $($script:RipperSession.DiscCount) disc(s) processed."

# Phase 6.4.1: drop the keep-alive ref (if any) and defensively stop
# the tunnel if it's still up after all per-sync releases. Under normal
# flow with KeepAliveBetweenDiscs=false the tunnel is already down by
# now (each sync's finally tore it down). With keep-alive on, the env-
# var sentinel still names it. The PowerShell.Exiting engine event
# above handles abrupt exits (Quit / X / Ctrl+C); this block handles
# the clean flow-through. Best-effort; never fail the exit path.
$wgSentinel = $env:MUSICRIPPER_WG_SESSION_REF
$wgConfigured = $cfg.PSObject.Properties['WireGuardTunnelName'] -and `
                -not [string]::IsNullOrWhiteSpace([string]$cfg.WireGuardTunnelName)
if ($wgConfigured -or -not [string]::IsNullOrWhiteSpace($wgSentinel)) {
    try {
        $wgName = if (-not [string]::IsNullOrWhiteSpace($wgSentinel)) {
            $wgSentinel
        } else {
            [string]$cfg.WireGuardTunnelName
        }
        Import-Module (Join-Path $PSScriptRoot 'lib\Wireguard.psd1') -Force -ErrorAction Stop
        # Drop keep-alive ref (no-op if it was never enabled).
        [void](Disable-RipperVpnTunnelSessionKeepAlive -Name $wgName)
        # Defensive: if the service is still Running (hard crash mid-
        # sync) take it down anyway.
        if (Test-RipperVpnTunnel -Name $wgName) {
            Write-RipperLog WARN 'Start-Ripper' "WireGuard tunnel '$wgName' still Running at exit; stopping defensively."
            [void](Stop-RipperVpnTunnel -Name $wgName)
        }
        $env:MUSICRIPPER_WG_SESSION_REF = $null
    } catch {
        Write-RipperLog WARN 'Start-Ripper' "WireGuard exit-time cleanup skipped: $($_.Exception.Message)"
    }
}

Stop-RipperLog
