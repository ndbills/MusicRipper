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
        - Metadata-provider chain   (Phase 5.2; comma-separated, in priority order)
        - Cover-art-provider chain  (Phase 5.2; comma-separated, in priority order)

.EXAMPLE
    PS> ./setup/New-RipperConfig.ps1

.EXAMPLE
    PS> ./setup/New-RipperConfig.ps1 -TopUp
    # Non-interactive: leaves existing values alone but fills in any
    # fields that are missing (e.g. MetadataProviders on a pre-5.2
    # config) with their built-in defaults. Safe to run unattended.

.NOTES
    Why DPAPI for the NAS credential: PowerShell's Export-Clixml encrypts
    SecureStrings with the current Windows user's DPAPI key. The resulting
    file is unreadable by any other user on the machine and unportable to
    other machines — a cheap, dependency-free, "good enough for Mom's
    laptop" credential vault.
    See: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-clixml
#>

[CmdletBinding()]
param(
    # Non-interactive mode: keep every existing value, but write any
    # missing fields with their built-in defaults. Useful after a
    # MusicRipper upgrade introduces a new config key (Phase 5.2 added
    # MetadataProviders + CoverArtProviders).
    [switch]$TopUp
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

Start-RipperLog -Context 'new-ripper-config' | Out-Null

# Read existing config (if any) so we can offer existing values as defaults.
$configPath = Get-RipperConfigPath
$existing   = if (Test-Path -LiteralPath $configPath) { Import-RipperConfig } else { $null }

# Built-in defaults for fields added in later phases. Referenced in two
# places: the "missing key" detection below, and the provider-chain
# prompts further down.
$knownMd  = @('MusicBrainz', 'CuetoolsDb', 'GnuDb')
$knownCov = @('CoverArtArchive', 'iTunesSearch', 'Deezer')

# Detect config keys that New-RipperConfigObject would emit but the
# existing file is missing. An upgrade-in-place without re-prompting
# the user just writes these out with their built-in defaults.
$missingKeys = @()
if ($existing) {
    $expected = @{
        MetadataProviders = $knownMd
        CoverArtProviders = $knownCov
    }
    foreach ($k in $expected.Keys) {
        if (-not $existing.PSObject.Properties[$k]) {
            $missingKeys += $k
        }
    }
}

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
    $existingMd  = if ($existing.PSObject.Properties['MetadataProviders']  -and $existing.MetadataProviders)  { ($existing.MetadataProviders  -join ', ') } else { '(missing — will default to: ' + ($knownMd  -join ', ') + ')' }
    $existingCov = if ($existing.PSObject.Properties['CoverArtProviders'] -and $existing.CoverArtProviders) { ($existing.CoverArtProviders -join ', ') } else { '(missing — will default to: ' + ($knownCov -join ', ') + ')' }
    Write-Host "  MetadataProviders     : $existingMd"
    Write-Host "  CoverArtProviders     : $existingCov"
    Write-Host ""

    # -TopUp: non-interactive upgrade path. Write existing values back
    # verbatim plus any missing keys with their built-in defaults.
    if ($TopUp) {
        if ($missingKeys.Count -eq 0) {
            Write-Host "-TopUp: config already has every known field. No changes." -ForegroundColor Green
            Stop-RipperLog
            return
        }
        Write-Host "-TopUp: adding missing field(s) with defaults: $($missingKeys -join ', ')" -ForegroundColor Yellow
        $cfg = New-RipperConfigObject `
            -LibraryRoot   $existing.LibraryRoot `
            -OneDrivePath  $existing.OneDrivePath `
            -SynologyUnc   $existing.SynologyUnc
        foreach ($p in $existing.PSObject.Properties) {
            # Carry every existing key over; New-RipperConfigObject has
            # already filled in defaults for anything the existing file
            # didn't have.
            if ($cfg.PSObject.Properties[$p.Name]) { $cfg.$($p.Name) = $p.Value }
        }
        $cfg | Save-RipperConfig
        Write-Host "Config written to $configPath" -ForegroundColor Green
        Write-RipperLog INFO 'New-RipperConfig' "Top-up: added missing keys $($missingKeys -join ', ')."
        Stop-RipperLog
        return
    }

    $hint = if ($missingKeys.Count -gt 0) {
        "Missing field(s) detected: $($missingKeys -join ', '). Type 'u' to add defaults, 'e' to edit field-by-field, or Enter to keep as-is"
    } else {
        "Press Enter to keep ALL existing values, type 'u' to top up any missing fields with defaults, or 'e' to edit field-by-field"
    }
    $ans = Read-Host $hint
    if ([string]::IsNullOrWhiteSpace($ans)) {
        Write-Host "No changes made." -ForegroundColor Green
        Stop-RipperLog
        return
    }
    if ($ans -match '^\s*u\s*$') {
        if ($missingKeys.Count -eq 0) {
            Write-Host "Config already has every known field. No changes." -ForegroundColor Green
            Stop-RipperLog
            return
        }
        Write-Host "Adding missing field(s) with defaults: $($missingKeys -join ', ')" -ForegroundColor Yellow
        $cfg = New-RipperConfigObject `
            -LibraryRoot   $existing.LibraryRoot `
            -OneDrivePath  $existing.OneDrivePath `
            -SynologyUnc   $existing.SynologyUnc
        foreach ($p in $existing.PSObject.Properties) {
            if ($cfg.PSObject.Properties[$p.Name]) { $cfg.$($p.Name) = $p.Value }
        }
        $cfg | Save-RipperConfig
        Write-Host "Config written to $configPath" -ForegroundColor Green
        Write-RipperLog INFO 'New-RipperConfig' "Top-up (interactive): added missing keys $($missingKeys -join ', ')."
        Stop-RipperLog
        return
    }
    # Anything else (typically 'e') falls through to the edit loop.
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

# --- Provider chains (Phase 5.2) ------------------------------------------
# Free-form comma-separated lists so the user can reorder, drop, or add
# providers we ship later without this script needing to grow a menu.
# Names that don't match a known provider are accepted but warned about
# (the orchestrator skips unknowns at runtime with a WARN log line).
# ($knownMd / $knownCov were computed at the top of the script.)

function Read-ProviderList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [string[]]$Default,
        [Parameter(Mandatory)] [string[]]$Known
    )
    $defStr = $Default -join ', '
    $raw = Read-Host "$Prompt [$defStr] (Enter = keep)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $list = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($n in $list) {
        if ($Known -notcontains $n) {
            Write-Warning "Provider '$n' is not one of the built-ins ($($Known -join ', ')). It will be skipped at runtime unless you add a matching provider module."
        }
    }
    return $list
}

$defaultMd  = if ($existing -and $existing.PSObject.Properties['MetadataProviders']  -and $existing.MetadataProviders)  { @($existing.MetadataProviders)  } else { $knownMd }
$defaultCov = if ($existing -and $existing.PSObject.Properties['CoverArtProviders'] -and $existing.CoverArtProviders) { @($existing.CoverArtProviders) } else { $knownCov }
$metadataProviders = Read-ProviderList -Prompt 'Metadata providers (priority order, comma-separated)'  -Default $defaultMd  -Known $knownMd
$coverArtProviders = Read-ProviderList -Prompt 'Cover-art providers (priority order, comma-separated)' -Default $defaultCov -Known $knownCov

# --- Build & persist -------------------------------------------------------
$cfg = New-RipperConfigObject `
    -LibraryRoot   $libraryRoot `
    -OneDrivePath  $oneDrive `
    -SynologyUnc   $syn

$cfg.MusicBrainzUserAgent  = $ua
$cfg.HasSynologyCredential = $hasCred
$cfg.MetadataProviders     = $metadataProviders
$cfg.CoverArtProviders     = $coverArtProviders

# Carry over drive info if Register-Drive ran first.
if ($existing) {
    $cfg.DriveLetter = $existing.DriveLetter
    $cfg.DriveOffset = $existing.DriveOffset
}

$cfg | Save-RipperConfig
Write-Host "Config written to $(Get-RipperConfigPath)" -ForegroundColor Green
Stop-RipperLog
