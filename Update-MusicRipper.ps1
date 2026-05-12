<#
.SYNOPSIS
    Phase 8 (D-032): standalone entry point for the self-update WPF
    dialog. Reachable via the "MusicRipper - Update" Start Menu
    shortcut.

.DESCRIPTION
    Sibling at the repo root to Install-MusicRipper.ps1 +
    Uninstall-MusicRipper.ps1 so the three top-level lifecycle
    actions (install / update / uninstall) live together.

    Two-mode design (the self-mutation problem -- see .NOTES):

      Bootstrap mode (default; no params):
        Triggered when the parent clicks the "MusicRipper - Update"
        shortcut. Copies the four required files (Update-MusicRipper.ps1
        + Logging/Common/Updater modules + Show-UpdateDialog.ps1) to
        %TEMP%\musicripper-updater-<guid>\, spawns a hidden pwsh from
        the temp copy with -IsTempHelper, then exits. The original
        pwsh's exit releases all open handles on the install dir,
        which is what makes the helper's atomic-rename apply step
        possible.

      Helper mode (-IsTempHelper -InstallRoot <path>):
        Self-minimizes the pwsh host, imports deps from the temp
        copy of the modules, opens the WPF dialog against the
        install path passed in. The install dir has zero open
        handles from this process, so the rename + apply succeeds.

    Idempotent: running it when no update is available just shows a
    friendly "you're up to date" panel + OK button.

.PARAMETER IsTempHelper
    Internal: signals helper mode. Set by the bootstrap when it
    spawns the helper from %TEMP%. Don't pass this manually.

.PARAMETER InstallRoot
    Required in helper mode: the absolute path of the live install
    that should be updated. Set by the bootstrap from $PSScriptRoot
    of the original launch.

.NOTES
    The self-mutation problem (D-032 amendment): when this script
    runs from inside the install dir, pwsh holds open handles on
    Update-MusicRipper.ps1 itself, the imported modules
    (Logging/Common/Updater .psm1 + .psd1), and the install dir is
    the working directory inherited from the .lnk. Windows refuses
    to Rename-Item the install dir while any of those handles
    exist, which crashes Save-RipperUpdateBackup with "rename
    failed". The two-mode design above moves the running script +
    its modules to %TEMP%, leaving the install dir cleanly
    renamable.

    Same temp-helper pattern documented in /memories/powershell.md
    ("Self-elevating an existing script") and used by
    Uninstall-MusicRipper.ps1's elevation flow.
#>

[CmdletBinding()]
param(
    [switch]$IsTempHelper,
    [string]$InstallRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Pre-load PresentationFramework BEFORE anything else so error-path
# MessageBox calls work in either mode (the "fresh pwsh AppDomain"
# parse-time trap documented in /memories/powershell.md).
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml


# =========================================================================
# BOOTSTRAP MODE: copy ourselves + deps to %TEMP%, spawn helper, exit.
# =========================================================================
if (-not $IsTempHelper) {
    $sourceRoot = $PSScriptRoot   # the live install dir
    $tempBase   = Join-Path ([System.IO.Path]::GetTempPath()) `
                            ('musicripper-updater-' + [guid]::NewGuid().ToString('N'))

    try {
        # Mirror the install layout for just the files the helper needs:
        #   <temp>\Update-MusicRipper.ps1
        #   <temp>\src\lib\{Logging,Common,Updater}.{psd1,psm1}
        #   <temp>\src\ui\Show-UpdateDialog.ps1
        New-Item -ItemType Directory -Path $tempBase                          -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempBase 'src\lib')    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tempBase 'src\ui')     -Force | Out-Null

        Copy-Item -LiteralPath (Join-Path $sourceRoot 'Update-MusicRipper.ps1') `
                  -Destination $tempBase -Force -ErrorAction Stop

        foreach ($m in @('Logging', 'Common', 'Updater')) {
            foreach ($ext in @('psd1', 'psm1')) {
                $src = Join-Path $sourceRoot "src\lib\$m.$ext"
                $dst = Join-Path $tempBase  "src\lib\$m.$ext"
                Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            }
        }

        Copy-Item -LiteralPath (Join-Path $sourceRoot 'src\ui\Show-UpdateDialog.ps1') `
                  -Destination (Join-Path $tempBase 'src\ui') -Force -ErrorAction Stop

        # Spawn the helper. Three things matter here:
        # 1. -WindowStyle Hidden so the parent never sees a stray pwsh
        #    console -- only the WPF dialog comes up.
        # 2. -WorkingDirectory $env:TEMP so the helper does NOT inherit
        #    the install dir as its CWD. Without this, even though the
        #    helper file + modules live in %TEMP%, the helper PROCESS
        #    holds the install dir as its current directory, and
        #    Windows refuses to rename a directory that any process
        #    has as CWD (ERROR_SHARING_VIOLATION; manifests as
        #    "Cannot rename the item ... because it is in use").
        #    Logged in /memories/powershell.md.
        # 3. We DON'T -Wait: the parent must exit immediately so its
        #    own file handles + CWD lock release; the helper runs
        #    independently.
        $helperPath = Join-Path $tempBase 'Update-MusicRipper.ps1'
        $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
        Start-Process -FilePath $pwshExe `
                      -WindowStyle Hidden `
                      -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
                      -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $helperPath,
            '-IsTempHelper',
            '-InstallRoot', $sourceRoot
        ) | Out-Null

        # Done. Exit cleanly so file handles are released ASAP.
        return
    } catch {
        # Bootstrap failure (disk full, permission denied, no pwsh on
        # PATH, etc.). Surface via MessageBox so the user isn't left
        # staring at nothing -- the bootstrap is invisible by design,
        # so silent failures would be impossible to diagnose.
        $msg = $_.Exception.Message
        try {
            [System.Windows.MessageBox]::Show(
                "MusicRipper update couldn't start.`n`nReason: $msg`n`nTry running the update again. If it keeps failing, check %TEMP% has free space and that pwsh is on PATH.",
                'MusicRipper - Update', 'OK', 'Error') | Out-Null
        } catch {
            # MessageBox itself failed (very unlikely with PresentationFramework
            # already loaded). Best effort: write to a known fallback log so
            # the next click of Update can at least be diagnosed.
            try {
                $fallbackLog = Join-Path ([System.IO.Path]::GetTempPath()) 'musicripper-updater-bootstrap-failure.log'
                "[$([DateTime]::Now.ToString('o'))] Bootstrap failed: $msg" |
                    Add-Content -LiteralPath $fallbackLog -Encoding UTF8
            } catch { }
        }
        return
    }
}


# =========================================================================
# HELPER MODE: imports from %TEMP%, opens the WPF, applies to $InstallRoot.
# =========================================================================

# In helper mode $PSScriptRoot is the temp dir (where our deps live);
# $InstallRoot is the actual install we're updating.
$repoRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    [System.Windows.MessageBox]::Show(
        "MusicRipper update was launched in helper mode without -InstallRoot. This shouldn't happen; please report the bug.",
        'MusicRipper - Update', 'OK', 'Error') | Out-Null
    return
}
if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    [System.Windows.MessageBox]::Show(
        "MusicRipper update was given an install root that doesn't exist:`n`n  $InstallRoot",
        'MusicRipper - Update', 'OK', 'Error') | Out-Null
    return
}

# Self-minimize the host pwsh window; same rationale + idiom as
# src\tools\Show-RipperConfig.ps1 (F-6 outcome). Belt-and-suspenders
# alongside the bootstrap's -WindowStyle Hidden launch.
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
} catch { }

Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Updater.psd1') -Force
. (Join-Path $repoRoot 'src\ui\Show-UpdateDialog.ps1')

Start-RipperLog -Context 'update'

try {
    # Belt-and-braces against -WorkingDirectory not propagating: force
    # CWD to the helper's temp dir. Without this, ANY parent-process
    # CWD inheritance (-WorkingDirectory bug, alternate launchers, etc.)
    # would re-trigger the "rename failed: in use" bug. Logged before
    # the Set-Location so the diagnostic survives if the change throws.
    Write-RipperLog INFO 'Update-MusicRipper' "Helper CWD on entry: $((Get-Location).Path)"
    try {
        Set-Location -LiteralPath $repoRoot
        Write-RipperLog INFO 'Update-MusicRipper' "Helper CWD pinned to temp: $repoRoot"
    } catch {
        Write-RipperLog WARN 'Update-MusicRipper' "Could not pin helper CWD to '$repoRoot': $($_.Exception.Message). Continuing; the rename step may fail with 'in use'."
    }

    Write-RipperLog INFO 'Update-MusicRipper' "Update helper starting (install root: $InstallRoot, helper temp: $repoRoot)."

    try {
        [void](Show-RipperUpdateDialog -InstallRoot $InstallRoot)
    } catch {
        Write-RipperLog ERROR 'Update-MusicRipper' "Show-RipperUpdateDialog threw: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        if ($_.ScriptStackTrace) {
            Write-RipperLog ERROR 'Update-MusicRipper' "Stack: $($_.ScriptStackTrace)"
        }
        [System.Windows.MessageBox]::Show(
            "The update dialog failed to open:`n`n  $($_.Exception.Message)`n`nSee the log for details.",
            'MusicRipper - Update', 'OK', 'Error') | Out-Null
    }
} finally {
    Stop-RipperLog
    # Best-effort cleanup of the helper's temp dir. We can't delete
    # ourselves while we're loaded, so this only fires if the deletion
    # is somehow possible (race-y on Windows). The OS / Storage Sense
    # will eventually GC %TEMP% anyway. Don't worry about failures.
    try {
        Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue
    } catch { }
}
