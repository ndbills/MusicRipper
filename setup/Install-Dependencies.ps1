<#
.SYNOPSIS
    Install the third-party tools MusicRipper depends on, via winget.

.DESCRIPTION
    Pipeline position:
        First setup script. Run once per machine, elevated.

    Installs:
        - Microsoft.PowerShell  (PS7 — the runtime everything else expects)
        - gchudov.CUETools      (the rip engine; .NET DLLs only — see below)
        - Xiph.FLAC             (provides metaflac.exe for tagging + ReplayGain;
                                 see docs/DECISIONS.md D-009)
        - MusicBrainz.Picard    (manual re-tagging tool for _ReviewQueue)

    Note on the CUETools id: the publisher's winget package id is
    `gchudov.CUETools` (the upstream maintainer's GitHub handle), NOT
    `CUETools.CUETools` as the website-style name might suggest. Verified
    via `winget search CUETools`.

    Note on Xiph.FLAC: the original Phase 1 plan assumed `metaflac.exe`
    shipped with CUETools — it does NOT (verified by inspecting the
    portable winget package, which contains only .NET DLLs + the GUI
    rippers). Phase 5 needs metaflac for FLAC tag writes, cover-art
    embedding, and ReplayGain analysis (the only canonical RG impl).
    See docs/DECISIONS.md D-009 for rejected alternatives.

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
    'gchudov.CUETools',
    'Xiph.FLAC',
    'MusicBrainz.Picard',
    # Phase 6.4: WireGuard for Windows is needed only when the family
    # NAS lives behind a VPN. We install it unconditionally because
    # winget's repeat-install is idempotent (returns "already installed"
    # exit code) and the binary is ~5 MB. setup/New-RipperConfig.ps1
    # handles per-tunnel install (/installtunnelservice + sdset) on
    # demand if the user opts in.
    'WireGuard.WireGuard'
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
