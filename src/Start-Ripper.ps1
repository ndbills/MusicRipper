<#
.SYNOPSIS
    Entry point parents click — currently a Phase-1 "Hello" stub.

.DESCRIPTION
    Pipeline position:
        Top of the daily-flow sequence. In later phases this will:
            Get-DiscId -> Get-DiscMetadata -> Show-MetadataDialog ->
            Invoke-Rip -> Test-RipQuality -> Write-Tags -> Move-ToLibrary ->
            post-processors -> eject.

    Phase 1 stub:
        Verifies config can be loaded, reports the active config + log paths,
        and shows a Windows message box so the Desktop shortcut visibly
        "did something." This is the verification target for Phase 1
        ("shortcut launches a 'Hello' stub").

.EXAMPLE
    PS> ./src/Start-Ripper.ps1

.NOTES
    Real orchestration logic lands in Phase 4+.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force

$logPath = Start-RipperLog -Context 'start-ripper-stub'
Write-RipperLog INFO 'Start-Ripper' 'Phase 1 stub starting.'

$configPath = Get-RipperConfigPath
$cfgStatus = if (Test-Path -LiteralPath $configPath) {
    try {
        $cfg = Import-RipperConfig
        "OK  (LibraryRoot=$($cfg.LibraryRoot), Drive=$($cfg.DriveLetter), Offset=$($cfg.DriveOffset))"
    } catch {
        "INVALID: $($_.Exception.Message)"
    }
} else {
    'NOT FOUND — run setup\New-RipperConfig.ps1'
}

$msg = @"
MusicRipper — Phase 1 stub

Config:  $configPath
Status:  $cfgStatus

Log:     $logPath

Rip logic lands in later phases.
"@

Write-RipperLog INFO 'Start-Ripper' "Config status: $cfgStatus"

# Fire a Windows message box so the Desktop shortcut visibly responds.
# System.Windows.Forms is part of WPF/WinForms; ships with .NET on Windows.
Add-Type -AssemblyName System.Windows.Forms | Out-Null
[System.Windows.Forms.MessageBox]::Show($msg, 'MusicRipper (Phase 1 stub)',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

Stop-RipperLog
