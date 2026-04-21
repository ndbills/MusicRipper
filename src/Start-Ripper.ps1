<#
.SYNOPSIS
    Entry point parents click. Phases 1-3: config check, disc-id read,
    MusicBrainz lookup, confirmation dialog.

.DESCRIPTION
    Pipeline position:
        Top of the daily-flow sequence. In later phases this will:
            ... -> Show-MetadataDialog -> Invoke-Rip (Phase 4) ->
            Test-RipQuality -> Write-Tags -> Move-ToLibrary ->
            post-processors -> eject.

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
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force

# Dot-source the Phase 2 core scripts and the Phase 3 dialog so their
# functions are in scope.
. (Join-Path $repoRoot 'src\core\Get-DiscId.ps1')
. (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
. (Join-Path $repoRoot 'src\ui\Show-MetadataDialog.ps1')

$logPath = Start-RipperLog -Context 'start-ripper'
Write-RipperLog INFO 'Start-Ripper' 'Phase 3 entry: config + disc-id + metadata + confirm dialog.'

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
    Show-RipperInfo "Config not found at $configPath.`n`nRun setup\New-RipperConfig.ps1 first." `
        'MusicRipper' 'Warning'
    Stop-RipperLog
    return
}
$cfg = Import-RipperConfig

# --- Read disc -------------------------------------------------------------
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
    Write-RipperLog WARN 'Start-Ripper' "Disc-id failed: $($lastDiscError.Exception.Message)"
    Show-RipperInfo "No disc / drive error:`n`n  $($lastDiscError.Exception.Message)`n`nInsert a CD and try again." `
        'MusicRipper' 'Warning'
    Stop-RipperLog
    return
}

# --- Metadata lookup -------------------------------------------------------
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

# --- Phase 3: confirmation dialog ------------------------------------------
$onResearch = {
    Write-RipperLog INFO 'Start-Ripper' "Re-search MusicBrainz requested for $($disc.DiscId)."
    Get-RipperDiscMetadata -DiscIdInfo $disc
}

$choice = Show-RipperMetadataDialog -Metadata $meta -OnResearch $onResearch

Write-RipperLog INFO 'Start-Ripper' "User chose: $($choice.Action)."

switch ($choice.Action) {
    'Rip' {
        $m = $choice.Metadata
        $summary  = "Phase 4 (rip engine) is not implemented yet.`n`n"
        $summary += "Would have ripped:`n"
        $summary += "  $($m.AlbumArtist) - $($m.Album)"
        if ($m.Year) { $summary += " ($($m.Year))" }
        $summary += "`n  $($m.TrackCount) track(s), Release MBID $($m.ReleaseMbid)`n"
        Show-RipperInfo $summary 'MusicRipper (Phase 3 stub)' 'Information'
    }
    'Review' {
        $m = $choice.Metadata
        Show-RipperInfo "Marked for Review (Phase 5 routing).`n`nDisc: $($m.AlbumArtist) - $($m.Album)`n`nEjecting now." `
            'MusicRipper (Phase 3 stub)' 'Information'
        Invoke-RipperEject
    }
    'Cancel' {
        Write-RipperLog INFO 'Start-Ripper' 'User cancelled at confirm dialog. Ejecting.'
        Invoke-RipperEject
    }
}

Stop-RipperLog
