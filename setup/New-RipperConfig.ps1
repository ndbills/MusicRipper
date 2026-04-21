<#
.SYNOPSIS
    Interactively create %LOCALAPPDATA%\MusicRipper\config.json.

.DESCRIPTION
    Pipeline position:
        Setup script #3. Run after Install-Dependencies.ps1. May be re-run
        anytime to re-prompt; existing values are shown as defaults.

    Prompts for:
        - Library root path (required)
        - MusicBrainz contact email (required by their ToS)
        - Optional OneDrive mirror path
        - Optional Synology NAS UNC + credential (DPAPI-stored)

.EXAMPLE
    PS> ./setup/New-RipperConfig.ps1

.NOTES
    Why DPAPI for the NAS credential: PowerShell's Export-Clixml encrypts
    SecureStrings with the current Windows user's DPAPI key. The resulting
    file is unreadable by any other user on the machine and unportable to
    other machines — a cheap, dependency-free, "good enough for Mom's
    laptop" credential vault.
    See: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-clixml
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

Start-RipperLog -Context 'new-ripper-config' | Out-Null

# Read existing config (if any) so we can offer existing values as defaults.
$configPath = Get-RipperConfigPath
$existing   = if (Test-Path -LiteralPath $configPath) { Import-RipperConfig } else { $null }

function Read-WithDefault {
<#
.SYNOPSIS
    Read-Host with a default value shown in brackets. Press Enter to accept.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default
    )
    $shown = if ($Default) { "$Prompt [$Default] (Enter = keep)" } else { $Prompt }
    $val = Read-Host $shown
    if ([string]::IsNullOrWhiteSpace($val)) { $Default } else { $val }
}

if ($existing) {
    Write-Host ""
    Write-Host "Existing config found at $configPath" -ForegroundColor Cyan
    Write-Host "  LibraryRoot           : $($existing.LibraryRoot)"
    Write-Host "  MusicBrainzUserAgent  : $($existing.MusicBrainzUserAgent)"
    Write-Host "  OneDrivePath          : $($existing.OneDrivePath)"
    Write-Host "  SynologyUnc           : $($existing.SynologyUnc)"
    Write-Host "  DriveLetter / Offset  : $($existing.DriveLetter) / $($existing.DriveOffset)"
    Write-Host ""
    $ans = Read-Host "Press Enter to keep ALL existing values, or type 'e' to edit field-by-field"
    if ([string]::IsNullOrWhiteSpace($ans)) {
        Write-Host "No changes made." -ForegroundColor Green
        Stop-RipperLog
        return
    }
}

# --- Library root (required) ----------------------------------------------
$defaultLib = if ($existing) { $existing.LibraryRoot } else { Join-Path ([Environment]::GetFolderPath('MyMusic')) 'MusicRipper' }
$libraryRoot = Read-WithDefault -Prompt 'Library root path' -Default $defaultLib
if ([string]::IsNullOrWhiteSpace($libraryRoot)) { throw "Library root is required." }
if (-not (Test-Path -LiteralPath $libraryRoot)) {
    New-Item -ItemType Directory -Path $libraryRoot -Force | Out-Null
    Write-RipperLog INFO 'New-RipperConfig' "Created library root '$libraryRoot'."
}

# --- MusicBrainz UA / contact email ---------------------------------------
$defaultUa = if ($existing) { $existing.MusicBrainzUserAgent } else { 'MusicRipper/0.1 ( unknown@example.com )' }
$email = Read-WithDefault -Prompt 'MusicBrainz contact email (required by their ToS)' `
                          -Default ($defaultUa -replace '.*\(\s*', '' -replace '\s*\).*', '')
$ua = "MusicRipper/0.1 ( $email )"

# --- OneDrive (optional) ---------------------------------------------------
$defaultOd = if ($existing) { $existing.OneDrivePath } else { '' }
$oneDrive  = Read-WithDefault -Prompt 'OneDrive mirror path (blank to skip)' -Default $defaultOd
if ([string]::IsNullOrWhiteSpace($oneDrive)) { $oneDrive = $null }

# --- Synology NAS (optional) ----------------------------------------------
$defaultSyn = if ($existing) { $existing.SynologyUnc } else { '' }
$syn = Read-WithDefault -Prompt 'Synology NAS UNC path, e.g. \\nas\music (blank to skip)' -Default $defaultSyn
if ([string]::IsNullOrWhiteSpace($syn)) { $syn = $null }

$hasCred = $false
if ($syn) {
    $cred = Get-Credential -Message "Credentials for $syn (cancel to skip — you'll be prompted again at sync time)"
    if ($cred) {
        Save-RipperCredential -Credential $cred
        $hasCred = $true
        Write-RipperLog INFO 'New-RipperConfig' 'Synology credential saved (DPAPI).'
    }
}

# --- Build & persist -------------------------------------------------------
$cfg = New-RipperConfigObject `
    -LibraryRoot   $libraryRoot `
    -OneDrivePath  $oneDrive `
    -SynologyUnc   $syn

$cfg.MusicBrainzUserAgent  = $ua
$cfg.HasSynologyCredential = $hasCred

# Carry over drive info if Register-Drive ran first.
if ($existing) {
    $cfg.DriveLetter = $existing.DriveLetter
    $cfg.DriveOffset = $existing.DriveOffset
}

$cfg | Save-RipperConfig
Write-Host "Config written to $(Get-RipperConfigPath)" -ForegroundColor Green
Stop-RipperLog
