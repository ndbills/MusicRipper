<#
.SYNOPSIS
    Fast harness for verifying the AccurateRip + CTDB contact path
    WITHOUT actually ripping the disc.

.DESCRIPTION
    Real-disc-test-1 (commit ad69960) burned 11 minutes ripping just to
    discover both AR and CTDB went offline because of two one-line bugs
    in the contact phase. This script exercises ONLY that contact phase,
    against the real TOC of whatever disc is in the drive, in ~5 seconds.

    What it does:
      1. Opens the drive, reads the TOC. (No rip; same path Get-DiscId uses.)
      2. Loads CUETools assemblies via Invoke-Rip.ps1's loader.
      3. Calls AccurateRipVerify.CalculateAccurateRipId(toc) and prints it.
      4. Calls AR.ContactAccurateRip(<id>) and prints AR.ARStatus.
      5. Constructs CUEToolsDB(toc) and calls ContactDB(...) with the
         user-agent from config.json. Prints DBStatus.
      6. Reports a one-line summary so a successful run is obvious.

    Exit code 0 = both AR + CTDB contact succeeded (or returned a known
    non-error status like NotFoundInDatabase). Exit code 1 = at least
    one of them threw.

.EXAMPLE
    PS> pwsh -NoProfile -File tests\manual\Repro-VerifyContact.ps1
#>
[CmdletBinding()]
param(
    [string]$DriveLetter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path $repoRoot 'src\core\Get-DiscId.ps1')
. (Join-Path $repoRoot 'src\core\Invoke-Rip.ps1')
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force

# --- Resolve drive ---------------------------------------------------------
$cfg = Import-RipperConfig
if (-not $DriveLetter) {
    if (-not $cfg.DriveLetter) {
        throw "No DriveLetter passed and none in config. Run setup\Register-Drive.ps1."
    }
    $DriveLetter = $cfg.DriveLetter
}
$driveChar = ($DriveLetter -replace '[^A-Za-z]', '').Substring(0,1).ToUpperInvariant()

Write-Host ""
Write-Host "=== Repro-VerifyContact: drive $driveChar`: ===" -ForegroundColor Cyan

# --- Open drive, grab raw TOC ----------------------------------------------
Initialize-CueToolsAssemblies
Initialize-RipAssemblies

$reader = New-Object CUETools.Ripper.SCSI.CDDriveReader
$ok     = $true
try {
    try {
        $reader.Open([char]$driveChar) | Out-Null
    } catch {
        throw "Could not open drive $driveChar`: $($_.Exception.Message). Is a CD inserted?"
    }
    $toc = $reader.TOC
    if (-not $toc -or $toc.AudioTracks -eq 0) {
        throw "No audio TOC on drive $driveChar."
    }
    Write-Host ("TOC: {0} tracks ({1} audio), MusicBrainzId={2}" -f `
        $toc.TrackCount, $toc.AudioTracks, $toc.MusicBrainzId)

    # --- 1. AccurateRip -----------------------------------------------------
    Write-Host ""
    Write-Host "--- AccurateRip ---" -ForegroundColor Yellow
    $arDiscId = [CUETools.AccurateRip.AccurateRipVerify]::CalculateAccurateRipId($toc)
    Write-Host "  AR disc id: $arDiscId"

    $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $ar    = [CUETools.AccurateRip.AccurateRipVerify]::new($toc, $proxy)
    try {
        $ar.ContactAccurateRip($arDiscId) | Out-Null
        Write-Host "  ARStatus  : $($ar.ARStatus)" -ForegroundColor Green
        if ($ar.AccDisks -and $ar.AccDisks.Count -gt 0) {
            Write-Host "  AR pressings found: $($ar.AccDisks.Count)" -ForegroundColor Green
        }
    } catch {
        $ok = $false
        Write-Host "  AR FAILED : $($_.Exception.Message)" -ForegroundColor Red
    }

    # --- 2. CTDB ------------------------------------------------------------
    Write-Host ""
    Write-Host "--- CTDB ---" -ForegroundColor Yellow
    $ctdb = [CUETools.CTDB.CUEToolsDB]::new($toc, $proxy)
    $ctdb.Init($ar) | Out-Null
    try {
        $ua = [string]$cfg.MusicBrainzUserAgent
        if (-not $ua) { throw "config.json missing MusicBrainzUserAgent." }
        Write-Host "  UA        : $ua"
        $ctdb.ContactDB('db.cuetools.net', $ua, [string]$reader.EACName, $true, $true, 0) | Out-Null
        Write-Host "  DBStatus  : $($ctdb.DBStatus)" -ForegroundColor Green
    } catch {
        $ok = $false
        Write-Host "  CTDB FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}
finally {
    $reader.Close()   | Out-Null
    $reader.Dispose() | Out-Null
}

Write-Host ""
if ($ok) {
    Write-Host "OK: AR + CTDB contact path is healthy." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL: at least one contact call threw. See above." -ForegroundColor Red
    exit 1
}
