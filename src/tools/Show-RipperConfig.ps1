<#
.SYNOPSIS
    F-6 (Phase 8): standalone entry point for the WPF config editor.

.DESCRIPTION
    Thin adapter that imports the modules `Show-RipperConfigDialog`
    needs, resolves the on-disk config path, and opens the editor.
    Reachable via the "MusicRipper - Settings" Start Menu shortcut
    installed by `setup\Install-StartMenuShortcuts.ps1`.

    Behaviour:
      - If `config.json` exists, load it and pass to the editor for
        edit. Save writes through `Save-RipperConfig` as usual.
      - If `config.json` does not exist (fresh machine, parent
        clicked Settings before ever launching MusicRipper), open
        the editor in `-FirstRun` mode so the OK-enable predicate
        enforces the irreducible fields. Mirrors the first-run flow
        in `src\Start-Ripper.ps1`.

    No live-reload: the main MusicRipper process (if running) reads
    config once at startup and never re-reads. Saved settings apply
    on the next launch -- the dialog's Save handler shows a toast
    saying so. See DECISIONS.md F-6 for the runtime-safety analysis.

.NOTES
    Always exits 0; cancel and save are both expected outcomes for
    a Settings shortcut. Errors during editor launch are surfaced as
    a MessageBox and logged, but still exit 0 so the shortcut never
    pops a pwsh stack trace at the parent.

    Same module-import / dot-source layout as
    `src\tools\Sync-PendingAlbums.ps1`.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
. (Join-Path $repoRoot 'src\ui\Show-RipperConfigDialog.ps1')

# Per-launch log file under the standard logs dir; mirrors the rest
# of the app so a parent-reported "Settings wouldn't open" can be
# diagnosed from the same place as a rip failure.
Start-RipperLog -Context 'settings'

try {
    $configPath = Get-RipperConfigPath
    $configDir  = Split-Path -Parent $configPath
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $configPath) {
        Write-RipperLog INFO 'Show-RipperConfig' "Editing existing config at '$configPath'."
        $cfg = Import-RipperConfig
        try {
            $saved = Show-RipperConfigDialog -Config $cfg -ConfigPath $configPath
        } catch {
            Write-RipperLog ERROR 'Show-RipperConfig' "Show-RipperConfigDialog threw: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            if ($_.ScriptStackTrace) { Write-RipperLog ERROR 'Show-RipperConfig' "Stack: $($_.ScriptStackTrace)" }
            Add-Type -AssemblyName PresentationFramework | Out-Null
            [System.Windows.MessageBox]::Show(
                "The settings editor failed to open:`n`n  $($_.Exception.Message)`n`nSee the log for details.",
                'MusicRipper - Settings', 'OK', 'Error') | Out-Null
            return
        }
        if ($saved) {
            Write-RipperLog INFO 'Show-RipperConfig' "Settings saved to '$configPath'."
        } else {
            Write-RipperLog INFO 'Show-RipperConfig' 'Settings dialog cancelled; no changes written.'
        }
    } else {
        # No config on disk -- open in first-run mode so the OK-enable
        # predicate enforces LibraryRoot + MB contact + at least one
        # sync target. Same shape as Start-Ripper.ps1's first-run hook.
        Write-RipperLog INFO 'Show-RipperConfig' "No config at '$configPath' -- launching first-run editor."
        try {
            $saved = Show-RipperConfigDialog -FirstRun -ConfigPath $configPath
        } catch {
            Write-RipperLog ERROR 'Show-RipperConfig' "Show-RipperConfigDialog (FirstRun) threw: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            if ($_.ScriptStackTrace) { Write-RipperLog ERROR 'Show-RipperConfig' "Stack: $($_.ScriptStackTrace)" }
            Add-Type -AssemblyName PresentationFramework | Out-Null
            [System.Windows.MessageBox]::Show(
                "The settings editor failed to open:`n`n  $($_.Exception.Message)`n`nSee the log for details.",
                'MusicRipper - Settings', 'OK', 'Error') | Out-Null
            return
        }
        if ($saved) {
            Write-RipperLog INFO 'Show-RipperConfig' "First-run config saved to '$configPath'."
        } else {
            Write-RipperLog INFO 'Show-RipperConfig' 'First-run settings dialog cancelled; no config written.'
        }
    }
} finally {
    Stop-RipperLog
}
