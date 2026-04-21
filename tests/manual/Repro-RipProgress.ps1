<#
.SYNOPSIS
    Fast repro harness for the Show-RipperRipProgress post-rip NRE.

.DESCRIPTION
    Bypasses the 11-minute rip by stubbing Invoke-RipperRip with a
    scriptblock that emits a few synthetic progress payloads then
    returns a fake-but-shape-correct rip result. Drives the WPF window
    through the exact same runspace + dispatcher sequence as the real
    Action='Rip' path, so any teardown bug reproduces in ~3 seconds.

.NOTES
    Uses env var MUSICRIPPER_RIP_STUB to point Show-RipProgress at a
    fake Invoke-Rip.ps1 that lives next to this harness.
#>

[CmdletBinding()] param([int]$DurationSeconds = 3)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $repoRoot -or -not (Test-Path (Join-Path $repoRoot 'src\ui\Show-RipProgress.ps1'))) {
    # Fall back to walking up from this file's location.
    $repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
}

Remove-Item "$env:TEMP\musicripper-ui-error.log" -ErrorAction SilentlyContinue

# --- Synthesize Metadata + DiscIdInfo shapes matching real Phase 2/3 -------
$tracks = 1..3 | ForEach-Object {
    [pscustomobject]@{
        Number        = $_
        IsAudio       = $true
        StartSector   = 150 + ($_ - 1) * 1000
        LengthSectors = 1000
        Pregap        = 0
        Title         = "Stub Track $_"
        Artist        = 'Stub Artist'
    }
}
$disc = [pscustomobject]@{
    DiscId      = 'stub-disc-id'
    DriveLetter = 'F:'
    Tracks      = $tracks
    TrackCount  = 3
    AudioTracks = 3
}
$meta = [pscustomobject]@{
    Album        = 'Stub Album'
    AlbumArtist  = 'Stub Artist'
    Year         = 2026
    TrackCount   = 3
    Tracks       = $tracks
    ReleaseMbid  = 'stub-mbid'
}

# --- Write a stub Invoke-Rip.ps1 that the runspace can dot-source -----------
$stubDir  = Join-Path $env:TEMP 'musicripper-stub'
New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
$stubPath = Join-Path $stubDir 'Invoke-Rip-Stub.ps1'

$stubBody = @'
function Invoke-RipperRip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $DiscIdInfo,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string]$OutputRoot,
        [scriptblock]$OnProgress,
        [ref]$CancelRequested,
        [bool]$ContactNetwork = $true
    )
    $totalTicks = __DURATION__ * 10
    for ($i = 1; $i -le $totalTicks; $i++) {
        if ($CancelRequested -and $CancelRequested.Value) { break }
        if ($OnProgress) {
            $frac = $i / [double]$totalTicks
            $payload = @{
                OverallFraction      = $frac
                CurrentTrack         = [int][Math]::Min(3, [Math]::Ceiling($frac * 3))
                CurrentTrackTitle    = "Stub Track"
                CurrentTrackArtist   = "Stub Artist"
                TotalTracks          = 3
                CurrentTrackFraction = $frac
                FailedSectors        = 0
                CorrectionMode       = 'Secure'
                ARStatus             = 'pending'
                ElapsedSeconds       = $i / 10.0
                BytesPerSecond       = 1MB
            }
            try { & $OnProgress $payload } catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    [pscustomobject]@{
        Status         = 'ProbablyGood'
        OutputDir      = $OutputRoot
        FlacFiles      = @('01 - Stub.flac','02 - Stub.flac','03 - Stub.flac')
        CueFile        = 'Stub Album.cue'
        LogFile        = 'Stub Album.log'
        CoverArtFile   = $null
        AccurateRip    = [pscustomobject]@{ Status='NotInDatabase'; MatchedTracks=0; TotalTracks=3; MinConfidence=$null }
        Ctdb           = [pscustomobject]@{ Status='Unknown'; MinConfidence=$null }
        FailedSectors  = 0
        ElapsedSeconds = __DURATION__
        Errors         = @()
        HtoaWarning    = $null
    }
}
'@
$stubBody = $stubBody.Replace('__DURATION__', [string]$DurationSeconds)
Set-Content -LiteralPath $stubPath -Value $stubBody -Encoding UTF8

# Tell Show-RipProgress to dot-source the stub instead of the real one.
$env:MUSICRIPPER_RIP_STUB = $stubPath

# --- Load the UI under test and run it --------------------------------------
. (Join-Path $repoRoot 'src\ui\Show-RipProgress.ps1')

$outRoot = Join-Path $env:TEMP 'musicripper-stub-out'
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

Write-Host "Running stubbed rip ($DurationSeconds s)..."
try {
    $result = Show-RipperRipProgress -DiscIdInfo $disc -Metadata $meta -OutputRoot $outRoot -ContactNetwork $false
    Write-Host "OK: result.Status = $($result.Status)" -ForegroundColor Green
} catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "ScriptStackTrace:`n$($_.ScriptStackTrace)" -ForegroundColor Yellow
} finally {
    Remove-Item Env:\MUSICRIPPER_RIP_STUB -ErrorAction SilentlyContinue
    if (Test-Path "$env:TEMP\musicripper-ui-error.log") {
        Write-Host "`n--- Sidecar log ---" -ForegroundColor Cyan
        Get-Content "$env:TEMP\musicripper-ui-error.log"
    } else {
        Write-Host "`n(no sidecar log emitted)" -ForegroundColor DarkGray
    }
}
