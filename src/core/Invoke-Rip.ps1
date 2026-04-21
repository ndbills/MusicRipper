<#
.SYNOPSIS
    Phase 4 rip engine: drive CUETools' .NET stack to produce per-track
    FLACs + EAC-style CUE + AccurateRip/CTDB-verified log for one disc.

.DESCRIPTION
    Pipeline position:
        Step 4 of the daily flow. Called from Start-Ripper.ps1 after the
        user confirms metadata in Show-RipperMetadataDialog. Writes to a
        per-disc folder under the configured output root; later phases
        (Test-RipQuality, Write-Tags, Move-ToLibrary) operate on that
        folder.

    Why this file exists (vs. just shelling to CUETools.Ripper.Console.exe):
        Per docs/PHASE-4-SPIKE.md (§5-6), the console ripper hard-codes
        WAV output, never emits a CUE sheet, derives filenames from the
        CTDB metadata it picks itself (not the user-confirmed metadata),
        and returns exit code 0 even on hard failures. Driving the same
        .NET DLLs the GUI uses (D-008 path) is the only way to get
        bit-exact FLACs, a CUE that matches user-confirmed track names,
        and real exception-based error handling.

    What this function DOES:
        1. Open the drive via CUETools.Ripper.SCSI.CDDriveReader.
           Apply DriveOffset + secure/burst/paranoid mode from config.
        2. Initialize AccurateRipVerify + CUEToolsDB. Best-effort online
           contact (offline = log a warning, keep ripping).
        3. Single straight-through read of the entire disc — slice into
           per-track FLAC files at sample boundaries. (Seeking interrupts
           AR/CTDB CRC accumulation and the secure-rip retry logic, so
           every secure ripper does it this way.)
        4. Each track: a fresh CUETools.Codecs.Flake.AudioEncoder with
           Vorbis comments pre-baked from confirmed metadata, FLAC L8.
           Append-to-previous pregap layout (D-002) — track N's pregap
           audio is encoded into file (N-1).
        5. Emit EAC-style CUE via Helpers.New-RipperCueSheet.
        6. Write cover.jpg if Metadata.CoverArtBytes present (Phase 5
           Write-Tags will embed it as APIC).
        7. Write <album>.log = AR.GenerateFullLog + CTDB.GenerateLog
           concatenated. Phase 5 Test-RipQuality re-derives a verdict
           from this file.
        8. Best-effort progress callback throughout — see -OnProgress.

    What this function does NOT do:
        - Embed cover art into the FLAC (Phase 5 Write-Tags.ps1's job;
          the cover.jpg sidecar is written here as input for it).
        - Move the rip to the music library (Phase 5 Move-ToLibrary).
        - Decide "good enough" — the returned Status is a best-effort
          rollup; Phase 5 Test-RipQuality re-evaluates from the on-disk
          log file.

.PARAMETER DiscIdInfo
    The pscustomobject returned by Get-RipperDiscId. We use:
        DiscId          (for AR.ContactAccurateRip)
        DriveLetter     (for the SCSI open)
        Tracks[]        (StartSector + LengthSectors per track — the
                         sample boundaries we slice on)

.PARAMETER Metadata
    The confirmed-metadata pscustomobject returned by
    Show-RipperMetadataDialog (Action='Rip' branch). Required fields:
        Album, AlbumArtist, Year, Genre (optional),
        Tracks=[{Number,Title,Artist}],
        CoverArtBytes (optional byte[]).

.PARAMETER OutputRoot
    Absolute path under which the per-disc folder is created.
    Folder name is "<AlbumArtist> - <Album>" (path-sanitized).

.PARAMETER OnProgress
    Optional scriptblock invoked frequently with a single hashtable arg:
        @{
            OverallFraction      = <0..1>             # of total disc samples read
            CurrentTrack         = <int>              # 1-based track number
            CurrentTrackTitle    = <string>
            CurrentTrackArtist   = <string>
            TotalTracks          = <int>
            CurrentTrackFraction = <0..1>             # of this track's samples
            FailedSectors        = <int>              # cumulative
            CorrectionMode       = 'Burst'|'Secure'|'Paranoid'
            ARStatus             = <string>           # AR contact status text
            ElapsedSeconds       = <double>
            BytesPerSecond       = <double>           # disc read throughput
        }
    Callbacks happen on the rip thread — the UI script must marshal to
    its dispatcher (see Show-RipProgress.ps1, Phase 4 step 3).

.PARAMETER CancelRequested
    Optional [ref] to a [bool]. The rip loop polls it between buffers
    and aborts cleanly (deletes partial files + the album folder).

.PARAMETER ContactNetwork
    Switch (default $true). When $false, skip AR/CTDB online contact —
    used by the smoke-test path so we don't slam those services during
    development. Logs are still emitted (with empty AR/CTDB sections).

.OUTPUTS
    pscustomobject:
        Status           : 'Verified' | 'ProbablyGood' | 'Suspect' |
                           'NotInDatabase' | 'Cancelled' | 'Failed'
        OutputDir        : absolute path to the per-disc folder
        FlacFiles        : @(filename, ...) under OutputDir
        CueFile          : <album>.cue under OutputDir
        LogFile          : <album>.log under OutputDir
        CoverArtFile     : cover.jpg or $null
        AccurateRip      : @{Status; MaxConfidence; Confidences=@()}
        Ctdb             : @{Status; Confidence}
        FailedSectors    : <int>
        ElapsedSeconds   : <double>
        Errors           : @() of warning strings (offline, etc.)
        HtoaWarning      : <string> | $null  (track 1 begins after sector 0)

.NOTES
    Requires Administrator privileges (CDDriveReader.Open uses raw SCSI;
    see gotcha #3 in the project state file). The Desktop shortcut is
    patched to RunAsAdministrator for exactly this reason.

    Voids must be piped to Out-Null:
        Open(), Close(), Dispose(), EjectDisk(), encoder.Close(),
        AR.Write(), AR.Close(), CTDB.DoVerify(), CTDB.Init(), etc.
    StrictMode 3 turns leaked return values into "property cannot be
    found" errors three calls downstream — see project gotcha #2.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')     -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1')    -Force
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')     -Force
Import-Module (Join-Path $repoRoot 'src\lib\RipHelpers.psd1') -Force

# Lazy DLL loading mirrors Get-DiscId.ps1's pattern. Loading at
# dot-source time would force every test that touches this file to
# have CUETools installed.
$script:RipAssembliesLoaded = $false

function Initialize-RipAssemblies {
    [CmdletBinding()]
    param()
    if ($script:RipAssembliesLoaded) { return }

    $cueDir = Get-CueToolsPath
    $dlls = @(
        # Already loaded by Get-DiscId for TOC reads, but Add-Type is
        # idempotent so double-loading the same path is a no-op.
        (Join-Path $cueDir 'CUETools.CDImage.dll'),
        (Join-Path $cueDir 'CUETools.Ripper.dll'),
        (Join-Path $cueDir 'plugins\CUETools.Ripper.SCSI.dll'),
        # New in Phase 4:
        (Join-Path $cueDir 'CUETools.Codecs.dll'),
        (Join-Path $cueDir 'plugins\CUETools.Codecs.Flake.dll'),
        (Join-Path $cueDir 'CUETools.AccurateRip.dll'),
        (Join-Path $cueDir 'CUETools.CTDB.dll'),
        (Join-Path $cueDir 'CUETools.CTDB.Types.dll')
    )
    foreach ($dll in $dlls) {
        if (-not (Test-Path -LiteralPath $dll)) {
            throw "Required CUETools DLL not found: $dll"
        }
        Add-Type -Path $dll
    }
    $script:RipAssembliesLoaded = $true
}

function Invoke-RipperRip {
<#
.SYNOPSIS
    Rip the inserted disc to per-track FLACs + CUE + log under OutputRoot.

.EXAMPLE
    PS> $r = Invoke-RipperRip -DiscIdInfo $disc -Metadata $meta `
            -OutputRoot 'D:\Rips\_inbox' -OnProgress { param($p) ... }
    PS> $r.Status
    Verified
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject]$DiscIdInfo,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string]$OutputRoot,
        [scriptblock]$OnProgress,
        [ref]$CancelRequested,
        [bool]$ContactNetwork = $true
    )

    Initialize-RipAssemblies

    $cfg = Import-RipperConfig
    if (-not $cfg.DriveOffset -and $cfg.DriveOffset -ne 0) {
        throw "Config has no DriveOffset. Run setup/Register-Drive.ps1 first."
    }

    # --- Output folder ------------------------------------------------------
    $folderName = "$(ConvertTo-SafeWindowsPathSegment $Metadata.AlbumArtist) - $(ConvertTo-SafeWindowsPathSegment $Metadata.Album)"
    $outDir     = Join-Path $OutputRoot $folderName
    if (-not (Test-Path -LiteralPath $OutputRoot)) {
        New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    }
    if (Test-Path -LiteralPath $outDir) {
        # Wipe a previous attempt: a partial rip from a crashed session must
        # not contaminate this one. The Phase-3 dialog already confirmed the
        # user wants to rip; we don't second-guess.
        Write-RipperLog WARN 'Invoke-Rip' "Output folder exists; wiping for fresh rip: $outDir"
        Remove-Item -LiteralPath $outDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    Write-RipperLog INFO 'Invoke-Rip' "Output folder: $outDir"

    # --- Open the drive -----------------------------------------------------
    $driveChar = ($DiscIdInfo.DriveLetter -replace '[^A-Za-z]', '').Substring(0,1).ToUpperInvariant()
    Write-RipperLog INFO 'Invoke-Rip' "Opening $driveChar`: for rip (offset=$($cfg.DriveOffset))."

    $reader = New-Object CUETools.Ripper.SCSI.CDDriveReader
    # NOTE: CDDriveReader internally lazy-creates its SCSI device handle on
    # Open(). Setting CorrectionQuality / DriveC2ErrorMode / DriveOffset
    # *before* Open() throws NullReferenceException because their setters
    # forward to that not-yet-created internal object. Open first, tune
    # second.

    $startTime     = [DateTime]::UtcNow
    $errors        = @()
    $progressCb    = $OnProgress
    $cancelRef     = $CancelRequested
    $cancelled     = $false
    $arStatusText  = 'pending'

    # Encoders we open during the rip — tracked so cancel/cleanup can
    # Delete() any in-progress encoder safely.
    $encoders = [System.Collections.Generic.List[object]]::new()

    try {
        try {
            $reader.Open([char]$driveChar) | Out-Null
        } catch {
            throw "Could not open drive $driveChar`: $($_.Exception.Message). Need Administrator + a disc inserted + no other CD app holding the drive."
        }

        # Tune AFTER Open(): see note above.
        $reader.DriveOffset       = [int]$cfg.DriveOffset
        $reader.CorrectionQuality = 1   # 1 = Secure (read each block twice). Default.
        $reader.DriveC2ErrorMode  = 0   # 0 = None. Most reliable on consumer drives.

        $toc       = $reader.TOC
        $pcm       = $reader.PCM
        $blockSize = [int]$reader.BestBlockSize
        if ($blockSize -le 0) { $blockSize = 27 }   # CUETools default

        $totalSamples = [int64]$reader.Length
        Write-RipperLog INFO 'Invoke-Rip' "Drive open. ARName='$($reader.ARName)' Length=$totalSamples samples ($([int]($totalSamples / 44100))s) Block=$blockSize sectors."

        # --- Init AR + CTDB -------------------------------------------------
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $ar = [CUETools.AccurateRip.AccurateRipVerify]::new($toc, $proxy)

        if ($ContactNetwork) {
            try {
                $ar.ContactAccurateRip($DiscIdInfo.DiscId) | Out-Null
                $arStatusText = [string]$ar.ARStatus
                Write-RipperLog INFO 'Invoke-Rip' "AccurateRip contact: $arStatusText"
            } catch {
                $errors += "AccurateRip offline: $($_.Exception.Message)"
                Write-RipperLog WARN 'Invoke-Rip' "AccurateRip contact failed: $($_.Exception.Message)"
            }
        } else {
            Write-RipperLog INFO 'Invoke-Rip' 'Skipping AR/CTDB online contact (ContactNetwork=$false).'
        }

        $ctdb = [CUETools.CTDB.CUEToolsDB]::new($toc, $proxy)
        $ctdb.Init($ar) | Out-Null
        if ($ContactNetwork) {
            try {
                # Args: server (null = default), userAgent, driveName,
                #       ctdb=$true, fuzzy=$true, metadataSearch=None(0).
                $ua = "MusicRipper/0.1 ( $($cfg.MusicBrainzContactEmail) )"
                $ctdb.ContactDB($null, $ua, [string]$reader.EACName, $true, $true, 0) | Out-Null
                Write-RipperLog INFO 'Invoke-Rip' "CTDB contact: $($ctdb.DBStatus)"
            } catch {
                $errors += "CTDB offline: $($_.Exception.Message)"
                Write-RipperLog WARN 'Invoke-Rip' "CTDB contact failed: $($_.Exception.Message)"
            }
        }

        # --- Per-track sample boundaries (append-to-previous pregap) -------
        # Track N's pregap = startSector(N) - (startSector(N-1) + length(N-1))
        # The pregap audio is encoded into file (N-1). So the encoder for
        # track i covers [startSamples(i), startSamples(i+1)) — i.e. its
        # OWN audio plus the trailing pregap of the NEXT track.
        $audioTracks = @($DiscIdInfo.Tracks | Where-Object { $_.IsAudio })
        $trackCount  = $audioTracks.Count
        $samplesPerSector = 588

        # boundaries[i] = first sample BELONGING to logical track i+1.
        # boundaries[trackCount] = totalSamples (= end of last file).
        $boundaries = New-Object 'System.Int64[]' ($trackCount + 1)
        for ($i = 0; $i -lt $trackCount; $i++) {
            $boundaries[$i] = [int64]$audioTracks[$i].StartSector * $samplesPerSector
        }
        $boundaries[$trackCount] = $totalSamples

        # HTOA detection — record a warning but do not encode. (Per spike §8
        # the HTOA-as-track-zero feature is deferred; we still surface the
        # fact so the user knows audio was discarded.)
        $htoaWarning = $null
        if ($boundaries[0] -gt 0) {
            $htoaWarning = "Track 1 begins at sample $($boundaries[0]) (sector $($audioTracks[0].StartSector)); pregap audio (Hidden Track) was not encoded."
            Write-RipperLog WARN 'Invoke-Rip' $htoaWarning
            $errors += $htoaWarning
        }

        # --- Build filenames + tags ----------------------------------------
        $isCompilation = $false
        $albumArtist   = [string]$Metadata.AlbumArtist
        foreach ($t in $Metadata.Tracks) {
            $artist = [string]$t.Artist
            if ($artist -and $artist -ne $albumArtist) { $isCompilation = $true; break }
        }

        $flacNames = New-Object 'System.String[]' $trackCount
        for ($i = 0; $i -lt $trackCount; $i++) {
            $tm = $Metadata.Tracks[$i]
            $params = @{
                TrackNumber  = [int]$tm.Number
                Title        = [string]$tm.Title
                TotalTracks  = $trackCount
            }
            if ($isCompilation) {
                $params.Artist        = [string]$tm.Artist
                $params.IsCompilation = $true
            }
            $flacNames[$i] = New-RipperTrackFileName @params
        }

        # --- Build per-track encoders --------------------------------------
        # We open them all up-front so the rip loop's "next track" branch is
        # cheap (just bump an index). Each encoder stays open until its
        # boundary is reached, then we Close() it and free the reference.
        $encSettings0 = [CUETools.Codecs.Flake.EncoderSettings]::new()
        $encSettings0.PCM         = $pcm
        $encSettings0.EncoderMode = '8'        # FLAC L8.
        $encSettings0.Padding     = 8192       # APIC headroom for Phase 5.
        $encSettings0.DoVerify    = $true
        $encSettings0.DoMD5       = $true
        $encSettings0.Validate()

        for ($i = 0; $i -lt $trackCount; $i++) {
            $settings = $encSettings0.Clone()
            $settings.Tags = _NewVorbisTags -Metadata $Metadata -TrackIndex $i `
                -DiscId $DiscIdInfo.DiscId -IsCompilation $isCompilation
            $path = Join-Path $outDir $flacNames[$i]
            $enc  = [CUETools.Codecs.Flake.AudioEncoder]::new($settings, $path, $null)
            $enc.FinalSampleCount = $boundaries[$i + 1] - $boundaries[$i]
            $encoders.Add($enc)
        }

        # --- The rip loop --------------------------------------------------
        $buf            = [CUETools.Codecs.AudioBuffer]::new($pcm, $blockSize * $samplesPerSector)
        $samplesRead    = [int64]0
        $currentTrack   = 0
        $lastProgressMs = -1000  # force first callback
        $stopwatch      = [Diagnostics.Stopwatch]::StartNew()

        while ($samplesRead -lt $totalSamples) {
            if ($cancelRef -and $cancelRef.Value) {
                Write-RipperLog WARN 'Invoke-Rip' 'Cancel requested — aborting rip.'
                $cancelled = $true
                break
            }

            $sectorsThisRead = $reader.Read($buf, $blockSize)
            if ($sectorsThisRead -le 0) {
                # End-of-disc or unrecoverable read error. Length should
                # already have been reached in the normal path; if not,
                # surface it.
                Write-RipperLog WARN 'Invoke-Rip' "reader.Read returned $sectorsThisRead at sample $samplesRead/$totalSamples — stopping."
                break
            }
            $samplesThisRead = [int64]$buf.Length

            # AR + CTDB always see the full buffer.
            $ar.Write($buf) | Out-Null

            # Slice into per-track encoder writes.
            $offset = [int64]0
            while ($offset -lt $samplesThisRead) {
                $absoluteStart = $samplesRead + $offset
                # Advance currentTrack until absoluteStart falls within
                # [boundaries[currentTrack], boundaries[currentTrack+1]).
                while ($currentTrack -lt ($trackCount - 1) -and
                       $absoluteStart -ge $boundaries[$currentTrack + 1]) {
                    $encoders[$currentTrack].Close() | Out-Null
                    $currentTrack++
                }
                $boundaryEnd = $boundaries[$currentTrack + 1]
                $remainingInRead = $samplesThisRead - $offset
                $remainingInTrack = $boundaryEnd - $absoluteStart
                $sliceLen = [int][Math]::Min($remainingInRead, $remainingInTrack)

                if ($sliceLen -eq $samplesThisRead -and $offset -eq 0) {
                    # Whole buffer fits inside the current track — fastest path.
                    $encoders[$currentTrack].Write($buf) | Out-Null
                } else {
                    # Need a slice. Build a temporary AudioBuffer over the
                    # same sample array but with a smaller logical length.
                    $slice = [CUETools.Codecs.AudioBuffer]::new($pcm, $sliceLen)
                    $slice.Prepare($buf, [int]$offset, [int]$sliceLen) | Out-Null
                    $encoders[$currentTrack].Write($slice) | Out-Null
                }
                $offset += $sliceLen
            }

            $samplesRead += $samplesThisRead

            # Throttle progress callbacks to ~10 Hz so the UI thread isn't
            # buried under marshaled invocations.
            $nowMs = [int]$stopwatch.ElapsedMilliseconds
            if ($progressCb -and ($nowMs - $lastProgressMs) -ge 100) {
                $lastProgressMs = $nowMs
                $tStart = $boundaries[$currentTrack]
                $tEnd   = $boundaries[$currentTrack + 1]
                $tFrac  = if ($tEnd -gt $tStart) {
                    [Math]::Min(1.0, ($samplesRead - $tStart) / [double]($tEnd - $tStart))
                } else { 0.0 }
                $tm = $Metadata.Tracks[$currentTrack]
                $elapsed = $stopwatch.Elapsed.TotalSeconds
                $bps     = if ($elapsed -gt 0) {
                    # 4 bytes/sample (16-bit stereo).
                    ($samplesRead * 4) / $elapsed
                } else { 0.0 }
                $failedCount = 0
                try {
                    foreach ($f in $reader.FailedSectors) {
                        if ($f) { $failedCount++ }
                    }
                } catch { $failedCount = 0 }

                $payload = @{
                    OverallFraction      = [double]$samplesRead / [double]$totalSamples
                    CurrentTrack         = [int]$tm.Number
                    CurrentTrackTitle    = [string]$tm.Title
                    CurrentTrackArtist   = [string]$tm.Artist
                    TotalTracks          = $trackCount
                    CurrentTrackFraction = $tFrac
                    FailedSectors        = $failedCount
                    CorrectionMode       = 'Secure'   # matches the value set above
                    ARStatus             = $arStatusText
                    ElapsedSeconds       = $elapsed
                    BytesPerSecond       = $bps
                }
                try { & $progressCb $payload } catch {
                    Write-RipperLog WARN 'Invoke-Rip' "OnProgress callback threw: $($_.Exception.Message)"
                }
            }
        }

        # --- Close remaining encoders -------------------------------------
        # (the rip loop only Close()s when crossing a boundary)
        if (-not $cancelled) {
            for ($i = $currentTrack; $i -lt $trackCount; $i++) {
                $encoders[$i].Close() | Out-Null
            }
        }

        if ($cancelled) {
            # Delete in-progress + everything else, then nuke the folder.
            for ($i = 0; $i -lt $trackCount; $i++) {
                try { $encoders[$i].Delete() | Out-Null } catch { }
            }
            $encoders.Clear()
            Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                Status         = 'Cancelled'
                OutputDir      = $null
                FlacFiles      = @()
                CueFile        = $null
                LogFile        = $null
                CoverArtFile   = $null
                AccurateRip    = @{ Status='cancelled'; MaxConfidence=$null; Confidences=@() }
                Ctdb           = @{ Status='cancelled'; Confidence=$null }
                FailedSectors  = 0
                ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
                Errors         = $errors
                HtoaWarning    = $htoaWarning
            }
        }

        # --- Finalize verification ----------------------------------------
        if ($ContactNetwork) {
            try { $ctdb.DoVerify() | Out-Null } catch {
                $errors += "CTDB verify failed: $($_.Exception.Message)"
                Write-RipperLog WARN 'Invoke-Rip' "CTDB verify failed: $($_.Exception.Message)"
            }
        }

        # --- Write CUE sheet ----------------------------------------------
        $cueText = New-RipperCueSheet `
            -Layout (_BuildLayoutShim -Tracks $audioTracks) `
            -Metadata (_AttachDiscId -Metadata $Metadata -DiscId $DiscIdInfo.DiscId) `
            -FlacFileNames $flacNames `
            -ToolTag "MusicRipper Phase4"
        $cueBaseName = ConvertTo-SafeWindowsPathSegment $Metadata.Album
        $cuePath     = Join-Path $outDir "$cueBaseName.cue"
        # CUE files are conventionally ASCII / Windows-1252 + CRLF. Use UTF-8
        # without BOM since modern parsers (foobar, CUETools, mpv) handle it
        # and our titles may contain non-ASCII.
        [System.IO.File]::WriteAllText($cuePath, $cueText, [System.Text.UTF8Encoding]::new($false))

        # --- Write log ----------------------------------------------------
        $logPath = Join-Path $outDir "$cueBaseName.log"
        $logText = _BuildRipLogText -AR $ar -Ctdb $ctdb -DiscIdInfo $DiscIdInfo `
            -Metadata $Metadata -Reader $reader -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
            -ContactNetwork:$ContactNetwork
        [System.IO.File]::WriteAllText($logPath, $logText, [System.Text.UTF8Encoding]::new($false))

        # --- Write cover art sidecar -------------------------------------
        $coverPath = $null
        $coverBytes = $null
        if ($Metadata.PSObject.Properties['CoverArtBytes']) {
            $coverBytes = $Metadata.CoverArtBytes
        }
        if ($coverBytes) {
            $coverPath = Join-Path $outDir 'cover.jpg'
            [System.IO.File]::WriteAllBytes($coverPath, [byte[]]$coverBytes)
            Write-RipperLog INFO 'Invoke-Rip' "Wrote cover.jpg ($($coverBytes.Length) bytes)."
        }

        # --- Build summary -----------------------------------------------
        $summary = Get-RipperLogSummary -LogText $logText
        $failedSectorCount = 0
        try {
            foreach ($f in $reader.FailedSectors) {
                if ($f) { $failedSectorCount++ }
            }
        } catch { }

        Write-RipperLog INFO 'Invoke-Rip' "Rip complete. Status=$($summary.Status) FailedSectors=$failedSectorCount Elapsed=$([int]$stopwatch.Elapsed.TotalSeconds)s"

        [pscustomobject]@{
            Status         = $summary.Status
            OutputDir      = $outDir
            FlacFiles      = @($flacNames)
            CueFile        = $cuePath
            LogFile        = $logPath
            CoverArtFile   = $coverPath
            AccurateRip    = $summary.AccurateRip
            Ctdb           = $summary.Ctdb
            FailedSectors  = $failedSectorCount
            ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
            Errors         = $errors
            HtoaWarning    = $htoaWarning
        }
    }
    catch {
        # Hard failure mid-rip: clean up encoders + folder, then rethrow.
        Write-RipperLog ERROR 'Invoke-Rip' "Rip failed: $($_.Exception.Message)"
        foreach ($e in $encoders) {
            try { $e.Delete() | Out-Null } catch { }
        }
        try { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        throw
    }
    finally {
        # Always release the drive (gotcha #2: pipe to Out-Null).
        try { $reader.Close()   | Out-Null } catch { }
        try { $reader.Dispose() | Out-Null } catch { }
    }
}

# --- Module-private helpers ------------------------------------------------

function _NewVorbisTags {
    # Build the Vorbis-comment string[] passed to EncoderSettings.Tags.
    # FLAC tag spec: https://xiph.org/flac/format.html#metadata_block_vorbis_comment
    param(
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [int]$TrackIndex,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [bool]$IsCompilation
    )
    $tm = $Metadata.Tracks[$TrackIndex]
    $tags = New-Object System.Collections.Generic.List[string]
    $tags.Add("ALBUM=$($Metadata.Album)")
    $tags.Add("ALBUMARTIST=$($Metadata.AlbumArtist)")
    $tags.Add("ARTIST=$(if ($tm.Artist) { $tm.Artist } else { $Metadata.AlbumArtist })")
    $tags.Add("TITLE=$($tm.Title)")
    $tags.Add("TRACKNUMBER=$($tm.Number)")
    $tags.Add("TRACKTOTAL=$($Metadata.Tracks.Count)")
    if ($Metadata.PSObject.Properties['Year']      -and $Metadata.Year)      { $tags.Add("DATE=$($Metadata.Year)") }
    if ($Metadata.PSObject.Properties['Genre']     -and $Metadata.Genre)     { $tags.Add("GENRE=$($Metadata.Genre)") }
    if ($IsCompilation)                                                      { $tags.Add('COMPILATION=1') }
    $tags.Add("MUSICBRAINZ_DISCID=$DiscId")
    if ($Metadata.PSObject.Properties['ReleaseMbid'] -and $Metadata.ReleaseMbid) {
        $tags.Add("MUSICBRAINZ_ALBUMID=$($Metadata.ReleaseMbid)")
    }
    $tags.ToArray()
}

function _BuildLayoutShim {
    # New-RipperCueSheet (RipHelpers) accepts either a CDImageLayout object
    # or a hashtable shaped { TrackCount, Tracks=[{...}] }. The objects we
    # already have from Get-RipperDiscId have IsAudio/StartSector/
    # LengthSectors/PreEmphasis exactly as the helper wants — so we just
    # assemble a shim hashtable (no need to construct a real CDImageLayout).
    param([Parameter(Mandatory)] $Tracks)
    @{
        TrackCount = $Tracks.Count
        Tracks     = @($Tracks)
    }
}

function _AttachDiscId {
    # The CUE generator expects Metadata.DiscId — our Phase 3 metadata
    # object doesn't carry it (DiscId belongs to the disc-id object, not
    # the metadata object). Add it before handing off.
    param([Parameter(Mandatory)] $Metadata, [Parameter(Mandatory)] [string]$DiscId)
    $clone = [pscustomobject]@{}
    foreach ($p in $Metadata.PSObject.Properties) {
        $clone | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
    $clone | Add-Member -NotePropertyName 'DiscId' -NotePropertyValue $DiscId -Force
    $clone
}

function _BuildRipLogText {
    # Concatenate AR.GenerateFullLog + CTDB.GenerateLog plus a small
    # MusicRipper header so Phase 5 Test-RipQuality has all the inputs
    # it needs in one file.
    param(
        [Parameter(Mandatory)] $AR,
        [Parameter(Mandatory)] $Ctdb,
        [Parameter(Mandatory)] $DiscIdInfo,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] $Reader,
        [Parameter(Mandatory)] [double]$ElapsedSeconds,
        [bool]$ContactNetwork = $true
    )
    $sw = [System.IO.StringWriter]::new()
    $sw.WriteLine("MusicRipper rip log")
    $sw.WriteLine("Date:        $(Get-Date -Format o)")
    $sw.WriteLine("Drive:       $($Reader.ARName)")
    $sw.WriteLine("Read mode:   Secure (CorrectionQuality=$($Reader.CorrectionQuality))")
    $sw.WriteLine("Drive offset: $($Reader.DriveOffset) samples")
    $sw.WriteLine("Album:       $($Metadata.AlbumArtist) - $($Metadata.Album)")
    $sw.WriteLine("Disc ID:     $($DiscIdInfo.DiscId)")
    $sw.WriteLine("Elapsed:     $([int]$ElapsedSeconds) s")
    $sw.WriteLine('')
    if ($ContactNetwork) {
        try { $AR.GenerateFullLog($sw, $false, $DiscIdInfo.DiscId) | Out-Null }
        catch { $sw.WriteLine("AccurateRip log generation failed: $($_.Exception.Message)") }
        $sw.WriteLine('')
        try { $Ctdb.GenerateLog($sw, $false) | Out-Null }
        catch { $sw.WriteLine("CTDB log generation failed: $($_.Exception.Message)") }
    } else {
        $sw.WriteLine('AccurateRip / CTDB sections skipped (offline mode).')
    }
    $sw.ToString()
}
