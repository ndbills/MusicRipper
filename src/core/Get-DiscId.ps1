<#
.SYNOPSIS
    Read the TOC of an inserted Audio CD and return its MusicBrainz disc ID
    plus per-track timing.

.DESCRIPTION
    Pipeline position:
        Step 1 of the daily-flow sequence (after Start-Ripper.ps1 picks up
        a disc-insert event). The output object feeds Get-DiscMetadata.ps1.

    Implementation: we load CUETools' .NET assemblies (CUETools.CDImage.dll,
    CUETools.Ripper.dll, plugins/CUETools.Ripper.SCSI.dll) directly via
    Add-Type rather than shelling out to a CLI tool. CUETools 2.2.6 ships
    no "print disc id" CLI mode (its console ripper only knows how to
    rip), but the same .NET types its GUI uses are loadable from
    PowerShell. See docs/DECISIONS.md D-008.

    This file defines the function and, when dot-sourced, leaves it in
    scope. It does NOT execute against a drive at import time.

.NOTES
    Requires: CUETools installed (winget portable install located via
    Get-CueToolsPath in src/lib/Common.psm1).

    The CDDriveReader implementation talks SCSI directly, which Windows
    permits to a non-elevated process IF the user has interactive logon
    rights and the drive isn't held by another app (e.g. CUERipper.exe
    open to the same drive). Surface "Access is denied" with a clear
    message rather than the raw HRESULT.

    Reference: https://github.com/gchudov/cuetools.net (CUETools source).
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Module imports done at dot-source time so Get-RipperDiscId can be invoked
# stand-alone (e.g. from a PowerShell prompt for debugging) without the
# caller needing to know the dependency graph.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

# CUETools assemblies are loaded lazily on the first Get-RipperDiscId call so
# that simply dot-sourcing this file (e.g. from a unit test or another
# module) doesn't hard-fail if CUETools isn't installed.
$script:CueToolsAssembliesLoaded = $false

function Initialize-CueToolsAssemblies {
<#
.SYNOPSIS
    Add-Type the three CUETools DLLs needed for disc-id reading. Idempotent.
.NOTES
    Internal helper. Not exported.
#>
    [CmdletBinding()]
    param()
    if ($script:CueToolsAssembliesLoaded) { return }

    $cueDir = Get-CueToolsPath
    $dlls = @(
        (Join-Path $cueDir 'CUETools.CDImage.dll'),
        (Join-Path $cueDir 'CUETools.Ripper.dll'),
        (Join-Path $cueDir 'plugins\CUETools.Ripper.SCSI.dll')
    )
    foreach ($dll in $dlls) {
        if (-not (Test-Path -LiteralPath $dll)) {
            throw "Required CUETools DLL not found: $dll"
        }
        Add-Type -Path $dll
    }
    $script:CueToolsAssembliesLoaded = $true
}

function Get-RipperDiscId {
<#
.SYNOPSIS
    Read the TOC of the disc in the given drive and return identifiers
    plus per-track timing data.

.DESCRIPTION
    Opens the drive via CUETools' CDDriveReader, snapshots the TOC, closes
    the drive immediately (we don't hold it open across the metadata
    network round-trip — a parent walking by could hit the eject button).

    The returned object is the contract Get-DiscMetadata.ps1 consumes:

        DiscId           : MusicBrainz disc ID (Base-64-ish 28-char string)
        MusicBrainzToc   : The TOC argument MB accepts as a fallback when
                           the disc ID isn't in their database
                           (?toc=1+11+...).
        CtdbId           : CUETools Database TOC ID (used in Phase 4-5).
        TrackCount       : Total tracks (audio + data).
        AudioTracks      : Audio-only count.
        DurationSeconds  : Total disc length in seconds.
        DriveLetter      : The drive that was read (echoed back so the
                           caller can carry it forward).
        Tracks           : Array of per-track records:
                             { Number, IsAudio, StartSector, LengthSectors,
                               LengthSeconds, PreEmphasis }

.PARAMETER DriveLetter
    Single letter (e.g. 'D') or 'D:'. If omitted, falls back to the
    DriveLetter saved in config.json (set by setup/Register-Drive.ps1).

.EXAMPLE
    PS> $disc = Get-RipperDiscId
    PS> $disc.DiscId
    Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-

.EXAMPLE
    PS> Get-RipperDiscId -DriveLetter 'E'

.NOTES
    Throws on:
        - No disc inserted (drive opens but TOC has zero audio tracks).
        - Drive busy / held by another app.
        - CUETools not installed.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$DriveLetter
    )

    Initialize-CueToolsAssemblies

    # Resolve the drive: explicit param > config > error.
    if (-not $DriveLetter) {
        Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1') -Force
        $cfg = Import-RipperConfig
        if (-not $cfg.DriveLetter) {
            throw "No DriveLetter passed and none saved in config. Run setup/Register-Drive.ps1."
        }
        $DriveLetter = $cfg.DriveLetter
    }
    # Normalize 'D:' / 'D:\' / 'D' all to a single char.
    $driveChar = ($DriveLetter -replace '[^A-Za-z]', '').Substring(0,1).ToUpperInvariant()

    Write-RipperLog INFO 'Get-DiscId' "Opening drive $driveChar`: for TOC read."

    $reader = New-Object CUETools.Ripper.SCSI.CDDriveReader
    try {
        try {
            # Pipe to Out-Null: some CUETools versions return non-void from
            # Open() (e.g. a status struct), which would leak straight into
            # our function's output and break `$disc.DiscId` downstream.
            $reader.Open([char]$driveChar) | Out-Null
        } catch {
            # The most common failure (no disc / tray open) bubbles up as
            # E_ACCESSDENIED — make the message useful instead of cryptic.
            throw "Could not open drive $driveChar`: $($_.Exception.Message). Is a CD inserted? Is another program (e.g. CUERipper) using the drive?"
        }

        $toc = $reader.TOC
        if (-not $toc -or $toc.AudioTracks -eq 0) {
            throw "Drive $driveChar opened but reports no audio tracks. Is this an Audio CD?"
        }

        # Build per-track array. CDImageLayout's indexer is 1-based.
        $tracks = for ($i = 1; $i -le $toc.TrackCount; $i++) {
            $t = $toc.Item($i)
            [pscustomobject]@{
                Number        = [int]$t.Number
                IsAudio       = [bool]$t.IsAudio
                StartSector   = [int64]$t.Start
                LengthSectors = [int64]$t.Length
                # CD audio is exactly 75 sectors per second.
                LengthSeconds = [math]::Round([double]$t.Length / 75.0, 3)
                PreEmphasis   = [bool]$t.PreEmphasis
            }
        }

        $result = [pscustomobject]@{
            DiscId          = [string]$toc.MusicBrainzId
            MusicBrainzToc  = [string]$toc.MusicBrainzTOC
            CtdbId          = [string]$toc.TOCID
            TrackCount      = [int]$toc.TrackCount
            AudioTracks     = [int]$toc.AudioTracks
            DurationSeconds = [math]::Round([double]$toc.AudioLength / 75.0, 3)
            DriveLetter     = "$driveChar`:"
            Tracks          = @($tracks)
        }

        Write-RipperLog INFO 'Get-DiscId' "TOC read: DiscId=$($result.DiscId), $($result.AudioTracks) audio tracks, $([int]$result.DurationSeconds)s."
        $result
    }
    finally {
        # Always release the drive — leaving it open blocks every other
        # CD app on the system until the PowerShell process exits.
        # Pipe to Out-Null because some CUETools versions return non-void
        # from Close()/Dispose() and would otherwise pollute our pipeline
        # output (turning the function's return into an array and breaking
        # downstream `$disc.DiscId` access under StrictMode).
        $reader.Close()   | Out-Null
        $reader.Dispose() | Out-Null
    }
}
