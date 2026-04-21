<#
.SYNOPSIS
    Entry point parents click. Currently runs Phase 1 + Phase 2:
    config sanity check, disc-id read, MusicBrainz lookup, summary dialog.

.DESCRIPTION
    Pipeline position:
        Top of the daily-flow sequence. In later phases this will:
            ... -> Show-MetadataDialog (Phase 3) -> Invoke-Rip (Phase 4) ->
            Test-RipQuality -> Write-Tags -> Move-ToLibrary ->
            post-processors -> eject.

    Phase 2 behavior:
        - Loads config; aborts gracefully if missing.
        - If a disc is in the configured drive, reads its TOC
          (Get-RipperDiscId) and queries MusicBrainz
          (Get-RipperDiscMetadata).
        - Pops a summary message box showing what was found
          (album/artist/year + candidate count) or what failed
          (no disc / no match / offline).
        - Real rip + UI logic still belongs to Phase 3+.

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

# Dot-source the Phase 2 core scripts so their functions are in scope.
. (Join-Path $repoRoot 'src\core\Get-DiscId.ps1')
. (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')

$logPath = Start-RipperLog -Context 'start-ripper'
Write-RipperLog INFO 'Start-Ripper' 'Phase 2 entry: config + disc-id + metadata.'

# --- Config check ----------------------------------------------------------
$configPath = Get-RipperConfigPath
if (-not (Test-Path -LiteralPath $configPath)) {
    $msg = "Config not found at $configPath.`n`nRun setup\New-RipperConfig.ps1 first."
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($msg, 'MusicRipper',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    Stop-RipperLog
    return
}
$cfg = Import-RipperConfig

# --- Read disc + look up metadata ------------------------------------------
$summary = "Config:  $configPath`nLog:     $logPath`n`n"

try {
    $disc = Get-RipperDiscId
    $summary += "Disc ID:        $($disc.DiscId)`n"
    $summary += "Tracks:         $($disc.AudioTracks) audio ($([int]$disc.DurationSeconds)s total)`n`n"
} catch {
    $summary += "No disc / drive error:`n  $($_.Exception.Message)`n"
    Write-RipperLog WARN 'Start-Ripper' "Disc-id failed: $($_.Exception.Message)"
    $disc = $null
}

if ($disc) {
    try {
        $meta = Get-RipperDiscMetadata -DiscIdInfo $disc
        $summary += "MusicBrainz status:  $($meta.Status)  ($($meta.Candidates.Count) candidate(s))`n"
        if ($meta.BestMatch) {
            $b = $meta.BestMatch
            $summary += "Best match:`n"
            $summary += "  $($b.AlbumArtist) - $($b.Album)"
            if ($b.Year) { $summary += " ($($b.Year))" }
            $summary += "`n  Release MBID: $($b.ReleaseMbid)`n"
            $summary += "  Cover art:    $(if ($b.CoverArtBytes) { "$($b.CoverArtBytes.Length) bytes" } else { 'none' })`n"
        }
    } catch {
        $summary += "Metadata lookup failed:`n  $($_.Exception.Message)`n"
        Write-RipperLog WARN 'Start-Ripper' "Metadata failed: $($_.Exception.Message)"
    }
}

$summary += "`n(Phase 2 stub. Confirm dialog + rip land in Phases 3-4.)"

Add-Type -AssemblyName System.Windows.Forms | Out-Null
[System.Windows.Forms.MessageBox]::Show($summary, 'MusicRipper (Phase 2 stub)',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

Stop-RipperLog
