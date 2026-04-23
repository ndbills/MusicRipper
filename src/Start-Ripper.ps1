<#
.SYNOPSIS
    Entry point parents click. Phases 1-5: config check, disc-id read,
    MusicBrainz lookup, confirmation dialog, secure rip, quality gate,
    tag + ReplayGain, library/_ReviewQueue placement.

.DESCRIPTION
    Pipeline position:
        Top of the daily-flow sequence:
            ... -> Show-MetadataDialog -> Invoke-Rip ->
            Test-RipQuality -> Write-Tags (library only) ->
            Move-ToLibrary -> Write-RipperReviewTxt +
            New-RipperReviewImage (review queue only) -> eject.

    Current behavior:
        - Loads config; aborts gracefully if missing.
        - If a disc is in the configured drive, reads its TOC
          (Get-RipperDiscId) and queries MusicBrainz
          (Get-RipperDiscMetadata).
        - Pops the Phase 3 confirmation dialog
          (Show-RipperMetadataDialog) so the user can review/edit
          metadata. "Re-search MusicBrainz" wires straight back into
          Get-RipperDiscMetadata.
        - Action='Rip'    -> Phase 4 stub message (no rip yet).
        - Action='Review' -> Phase 5 stub message + ejects.
        - Action='Cancel' -> ejects and exits cleanly.
        - On no-disc / no-match / offline, surfaces the status and
          (where useful) still pops the dialog so the user can choose
          "Send to Review".

.EXAMPLE
    PS> ./src/Start-Ripper.ps1

.NOTES
    Designed to be safe to run with no disc inserted — that path just
    reports "no disc" instead of throwing.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force

# Dot-source the Phase 2/3/4/5 core scripts and dialogs so their functions
# are in scope.
. (Join-Path $repoRoot 'src\core\Get-DiscId.ps1')
. (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
. (Join-Path $repoRoot 'src\core\Search-DiscMetadataByText.ps1')
. (Join-Path $repoRoot 'src\core\Invoke-Rip.ps1')
. (Join-Path $repoRoot 'src\core\Test-RipQuality.ps1')
. (Join-Path $repoRoot 'src\core\Write-Tags.ps1')
. (Join-Path $repoRoot 'src\core\Move-ToLibrary.ps1')
. (Join-Path $repoRoot 'src\core\New-ReviewQueueArtifacts.ps1')
. (Join-Path $repoRoot 'src\core\Invoke-PostProcess.ps1')
. (Join-Path $repoRoot 'src\core\Resume.ps1')
. (Join-Path $repoRoot 'src\ui\Show-MetadataDialog.ps1')
. (Join-Path $repoRoot 'src\ui\Show-RipProgress.ps1')

$logPath = Start-RipperLog -Context 'start-ripper'
Write-RipperLog INFO 'Start-Ripper' 'Phase 5 entry: config + disc-id + metadata + confirm + rip + quality/tag/move.'

# --- Helpers ---------------------------------------------------------------
function Show-RipperInfo([string]$msg, [string]$title = 'MusicRipper', [string]$icon = 'Information') {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($msg, $title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$icon) | Out-Null
}

function Invoke-RipperEject {
    # Best-effort eject of the configured drive. Failure is non-fatal —
    # we just log it and move on (the user can pop it manually).
    if (-not $cfg.DriveLetter) { return }
    try {
        $shell = New-Object -ComObject Shell.Application
        $drive = $shell.Namespace(17).ParseName($cfg.DriveLetter)
        if ($drive) {
            $drive.InvokeVerb('Eject') | Out-Null
            Write-RipperLog INFO 'Start-Ripper' "Ejected $($cfg.DriveLetter)."
        }
    } catch {
        Write-RipperLog WARN 'Start-Ripper' "Eject failed: $($_.Exception.Message)"
    }
}

function Close-RipperTray {
    # Best-effort close of an open tray on the configured drive. Used before
    # the disc-id read so a parent who left the tray hanging open doesn't
    # immediately get a "no disc" error.
    #
    # Why MCI and not Shell.Application: the shell's "Close" verb is
    # unreliable across Windows versions (sometimes hidden, sometimes named
    # differently per locale). `mciSendString` is the Win32-supported way to
    # drive the tray and works regardless of locale.
    #
    # Drive selection: MCI's `!<drive>` selector wants the bare letter (e.g.
    # "D"), not "D:". We strip the colon if present.
    if (-not $cfg.DriveLetter) { return }
    $letter = ($cfg.DriveLetter -replace '[:\\]','').ToUpperInvariant()
    if ($letter.Length -ne 1) { return }

    if (-not ('MusicRipper.Mci' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @'
using System.Runtime.InteropServices;
namespace MusicRipper {
    public static class Mci {
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int mciSendString(
            string lpstrCommand, System.Text.StringBuilder lpstrReturnString,
            int uReturnLength, System.IntPtr hwndCallback);
    }
}
'@
    }

    $alias = "ripper_cd_$letter"
    $rb    = [System.Text.StringBuilder]::new(128)
    try {
        # Open the device (idempotent if already open under another alias).
        [void][MusicRipper.Mci]::mciSendString(
            "open $($cfg.DriveLetter) type CDAudio alias $alias", $rb, 128, [System.IntPtr]::Zero)
        $rc = [MusicRipper.Mci]::mciSendString(
            "set $alias door closed wait", $rb, 128, [System.IntPtr]::Zero)
        [void][MusicRipper.Mci]::mciSendString(
            "close $alias", $rb, 128, [System.IntPtr]::Zero)
        if ($rc -eq 0) {
            Write-RipperLog INFO 'Start-Ripper' "Closed tray on $($cfg.DriveLetter) (or it was already closed)."
        } else {
            Write-RipperLog INFO 'Start-Ripper' "Tray-close on $($cfg.DriveLetter) returned MCI rc=$rc (non-fatal)."
        }
    } catch {
        Write-RipperLog WARN 'Start-Ripper' "Tray-close failed: $($_.Exception.Message)"
    }
}

# --- Config check ----------------------------------------------------------
$configPath = Get-RipperConfigPath
if (-not (Test-Path -LiteralPath $configPath)) {
    Show-RipperInfo "Config not found at $configPath.`n`nRun setup\New-RipperConfig.ps1 first." `
        'MusicRipper' 'Warning'
    Stop-RipperLog
    return
}
$cfg = Import-RipperConfig

# --- Dependency check -----------------------------------------------------
# We do this BEFORE any disc work because a missing metaflac.exe would
# only surface AFTER the rip (Phase 5 needs it for tagging + ReplayGain),
# wasting an 11-minute rip. Idempotent flow: if anything is missing,
# offer to run setup/Install-Dependencies.ps1 in-place, then ask the
# user to relaunch. A subsequent launch finds everything and proceeds.
$deps = Test-RipperDependencies
if (-not $deps.Ok) {
    $list   = ($deps.Missing | ForEach-Object { "  - $($_.Name)  (winget id: $($_.WingetId))" }) -join "`n"
    $names  = ($deps.Missing.Name) -join ', '
    Write-RipperLog WARN 'Start-Ripper' "Missing dependencies: $names"

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $rc = [System.Windows.Forms.MessageBox]::Show(
        "MusicRipper needs the following tools, which aren't installed yet:`n`n$list`n`nInstall them now via winget? (you may see an admin elevation prompt)",
        'MusicRipper - Missing Dependencies',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)

    if ($rc -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-RipperLog WARN 'Start-Ripper' 'User declined dependency install.'
        Show-RipperInfo "MusicRipper can't continue without those tools.`n`nRun setup\Install-Dependencies.ps1 manually when ready, then re-launch." `
            'MusicRipper' 'Information'
        Stop-RipperLog
        return
    }

    $installScript = Join-Path $repoRoot 'setup\Install-Dependencies.ps1'
    Write-RipperLog INFO 'Start-Ripper' "Running $installScript"
    try {
        & $installScript
    } catch {
        Write-RipperLog ERROR 'Start-Ripper' "Install-Dependencies failed: $($_.Exception.Message)"
        Show-RipperInfo "Dependency install failed:`n`n  $($_.Exception.Message)`n`nSee log:`n  $logPath" `
            'MusicRipper - Install Failed' 'Error'
        Stop-RipperLog
        return
    }

    Write-RipperLog INFO 'Start-Ripper' 'Dependency installer finished. Asking user to relaunch.'
    Show-RipperInfo "Dependencies installed.`n`nPlease re-launch MusicRipper to continue." `
        'MusicRipper' 'Information'
    Stop-RipperLog
    return
}

# --- Resume orphaned rips --------------------------------------------------
# Any folder under <LibraryRoot>\_inbox\ that still has _ripper-state.json
# is a rip whose post-process never finished (crash, power loss, manual exit
# between Invoke-Rip and Invoke-RipperPostProcess). Offer to finish them now
# before touching the drive — running the disc-id step would be wasted work
# if the user wants to bail out and recover by hand instead.
$orphans = @(Find-RipperOrphanedRips -LibraryRoot $cfg.LibraryRoot)
if ($orphans.Count -gt 0) {
    $names = ($orphans | ForEach-Object { "  - $(Split-Path -Leaf $_.Folder)" }) -join "`n"
    Write-RipperLog INFO 'Start-Ripper' "Found $($orphans.Count) orphaned rip(s)."

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $rc = [System.Windows.Forms.MessageBox]::Show(
        "MusicRipper found $($orphans.Count) unfinished rip(s) in your inbox:`n`n$names`n`nFinish them now? (Tag, ReplayGain, and move to your library / review queue.)`n`nYes = process them all`nNo  = skip and continue with today's disc`nCancel = quit",
        'MusicRipper - Resume Unfinished Rips',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)

    if ($rc -eq [System.Windows.Forms.DialogResult]::Cancel) {
        Write-RipperLog INFO 'Start-Ripper' 'User cancelled at orphan-resume prompt.'
        Stop-RipperLog
        return
    }
    if ($rc -eq [System.Windows.Forms.DialogResult]::Yes) {
        $resumeFails = @()
        foreach ($orphan in $orphans) {
            try {
                $rpp = Resume-RipperOrphan -RipFolder $orphan.Folder -LibraryRoot $cfg.LibraryRoot
                Write-RipperLog INFO 'Start-Ripper' "Resumed orphan -> $($rpp.Target)"
            } catch {
                Write-RipperLog ERROR 'Start-Ripper' "Resume failed for $($orphan.Folder): $($_.Exception.Message)"
                $resumeFails += [pscustomobject]@{ Folder = $orphan.Folder; Error = $_.Exception.Message }
            }
        }
        if ($resumeFails.Count -gt 0) {
            $failList = ($resumeFails | ForEach-Object { "  - $(Split-Path -Leaf $_.Folder): $($_.Error)" }) -join "`n"
            Show-RipperInfo "Some orphan rips could not be finished:`n`n$failList`n`nThe sidecars are still in place — try again next launch, or use src\tools\Complete-OrphanedRip.ps1." `
                'MusicRipper - Resume Issues' 'Warning'
        }
    } else {
        Write-RipperLog INFO 'Start-Ripper' 'User chose to skip orphan resume.'
    }
}

# --- Read disc -------------------------------------------------------------
# If the tray was left open, close it first so the user doesn't get an
# immediate "no disc" error. After a close, the drive needs a beat to spin
# up and report the TOC, so we retry a few times on transient "not ready"
# errors before giving up.
Close-RipperTray

$disc          = $null
$lastDiscError = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        $disc = Get-RipperDiscId
        break
    } catch {
        $lastDiscError = $_
        $msg = $_.Exception.Message
        if ($msg -match 'not ready|medium not present|tray open|no disc') {
            Write-RipperLog INFO 'Start-Ripper' "Drive not ready (attempt $attempt/5); waiting for spin-up."
            Start-Sleep -Seconds 2
            continue
        }
        # Non-transient error: don't burn retries on it.
        break
    }
}

if (-not $disc) {
    Write-RipperLog WARN 'Start-Ripper' "Disc-id failed: $($lastDiscError.Exception.Message)"
    Show-RipperInfo "No disc / drive error:`n`n  $($lastDiscError.Exception.Message)`n`nInsert a CD and try again." `
        'MusicRipper' 'Warning'
    Stop-RipperLog
    return
}

# --- Metadata lookup -------------------------------------------------------
try {
    $meta = Get-RipperDiscMetadata -DiscIdInfo $disc
} catch {
    Write-RipperLog WARN 'Start-Ripper' "Metadata failed: $($_.Exception.Message)"
    # Synthesize an Offline-style result so the dialog still comes up and
    # the user can route to Review.
    $meta = [pscustomobject]@{
        DiscId     = $disc.DiscId
        Status     = 'Offline'
        BestMatch  = $null
        Candidates = @()
    }
}

# --- Phase 3: confirmation dialog ------------------------------------------
$onResearch = {
    Write-RipperLog INFO 'Start-Ripper' "Re-search MusicBrainz requested for $($disc.DiscId)."
    Get-RipperDiscMetadata -DiscIdInfo $disc
}

# Pull the cover-art chain across each text-search hit so the dialog
# can render an image once the user picks one. Failures are non-fatal
# (same convention as the disc-id flow): the picked candidate just
# shows up without a cover.
#
# Two-tier strategy:
#   1. iTunes/Deezer text-search candidates carry an .ArtworkUrl from
#      their original metadata response (the same response that gave us
#      the artist/album/tracks). One HTTP GET fetches the bytes — no
#      AlbumArtist+Album guesswork needed, which is critical for
#      compilations and multi-artist titles where the re-query would
#      miss.
#   2. Anything without an .ArtworkUrl (MusicBrainz, GnuDB) falls
#      through to the full Get-RipperBestCoverArt provider chain.
$onTextSearch = {
    param($payload)
    Write-RipperLog INFO 'Start-Ripper' "Text-search requested: artist='$($payload.Artist)' album='$($payload.Album)' year=$($payload.Year) providers=$(@($payload.Providers) -join ',')"
    $r = Search-RipperMetadataByText `
            -Artist    $payload.Artist `
            -Album     $payload.Album `
            -Year      $payload.Year `
            -Providers @($payload.Providers)
    if ($r -and $r.Candidates) {
        foreach ($c in @($r.Candidates)) {
            $bytes = $null
            $directUrl = if (($c.PSObject.Properties.Name -contains 'ArtworkUrl') -and $c.ArtworkUrl) {
                [string]$c.ArtworkUrl
            } else { $null }
            if ($directUrl) {
                try {
                    $tmp = [System.IO.Path]::GetTempFileName()
                    try {
                        Invoke-WebRequest -Uri $directUrl -OutFile $tmp -TimeoutSec 30 -UseBasicParsing | Out-Null
                        $bytes = [System.IO.File]::ReadAllBytes($tmp)
                        Write-RipperLog INFO 'Start-Ripper' "Cover-art (direct, $($c.Source)): $($bytes.Length) bytes from $directUrl"
                    } finally {
                        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                    }
                } catch {
                    Write-RipperLog WARN 'Start-Ripper' "Cover-art direct fetch failed for $($c.Source) '$($c.Album)': $($_.Exception.Message)"
                    $bytes = $null
                }
            }
            if (-not $bytes) {
                try {
                    $bytes = Get-RipperBestCoverArt -Candidate $c
                } catch {
                    $bytes = $null
                }
            }
            $c | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue $bytes -Force
        }
    }
    $r
}

$textSearchProviders = @(Get-RipperTextSearchProviderNames)

# Phase 5.3: "Change cover…" picker. Runs every configured provider
# (not short-circuit like Get-RipperBestCoverArt) so the user can
# compare all available images side-by-side. The dialog hides the
# button when -OnPickCover is not supplied, so this is purely opt-in.
$onPickCover = {
    param($candidate)
    Write-RipperLog INFO 'Start-Ripper' "Cover-picker requested for '$($candidate.AlbumArtist) / $($candidate.Album)'."
    Get-RipperCoverArtCandidates -Candidate $candidate
}

$choice = Show-RipperMetadataDialog `
            -Metadata             $meta `
            -OnResearch           $onResearch `
            -OnTextSearch         $onTextSearch `
            -TextSearchProviders  $textSearchProviders `
            -OnPickCover          $onPickCover `
            -EjectAfterRip        ($(if ($cfg.PSObject.Properties['EjectAfterRip']) { [bool]$cfg.EjectAfterRip } else { $true }))

Write-RipperLog INFO 'Start-Ripper' "User chose: $($choice.Action) (eject=$($choice.EjectAfterRip))."

# Honour the per-rip eject decision the user just made in the dialog
# (seeded from cfg.EjectAfterRip but flippable via the checkbox).
# Wrapper instead of inline guards so every existing Invoke-RipperEject
# call site stays a single line.
function Invoke-RipperMaybeEject {
    if ($choice -and $choice.PSObject.Properties['EjectAfterRip'] -and -not $choice.EjectAfterRip) {
        Write-RipperLog INFO 'Start-Ripper' 'Skipping eject (per-rip checkbox unchecked).'
        return
    }
    Invoke-RipperEject
}

switch ($choice.Action) {
    'Rip' {
        $m = $choice.Metadata

        # Phase 4 rips land in <LibraryRoot>\_inbox\<AlbumArtist> - <Album>\.
        # Phase 5's Move-ToLibrary will relocate from there to the Plex
        # layout (or _ReviewQueue\) once rip quality is known. Keeping the
        # staging area under LibraryRoot keeps everything on one volume so
        # the move is a rename (fast), not a copy.
        $inboxRoot = Join-Path $cfg.LibraryRoot '_inbox'
        if (-not (Test-Path -LiteralPath $inboxRoot)) {
            New-Item -ItemType Directory -Path $inboxRoot -Force | Out-Null
        }

        Write-RipperLog INFO 'Start-Ripper' `
            "Starting rip: $($m.AlbumArtist) - $($m.Album) -> $inboxRoot"

        try {
            $result = Show-RipperRipProgress `
                -DiscIdInfo $disc `
                -Metadata $m `
                -OutputRoot $inboxRoot `
                -ContactNetwork $true
        } catch {
            Write-RipperLog ERROR 'Start-Ripper' "Rip threw: $($_.Exception.Message)"
            Show-RipperInfo "Rip failed:`n`n  $($_.Exception.Message)`n`nSee log:`n  $logPath" `
                'MusicRipper - Rip Failed' 'Error'
            Invoke-RipperMaybeEject
            Stop-RipperLog
            return
        }

        if (-not $result) {
            # Progress window closed before the rip started — rare but
            # survivable. Treat like a cancel.
            Write-RipperLog WARN 'Start-Ripper' 'Rip returned $null (window closed early).'
            Invoke-RipperMaybeEject
            break
        }

        Write-RipperLog INFO 'Start-Ripper' `
            "Rip finished: Status=$($result.Status) FailedSectors=$($result.FailedSectors) Output=$($result.OutputDir)"

        # --- Phase 5: quality gate -> tag -> move -> review artifacts -----
        # Only run the post-rip pipeline on rips that actually produced
        # output. Cancelled/Failed rips fall through to the user dialog
        # without further processing.
        $phase5Target  = $null
        $phase5Quality = $null
        if ($result.Status -ne 'Cancelled' -and $result.Status -ne 'Failed') {
            # Drop a sidecar BEFORE running post-process so a crash mid-tag
            # leaves the next launch enough breadcrumbs to finish the job.
            try {
                $coverLeaf = if ($result.CoverArtFile) { Split-Path -Leaf $result.CoverArtFile } else { $null }
                Write-RipperRipState `
                    -RipFolder        $result.OutputDir `
                    -DiscId           $disc.DiscId `
                    -Metadata         $m `
                    -LogFileName      (Split-Path -Leaf $result.LogFile) `
                    -CoverArtFileName $coverLeaf | Out-Null
            } catch {
                # Sidecar is best-effort; a write failure shouldn't block
                # post-process. Log and continue.
                Write-RipperLog WARN 'Start-Ripper' "Sidecar write failed: $($_.Exception.Message)"
            }
            try {
                $pp = Invoke-RipperPostProcess `
                    -RipFolder    $result.OutputDir `
                    -LogFile      $result.LogFile `
                    -Metadata     $m `
                    -DiscId       $disc.DiscId `
                    -LibraryRoot  $cfg.LibraryRoot `
                    -CoverArtFile $result.CoverArtFile
                $phase5Quality = $pp.Quality
                $phase5Target  = $pp.Target
                # Happy path: clear the sidecar from the post-move folder.
                try { Remove-RipperRipState -RipFolder $pp.Target } catch {
                    Write-RipperLog WARN 'Start-Ripper' "Sidecar cleanup failed: $($_.Exception.Message)"
                }
            } catch {
                Write-RipperLog ERROR 'Start-Ripper' "Phase 5 pipeline failed: $($_.Exception.Message)"
                Show-RipperInfo "Rip succeeded but post-processing failed:`n`n  $($_.Exception.Message)`n`nThe raw rip is still at:`n  $($result.OutputDir)`n`nSee log:`n  $logPath" `
                    'MusicRipper - Post-Processing Failed' 'Warning'
                Invoke-RipperMaybeEject
                Stop-RipperLog
                return
            }
        }

        # Build summary text per the Invoke-RipperRip contract. We surface
        # Status prominently because that's what Phase 5 routing will
        # branch on (Verified/ProbablyGood -> library, Suspect/NotInDatabase
        # -> _ReviewQueue).
        switch ($result.Status) {
            'Cancelled' {
                Show-RipperInfo "Rip cancelled. Partial files were removed." `
                    'MusicRipper' 'Information'
            }
            'Failed' {
                $err = ($result.Errors -join "`n  ")
                Show-RipperInfo "Rip failed.`n`n  $err`n`nSee log:`n  $logPath" `
                    'MusicRipper - Rip Failed' 'Error'
            }
            default {
                $ar    = $result.AccurateRip
                $ctdb  = $result.Ctdb
                $destLine = if ($phase5Target) {
                    $kind = if ($phase5Quality -and $phase5Quality.Destination -eq 'ReviewQueue') { 'Review queue' } else { 'Library' }
                    "${kind}: $phase5Target"
                } else {
                    "Output: $($result.OutputDir)"
                }
                $lines = @(
                    "Status: $($result.Status)"
                    ""
                    "  $($m.AlbumArtist) - $($m.Album)"
                    "  $($m.TrackCount) track(s) - $([int][Math]::Round($result.ElapsedSeconds / 60))m $([int]($result.ElapsedSeconds % 60))s"
                    ""
                    "AccurateRip: $($ar.Status)$(if ($null -ne $ar.MinConfidence) { " (min confidence $($ar.MinConfidence))" })"
                    "CTDB:        $($ctdb.Status)$(if ($null -ne $ctdb.MinConfidence) { " (confidence $($ctdb.MinConfidence))" })"
                    "Re-read sectors: $($result.FailedSectors)"
                    ""
                    $destLine
                )
                if ($result.HtoaWarning) { $lines += @("", "Note: $($result.HtoaWarning)") }
                if ($result.Errors -and $result.Errors.Count -gt 0) {
                    $lines += @("", "Warnings:") + ($result.Errors | ForEach-Object { "  - $_" })
                }
                $icon = switch ($result.Status) {
                    'Verified'      { 'Information' }
                    'ProbablyGood'  { 'Information' }
                    default         { 'Warning' }   # Suspect / NotInDatabase
                }
                Show-RipperInfo ($lines -join "`n") 'MusicRipper - Rip Complete' $icon
            }
        }

        Invoke-RipperMaybeEject
    }
    'Review' {
        $m = $choice.Metadata
        Show-RipperInfo "Marked for Review (Phase 5 routing).`n`nDisc: $($m.AlbumArtist) - $($m.Album)`n`nEjecting now." `
            'MusicRipper (Phase 3 stub)' 'Information'
        Invoke-RipperMaybeEject
    }
    'Cancel' {
        Write-RipperLog INFO 'Start-Ripper' 'User cancelled at confirm dialog. Ejecting.'
        Invoke-RipperMaybeEject
    }
}

Stop-RipperLog
