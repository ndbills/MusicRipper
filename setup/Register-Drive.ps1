<#
.SYNOPSIS
    Detect the optical drive(s) on this machine and persist the chosen drive
    plus its AccurateRip read-offset to config.json.

.DESCRIPTION
    Pipeline position:
        Setup script #2. Run after Install-Dependencies.ps1 and (ideally)
        New-RipperConfig.ps1, so config.json already exists.

    Steps:
        1. Enumerate optical drives via CIM (Win32_CDROMDrive).
        2. If multiple, prompt the user to pick one.
        3. Look up the drive's AccurateRip read offset:
             a. Try scraping http://www.accuraterip.com/driveoffsets.htm.
             b. On any failure (network down, page format change), fall back
                to the install-time data/driveoffsets.cached.json (populated
                by setup/Install-DriveOffsetCache.ps1 during first install;
                the AccurateRip offset list is not redistributable, so we
                fetch it fresh on the user's machine).
             c. If still no match, prompt the user to enter manually (or 0
                with a warning that AR verification will be unreliable).
        4. Update config.json with DriveLetter + DriveOffset.

.EXAMPLE
    PS> ./setup/Register-Drive.ps1

.NOTES
    Why CIM not WMI: Get-CimInstance is the modern, faster, remoting-friendly
    API. Win32_CDROMDrive is one of the few WMI classes that still returns
    consistent results across Win10/Win11.

    AccurateRip offset background:
    https://www.accuraterip.com/driveoffsets.htm
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Pull in shared modules. Use absolute paths derived from this script's
# location so the script works regardless of cwd.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')             -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1')            -Force
Import-Module (Join-Path $repoRoot 'src\lib\DriveRegistration.psd1') -Force

Start-RipperLog -Context 'register-drive' | Out-Null

# If a previous run already populated DriveLetter + DriveOffset, offer to keep
# them rather than re-doing the live AccurateRip lookup (which may have failed
# the first time, e.g. for an obscure drive that needed manual entry).
$existingCfg = if (Test-Path -LiteralPath (Get-RipperConfigPath)) { Import-RipperConfig } else { $null }
if ($existingCfg -and $existingCfg.DriveLetter -and $null -ne $existingCfg.DriveOffset) {
    Write-Host ""
    Write-Host "Drive already registered:" -ForegroundColor Cyan
    Write-Host "  DriveLetter : $($existingCfg.DriveLetter)"
    Write-Host "  DriveOffset : $($existingCfg.DriveOffset) samples"
    Write-Host ""
    $ans = Read-Host "Press Enter to keep, or type 'r' to re-detect"
    if ([string]::IsNullOrWhiteSpace($ans)) {
        Write-Host "No changes made." -ForegroundColor Green
        Stop-RipperLog
        return
    }
}

Write-RipperLog INFO 'Register-Drive' 'Enumerating optical drives via Win32_CDROMDrive.'

$drives = @(Get-RipperOpticalDrives)
if ($drives.Count -eq 0) {
    throw "No optical drives detected. Plug in a USB CD/DVD drive and re-run."
}

# Pick the drive (auto if one, prompt if many).
if ($drives.Count -eq 1) {
    $chosen = $drives[0]
} else {
    Write-Host "Multiple optical drives found:" -ForegroundColor Cyan
    # Pre-select the previously-saved drive if it's still present.
    $defaultIdx = 0
    if ($existingCfg -and $existingCfg.DriveLetter) {
        for ($i = 0; $i -lt $drives.Count; $i++) {
            if ($drives[$i].Drive -eq $existingCfg.DriveLetter) { $defaultIdx = $i; break }
        }
    }
    for ($i = 0; $i -lt $drives.Count; $i++) {
        $marker = if ($i -eq $defaultIdx) { '*' } else { ' ' }
        '{0} {1,3}: {2}  ({3})' -f $marker, $i, $drives[$i].Drive, $drives[$i].Name | Write-Host
    }
    do {
        $sel = Read-Host "Select drive number [$defaultIdx] (Enter = keep)"
        if ([string]::IsNullOrWhiteSpace($sel)) { $sel = "$defaultIdx" }
    } until ($sel -match '^\d+$' -and [int]$sel -lt $drives.Count)
    $chosen = $drives[[int]$sel]
}

Write-RipperLog INFO 'Register-Drive' "Selected drive $($chosen.Drive) ($($chosen.Name))."

# ---- AccurateRip offset lookup --------------------------------------------
$cachedList = Join-Path $repoRoot 'data\driveoffsets.cached.json'
Write-RipperLog INFO 'Register-Drive' 'Querying AccurateRip live driveoffsets page.'
$offset = Find-RipperAccurateRipOffset -DriveName $chosen.Name -CachedListPath $cachedList

if ($null -eq $offset) {
    Write-Warning "No AccurateRip offset found for drive '$($chosen.Name)'."
    # Offer the previously-saved offset (if any) as the default so a re-run
    # doesn't force you to retype it. Otherwise default to 0 with a warning.
    $defaultOffset = if ($existingCfg -and $null -ne $existingCfg.DriveOffset) { [int]$existingCfg.DriveOffset } else { 0 }
    $manual = Read-Host "Enter the offset in samples [$defaultOffset] (Enter = keep; AR verification unreliable if 0)"
    $offset = if ([string]::IsNullOrWhiteSpace($manual)) { $defaultOffset } else { [int]$manual }
}

Write-RipperLog INFO 'Register-Drive' "AccurateRip offset for $($chosen.Name) = $offset"

# ---- Persist to config.json ----------------------------------------------
$configPath = Get-RipperConfigPath
if (Test-Path -LiteralPath $configPath) {
    $cfg = Import-RipperConfig
} else {
    Write-Warning "config.json not found; creating a stub. Run New-RipperConfig.ps1 next to set the library root."
    $cfg = New-RipperConfigObject -LibraryRoot ([Environment]::GetFolderPath('MyMusic'))
}

# Win32_CDROMDrive.Drive is e.g. 'D:' — keep that exact form.
$cfg.DriveLetter = $chosen.Drive
$cfg.DriveOffset = $offset
$cfg | Save-RipperConfig

Write-Host "Drive $($chosen.Drive) registered with AccurateRip offset $offset." -ForegroundColor Green
Stop-RipperLog
