<#
.SYNOPSIS
    Phase 8 (D-032): standalone entry point for the self-update WPF
    dialog. Reachable via the "MusicRipper - Update" Desktop / Start
    Menu shortcut.

.DESCRIPTION
    Mirrors the F-6 Show-RipperConfig.ps1 adapter: self-minimize the
    pwsh host, import deps, dot-source the WPF, run a per-launch log,
    open the dialog, exit 0 regardless of cancel/save.

    The update flow itself lives in src\ui\Show-UpdateDialog.ps1 +
    src\lib\Updater.psm1; this file is a thin shim.

    Idempotent: running it when no update is available just shows a
    friendly "you're up to date" panel + OK button.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Self-minimize the host pwsh window; same rationale + idiom as
# src\tools\Show-RipperConfig.ps1 (F-6 outcome -- a Minimized .lnk
# launching pwsh that immediately spawns a WPF window can leave the
# WPF inheriting SW_SHOWMINIMIZED if pwsh hasn't fully come up yet).
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
    # Resolve the install root from THIS script's location (rather
    # than $repoRoot) so the updater always operates on the install
    # it was launched from. Belt-and-suspenders: $repoRoot above is
    # the same value, but Get-RipperInstallRoot validates marker
    # files and so will reject a malformed install we wouldn't want
    # to risk applying over.
    $installRoot = Get-RipperInstallRoot -StartPath $PSScriptRoot
    if (-not $installRoot) {
        Write-RipperLog ERROR 'Update-MusicRipper' "Could not resolve a MusicRipper install root from '$PSScriptRoot'. Refusing to update."
        Add-Type -AssemblyName PresentationFramework | Out-Null
        [System.Windows.MessageBox]::Show(
            "MusicRipper update couldn't find a valid install to update.`n`nThe script ran from:`n  $PSScriptRoot`n`nIt expected to find Install-MusicRipper.ps1 + src\Start-Ripper.ps1 in the same install. Reinstall MusicRipper if this doesn't make sense.",
            'MusicRipper - Update', 'OK', 'Error') | Out-Null
        return
    }
    Write-RipperLog INFO 'Update-MusicRipper' "Update flow starting (install root: $installRoot)."

    try {
        [void](Show-RipperUpdateDialog -InstallRoot $installRoot)
    } catch {
        Write-RipperLog ERROR 'Update-MusicRipper' "Show-RipperUpdateDialog threw: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        if ($_.ScriptStackTrace) {
            Write-RipperLog ERROR 'Update-MusicRipper' "Stack: $($_.ScriptStackTrace)"
        }
        Add-Type -AssemblyName PresentationFramework | Out-Null
        [System.Windows.MessageBox]::Show(
            "The update dialog failed to open:`n`n  $($_.Exception.Message)`n`nSee the log for details.",
            'MusicRipper - Update', 'OK', 'Error') | Out-Null
    }
} finally {
    Stop-RipperLog
}
