<#
.SYNOPSIS
    Install the third-party tools MusicRipper depends on, via winget.

.DESCRIPTION
    Pipeline position:
        First setup script. Run once per machine, elevated.

    Installs:
        - Microsoft.PowerShell    (PS7 — the runtime everything else expects)
        - CUETools.CUETools       (the rip engine + metaflac.exe)
        - MusicBrainz.Picard      (manual re-tagging tool for _ReviewQueue)

.EXAMPLE
    PS> ./setup/Install-Dependencies.ps1

.NOTES
    Requires winget (ships with Win10 1809+ and Win11). Idempotent: winget
    skips already-installed packages. We pass --accept-source-agreements and
    --accept-package-agreements so an unattended run from Install-MusicRipper.ps1
    (Phase 7) doesn't hang on prompts.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}

$packages = @(
    'Microsoft.PowerShell',
    'CUETools.CUETools',
    'MusicBrainz.Picard'
)

foreach ($id in $packages) {
    Write-Host "Installing $id ..." -ForegroundColor Cyan
    # --exact + --id avoids ambiguous matches; the agreement flags keep us
    # non-interactive so the top-level installer can run start-to-finish.
    & winget install --exact --id $id `
        --accept-source-agreements --accept-package-agreements `
        --silent
    # winget exit code 0 = installed; -1978335189 (0x8A150049) = already installed.
    # Both are success for our purposes.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Warning "winget exited with code $LASTEXITCODE for $id (continuing)."
    }
}

Write-Host "Dependencies installed. Next: ./setup/Register-Drive.ps1" -ForegroundColor Green
