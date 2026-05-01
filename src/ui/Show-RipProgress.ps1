<#
.SYNOPSIS
    Non-modal WPF progress window for a disc rip. Drives Invoke-RipperRip
    from a background runspace and surfaces live progress to the user.

.DESCRIPTION
    Pipeline position:
        Called by Start-Ripper.ps1 from the Action='Rip' branch after
        the user confirms metadata. This function owns the whole rip:
        it opens the window, spawns the rip on a background runspace,
        pumps progress updates into the UI on the WPF dispatcher, and
        returns the rip result once the window closes.

    Why a background runspace:
        Invoke-RipperRip blocks for 5-15 minutes reading a disc.
        PowerShell is single-threaded per runspace, so we can't rip on
        the same thread as WPF.ShowDialog without freezing the UI. We
        create a separate STA runspace for the rip; a DispatcherTimer
        on the UI thread polls a synchronized hashtable at 10 Hz and
        updates the controls.

    Why not just Dispatcher.Invoke from the callback:
        Scriptblocks belong to the runspace that created them.
        Invoking them cross-runspace is fragile (modules not loaded,
        variable scope broken). The "drop the payload into a shared
        hashtable, pull it on the UI timer" pattern sidesteps that
        entirely and is the idiomatic PowerShell+WPF approach.

    Features (per user request, Phase 4 green-light brief):
        - Per-track progress bar + percentage.
        - Overall album progress bar + percentage.
        - Elapsed time (HH:MM:SS, ticks every second).
        - ETA — "calculating..." for the first 5 seconds, then refined.
        - Read speed ("8.2x") computed from B/s.
        - Current track title + artist.
        - AR/CTDB status line.
        - Failed-sector counter (bold red when > 0, hidden when 0).
        - Drive read mode footer.
        - Cancel button (confirm-dialog before actually cancelling).
        - Window close ([X]) asks the same confirm.

    Manual verification: Phase 4 spike §9 checklist (rip 3 known discs,
    cancel mid-rip leaves no orphans).

.PARAMETER DiscIdInfo
    Pass-through to Invoke-RipperRip.

.PARAMETER Metadata
    Pass-through to Invoke-RipperRip (the confirmed metadata from the
    Phase 3 dialog).

.PARAMETER OutputRoot
    Pass-through to Invoke-RipperRip.

.PARAMETER ContactNetwork
    Pass-through to Invoke-RipperRip. Default $true.

.PARAMETER PostProcessAction
    Optional scriptblock executed on the same background runspace AFTER
    the rip completes successfully (and is not cancelled / errored).
    Window stays open while the action runs and switches into a
    "Finalizing album" mode that surfaces a live status line written
    by the action via $state['PostProcessStatus'] = 'msg'.

    Signature: param($state, $ripResult, $context)
    Returns:   any object (stored on the return value as PostProcess).

.PARAMETER PostProcessContext
    Optional hashtable forwarded to PostProcessAction as its third
    argument. Use it to ship config / paths / discId into the action
    without closure capture (closures across runspaces are fragile --
    see file header).

.OUTPUTS
    pscustomobject -- when -PostProcessAction is omitted (legacy
    callers) returns exactly what Invoke-RipperRip returned. When
    -PostProcessAction is supplied, returns:
        @{ Rip = <ripResult>; PostProcess = <action return>; PostProcessError = <ex or $null> }
    or $null if an unrecoverable error prevented starting the rip.

.EXAMPLE
    PS> $result = Show-RipperRipProgress -DiscIdInfo $disc -Metadata $meta `
            -OutputRoot 'D:\Rips\_inbox'
    PS> $result.Status
    Verified

.NOTES
    WPF event handlers can't see script-scope functions even with
    GetNewClosure() — closures capture variables, not functions.
    Helpers are bound as scriptblock locals before handler wiring.
    (Project gotcha #6.)
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')     -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1')    -Force
Import-Module (Join-Path $repoRoot 'src\lib\RipHelpers.psd1') -Force

Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore      | Out-Null
Add-Type -AssemblyName WindowsBase           | Out-Null

function Show-RipperRipProgress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject]$DiscIdInfo,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string]$OutputRoot,
        [bool]$ContactNetwork = $true,
        [Parameter()] [scriptblock]$PostProcessAction,
        [Parameter()] [hashtable]$PostProcessContext = @{}
    )

    # --- Build window from inline XAML -------------------------------------
    # Layout rationale:
    #   Row 0 : Album title + artist (headline — what are we ripping).
    #   Row 1 : Current track line (what's happening right now).
    #   Row 2 : Per-track progress bar + right-aligned track-time/percent.
    #   Row 3 : Overall progress bar + right-aligned overall percent.
    #   Row 4 : Three-column stats (Elapsed | ETA | Speed).
    #   Row 5 : AR/CTDB status line.
    #   Row 6 : Failed-sector warning (collapsed when 0).
    #   Row 7 : Drive read-mode footer + Cancel button.
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ripping CD..."
        Height="395" Width="620"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        FontFamily="Segoe UI" FontSize="13">
    <Grid Margin="16" Grid.IsSharedSizeScope="True">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>  <!-- album headline -->
      <RowDefinition Height="Auto"/>  <!-- current track -->
      <RowDefinition Height="Auto"/>  <!-- per-track bar -->
      <RowDefinition Height="Auto"/>  <!-- overall bar -->
      <RowDefinition Height="Auto"/>  <!-- tagging bar (post-process only) -->
      <RowDefinition Height="Auto"/>  <!-- stats row -->
      <RowDefinition Height="Auto"/>  <!-- AR/CTDB -->
      <RowDefinition Height="Auto"/>  <!-- failed sectors -->
      <RowDefinition Height="*"/>     <!-- spacer -->
      <RowDefinition Height="Auto"/>  <!-- footer -->
    </Grid.RowDefinitions>

    <!-- Row 0: album headline -->
    <StackPanel Grid.Row="0" Margin="0,0,0,6">
      <TextBlock x:Name="AlbumText"  FontSize="17" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="ArtistText" FontSize="13" Foreground="#555" TextTrimming="CharacterEllipsis"/>
    </StackPanel>

    <!-- Row 1: current track -->
    <TextBlock Grid.Row="1" x:Name="CurrentTrackText" Margin="0,6,0,2"
               FontSize="13" Foreground="#222" TextTrimming="CharacterEllipsis"
               Text="Starting up..."/>

    <!-- Row 2: per-track bar -->
    <!-- Row 2: per-track bar.
         Same 3-column layout as the overall row below so the bars and
         the percentage column line up exactly. SharedSizeGroup keeps
         the label column the same width regardless of which label is
         longer. -->
    <Grid Grid.Row="2" x:Name="TrackBarRow" Margin="0,2,0,6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto" SharedSizeGroup="BarLabel"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto" SharedSizeGroup="BarPct"/>
      </Grid.ColumnDefinitions>
      <TextBlock   Grid.Column="0" Text="Track"   VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#555"/>
      <ProgressBar Grid.Column="1" x:Name="TrackBar"   Height="14" Minimum="0" Maximum="1" Value="0"/>
      <TextBlock   Grid.Column="2" x:Name="TrackPctText" Margin="8,0,0,0" VerticalAlignment="Center"
                   MinWidth="46" TextAlignment="Right" Text="  0%"/>
    </Grid>

    <!-- Row 3: overall bar -->
    <Grid Grid.Row="3" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto" SharedSizeGroup="BarLabel"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto" SharedSizeGroup="BarPct"/>
      </Grid.ColumnDefinitions>
      <TextBlock   Grid.Column="0" Text="Overall" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#555"/>
      <ProgressBar Grid.Column="1" x:Name="OverallBar" Height="18" Minimum="0" Maximum="1" Value="0"/>
      <TextBlock   Grid.Column="2" x:Name="OverallPctText" Margin="8,0,0,0" VerticalAlignment="Center"
                   MinWidth="46" TextAlignment="Right" FontWeight="Bold" Text="  0%"/>
    </Grid>

    <!-- Row 4: tagging bar (Phase 6.2.D, hidden during the rip phase,
         shown during post-process while Invoke-RipperWriteTags walks
         per-track. The percent column shows '3 / 12' rather than '%'
         because for short queues the discrete count is more legible. -->
    <Grid Grid.Row="4" x:Name="TaggingBarRow" Margin="0,0,0,10" Visibility="Collapsed">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto" SharedSizeGroup="BarLabel"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto" SharedSizeGroup="BarPct"/>
      </Grid.ColumnDefinitions>
      <TextBlock   Grid.Column="0" Text="Tagging" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#555"/>
      <ProgressBar Grid.Column="1" x:Name="TaggingBar"   Height="14" Minimum="0" Maximum="1" Value="0"/>
      <TextBlock   Grid.Column="2" x:Name="TaggingPctText" Margin="8,0,0,0" VerticalAlignment="Center"
                   MinWidth="46" TextAlignment="Right" Text=""/>
    </Grid>

    <!-- Row 5: stats (Elapsed | ETA | Speed) -->
    <Grid Grid.Row="5" x:Name="StatsRow" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="Elapsed" Foreground="#888" FontSize="11"/>
        <TextBlock x:Name="ElapsedText" FontSize="15" FontWeight="SemiBold" Text="0:00"/>
      </StackPanel>
      <StackPanel Grid.Column="1">
        <TextBlock Text="Remaining" Foreground="#888" FontSize="11"/>
        <TextBlock x:Name="EtaText"     FontSize="15" FontWeight="SemiBold" Text="calculating..."/>
      </StackPanel>
      <StackPanel Grid.Column="2">
        <TextBlock Text="Read speed" Foreground="#888" FontSize="11"/>
        <TextBlock x:Name="SpeedText"   FontSize="15" FontWeight="SemiBold" Text="—"/>
      </StackPanel>
    </Grid>

    <!-- Row 6: AR/CTDB status -->
    <TextBlock Grid.Row="6" x:Name="ArStatusText" Margin="0,0,0,4"
               Foreground="#444" FontSize="12" Text="AccurateRip: pending..."/>

    <!-- Row 7: failed sector warning (collapsed when zero) -->
    <TextBlock Grid.Row="7" x:Name="FailedSectorsText" Margin="0,0,0,4"
               Foreground="#b00" FontWeight="Bold" FontSize="12"
               Visibility="Collapsed" Text=""/>

    <!-- Row 9: footer -->
    <DockPanel Grid.Row="9" LastChildFill="False">
      <TextBlock x:Name="ModeText" DockPanel.Dock="Left" VerticalAlignment="Center"
                 Foreground="#888" FontSize="11" Text="Secure mode"/>
      <Button x:Name="CancelButton" DockPanel.Dock="Right"
              Content="Cancel rip" Padding="14,4" MinWidth="120"
              ToolTip="Stop the rip and delete the partial files."/>
    </DockPanel>
  </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    Set-RipperWindowIcon $window

    # Phase 5.11: see Show-DuplicateDiscDialog -- steal foreground from
    # whatever was last in focus, since the host pwsh window is minimized.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    $controls = @{}
    foreach ($n in @(
        'AlbumText','ArtistText','CurrentTrackText',
        'TrackBar','TrackPctText','TrackBarRow',
        'OverallBar','OverallPctText','OverallPctText',
        'TaggingBarRow','TaggingBar','TaggingPctText',
        'StatsRow','ElapsedText','EtaText','SpeedText',
        'ArStatusText','FailedSectorsText','ModeText','CancelButton'
    )) { $controls[$n] = $window.FindName($n) }

    # Pre-populate the headline so the window never looks "empty" before
    # the first progress callback arrives.
    $controls.AlbumText.Text  = [string]$Metadata.Album
    $controls.ArtistText.Text = [string]$Metadata.AlbumArtist
    $totalTracks = @($Metadata.Tracks).Count
    $controls.CurrentTrackText.Text = "Opening drive $($DiscIdInfo.DriveLetter)..."

    # Dispatcher-level safety net. Anything that escapes onto the WPF
    # dispatcher (any event handler, any binding update, any internal
    # WPF callback) lands here. Without this, ShowDialog re-raises it
    # to the caller as an unhelpful "Cannot index into a null array"
    # / NRE that we can never catch in PowerShell-level try/catch.
    # Setting Handled=$true keeps the window alive long enough for
    # our normal teardown to run.
    $window.Dispatcher.Add_UnhandledException({
        param($sender, $eArgs)
        try {
            $exMsg = "$($eArgs.Exception.GetType().FullName): $($eArgs.Exception.Message)`r`n$($eArgs.Exception.StackTrace)"
            $invInfo = ''
            if ($eArgs.Exception -is [System.Management.Automation.RuntimeException]) {
                $er = $eArgs.Exception.ErrorRecord
                if ($er) {
                    $invInfo = "PositionMessage:`r`n$($er.InvocationInfo.PositionMessage)`r`nScriptStackTrace:`r`n$($er.ScriptStackTrace)"
                }
            }
            [System.IO.File]::AppendAllText(
                (Join-Path $env:TEMP 'musicripper-ui-error.log'),
                "[Dispatcher.UnhandledException] $exMsg`r`n$invInfo`r`n`r`n")
            $eArgs.Handled = $true
        } catch { }
    })

    # --- Shared state across UI thread and rip runspace --------------------
    # Synchronized hashtable: both threads can write, reads are atomic per
    # key. Simpler than a ManualResetEvent for our "latest wins" progress
    # pattern.
    $state = [hashtable]::Synchronized(@{
        Cancel             = $false        # UI -> rip (read live by the rip runspace via a scriptblock callback)
        Progress           = $null         # rip -> UI (hashtable from Invoke-RipperRip OnProgress)
        RipResult          = $null         # rip -> UI, set at end
        RipError           = $null         # rip -> UI if it threw
        RipDone            = $false        # rip -> UI: terminal state reached
        Closing            = $false        # UI tick -> UI tick: guard against re-entry
        UiError            = $null         # UI tick -> caller (after ShowDialog re-raises NRE)
        StartedAt          = [DateTime]::UtcNow
        # Phase 6.2.C post-process passthrough.
        PostProcessStatus  = ''            # action -> UI: live status text
        PostProcessResult  = $null         # action -> UI: return value
        PostProcessError   = $null         # action -> UI: ex if action threw
        PostProcessDone    = $false        # action -> UI: terminal
        UiInPostProcess    = $false        # UI tick -> UI tick: did we already swap UI mode?
        # Phase 6.2.D weighted progress -- driven by Invoke-RipperPostProcess
        # via -ProgressCallback. UI tick reads them directly.
        PostProcessOverallFraction = 0.0   # 0.0 .. 1.0 across all post-process steps
        PostProcessTagCurrent      = 0     # 1-based when tagging, 0 when not
        PostProcessTagTotal        = 0     # 0 when not in tagging phase
    })

    # --- Start rip on a background runspace -------------------------------
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('state',          $state)
    $rs.SessionStateProxy.SetVariable('repoRoot',       $repoRoot)
    $rs.SessionStateProxy.SetVariable('DiscIdInfo',     $DiscIdInfo)
    $rs.SessionStateProxy.SetVariable('Metadata',       $Metadata)
    $rs.SessionStateProxy.SetVariable('OutputRoot',     $OutputRoot)
    $rs.SessionStateProxy.SetVariable('ContactNetwork', $ContactNetwork)
    # Test-harness override: tests/manual/Repro-RipProgress.ps1 sets
    # this env var to point at a stub Invoke-Rip.ps1 so we can repro
    # post-rip UI bugs in 3 seconds without burning a real disc.
    $ripScriptPath = if ($env:MUSICRIPPER_RIP_STUB -and (Test-Path -LiteralPath $env:MUSICRIPPER_RIP_STUB)) {
        $env:MUSICRIPPER_RIP_STUB
    } else {
        Join-Path $repoRoot 'src\core\Invoke-Rip.ps1'
    }
    $rs.SessionStateProxy.SetVariable('ripScriptPath', $ripScriptPath)

    # Phase 7 fix: hand the parent runspace's active log file path to
    # the worker so it can adopt it via Set-RipperLogPath. PowerShell
    # module state is per-runspace -- without this, the worker's
    # Logging module re-imports with $script:LogPath = $null, every
    # Write-RipperLog from inside Invoke-Rip / Invoke-RipperPostProcess
    # silently fails to hit the file (just the host stream), and
    # Copy-RipperLog at end-of-post-process returns $null with a
    # warning. Symptom that surfaced this: a 10-min review-queue rip
    # produced an album folder with NO ripper-session.log copy and a
    # per-disc log file that contained zero entries between "Starting
    # rip:" and "Rip finished:".
    $parentLogPath = $null
    try { $parentLogPath = Get-RipperLogPath } catch {}
    $rs.SessionStateProxy.SetVariable('parentLogPath', $parentLogPath)

    # Phase 6.2.C: ship the post-process action across the runspace
    # boundary as a string. Cross-runspace scriptblock invocation is
    # fragile (closures lose their module context) -- re-creating from
    # source inside the runspace gives us a clean, locally-rooted block
    # that can dot-source whatever it needs.
    $ppActionStr = if ($PostProcessAction) { $PostProcessAction.ToString() } else { $null }
    $rs.SessionStateProxy.SetVariable('ppActionStr', $ppActionStr)
    $rs.SessionStateProxy.SetVariable('ppContext',   $PostProcessContext)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
        try {
            . $ripScriptPath
            # Phase 7 fix: the dot-source above (and every src/core/*.ps1
            # the post-process action below dot-sources) pulls Logging.psd1
            # in this runspace with a fresh $script:LogPath = $null. Adopt
            # the parent's log file so Write-RipperLog calls actually land
            # in the per-disc log file and Copy-RipperLog snapshots the
            # right thing. Best-effort -- if Set-RipperLogPath isn't
            # available (older Logging build) the rip just runs without
            # in-runspace file logging, same as before.
            if ($parentLogPath -and (Get-Command -Name Set-RipperLogPath -ErrorAction SilentlyContinue)) {
                Set-RipperLogPath -Path $parentLogPath -Context 'rip-worker'
            }
            $progressCb = {
                param($payload)
                # Latest-wins: UI reads whatever is in $state.Progress at
                # its next timer tick. Dropping intermediate updates is
                # exactly what we want for a 10 Hz readout.
                $state['Progress'] = $payload
            }
            # Cancellation: pass a scriptblock so the rip loop reads the
            # live $state['Cancel'] flag every iteration. A [ref] would
            # snapshot the boolean (PowerShell's [ref] of an indexed value
            # captures the current value, not a live address), so the UI
            # thread's flip would never be visible inside the rip.
            $cancelCheck = { [bool]$state['Cancel'] }.GetNewClosure()
            $r = Invoke-RipperRip `
                    -DiscIdInfo $DiscIdInfo `
                    -Metadata $Metadata `
                    -OutputRoot $OutputRoot `
                    -OnProgress $progressCb `
                    -CancelRequested $cancelCheck `
                    -ContactNetwork $ContactNetwork
            $state['RipResult'] = $r
        } catch {
            $state['RipError'] = $_
        } finally {
            $state['RipDone'] = $true
        }

        # Phase 6.2.C: run the post-process action on this same runspace
        # so the window can stay open with a live status line driven by
        # $state['PostProcessStatus']. Skipped on cancel / rip-error /
        # no-action -- the UI will just close as before.
        $rip = $state['RipResult']
        if ($ppActionStr -and $rip -and -not $state['RipError'] -and -not $state['Cancel'] `
                -and $rip.Status -ne 'Cancelled' -and $rip.Status -ne 'Failed') {
            $state['PostProcessStatus'] = 'Starting post-processing...'
            try {
                $ppAction = [scriptblock]::Create($ppActionStr)
                $state['PostProcessResult'] = & $ppAction $state $rip $ppContext
            } catch {
                $state['PostProcessError'] = $_
            } finally {
                $state['PostProcessDone'] = $true
            }
        } else {
            # Nothing to do; mark done so the close-gate trips immediately.
            $state['PostProcessDone'] = $true
        }
    })

    $asyncHandle = $ps.BeginInvoke()

    # --- UI-thread helpers (bind as scriptblock locals per gotcha #6) ------
    $fmtEta   = ${function:ConvertTo-RipperEtaText}
    $fmtSpeed = ${function:ConvertTo-RipperReadSpeedText}

    # ETA grace period: the first few buffers produce nonsense estimates
    # because the drive spin-up dominates. Don't show an ETA for the first
    # 5 seconds.
    $etaGraceSeconds = 5

    # --- Pump updates via DispatcherTimer ---------------------------------
    # 10 Hz matches the rate the rip throttles OnProgress callbacks. The
    # timer runs on the UI dispatcher thread, so it's safe to touch
    # controls directly.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)

    $tickHandler = {
        # Diagnostic wrapper: WPF re-raises any unhandled scriptblock
        # exception out of ShowDialog as the unhelpful "Exception calling
        # 'ShowDialog' with '0' argument(s): 'You cannot call a method on
        # a null-valued expression.'" — so we catch anything here and
        # store it on $state for the caller to surface with a real
        # ScriptStackTrace. (Manual-test-4.)
        try {
        $p = $state.Progress
        if ($p) {
            $frac     = [double]$p.OverallFraction
            $tFrac    = [double]$p.CurrentTrackFraction
            $elapsed  = [TimeSpan]::FromSeconds([double]$p.ElapsedSeconds)

            $controls.OverallBar.Value    = $frac
            $controls.OverallPctText.Text = '{0,3}%' -f [int]([Math]::Round($frac * 100))
            $controls.TrackBar.Value      = $tFrac
            $controls.TrackPctText.Text   = '{0,3}%' -f [int]([Math]::Round($tFrac * 100))

            $ctTitle  = [string]$p.CurrentTrackTitle
            $ctArtist = [string]$p.CurrentTrackArtist
            $ctNum    = [int]$p.CurrentTrack
            $ctTot    = [int]$p.TotalTracks
            $line = "Track $ctNum of $ctTot - $ctTitle"
            if ($ctArtist -and $ctArtist -ne [string]$Metadata.AlbumArtist) {
                $line += " (by $ctArtist)"
            }
            $controls.CurrentTrackText.Text = $line

            # Elapsed / ETA / speed formatters live in RipHelpers.
            # Suppress ETA during the grace window so the user doesn't
            # see a wildly wrong first estimate.
            $eta = & $fmtEta -Elapsed $elapsed -FractionDone $frac
            $controls.ElapsedText.Text = $eta.Elapsed
            if ($p.ElapsedSeconds -lt $etaGraceSeconds -and $frac -lt 1.0) {
                $controls.EtaText.Text = 'calculating...'
            } else {
                $controls.EtaText.Text = $eta.Eta
            }
            $controls.SpeedText.Text = & $fmtSpeed -BytesPerSecond $p.BytesPerSecond

            # AR status line.
            $arStatus = [string]$p.ARStatus
            if ($arStatus) {
                $controls.ArStatusText.Text = "AccurateRip: $arStatus"
            }

            # Failed sectors — bold red when non-zero, collapsed otherwise.
            $failed = [int]$p.FailedSectors
            if ($failed -gt 0) {
                $controls.FailedSectorsText.Text = "$failed sector(s) needed re-reads (still within spec)"
                $controls.FailedSectorsText.Visibility = 'Visible'
            } else {
                $controls.FailedSectorsText.Visibility = 'Collapsed'
            }

            $controls.ModeText.Text = "$($p.CorrectionMode) mode"
        }

        # Phase 6.2.C: when the rip is done but the post-process
        # action is still running, transition the window into a
        # "Finalizing album" mode and don't close. The runspace will
        # set $state['PostProcessDone'] = $true once it returns; the
        # next tick falls through to the normal close path below.
        if ($state['RipDone'] -and -not $state['PostProcessDone'] `
                -and -not $state['Cancel'] -and -not $state['RipError']) {
            if (-not $state['UiInPostProcess']) {
                $state['UiInPostProcess'] = $true
                $window.Title                       = 'Finalizing album...'
                # Start indeterminate (marquee) -- some operations
                # (robocopy to a remote NAS) can block for many seconds
                # before the next progress callback fires, and a frozen
                # 0% looked like the app had hung. The first non-zero
                # frac update below switches us back to determinate.
                # IMPORTANT: reset Value to 0 BEFORE switching to
                # indeterminate. The rip phase left Value=1.0; if the
                # first determinate update from the post-process
                # callback then arrives with $ovFrac=0.05 (sidecar+
                # quality), the bar visibly snaps from full to 5% and
                # then climbs back up -- it looks broken / motionless
                # during tagging. Starting at 0 means tagging climbs
                # 0 -> ~0.55 monotonically.
                $controls.OverallBar.Value          = 0.0
                $controls.OverallBar.IsIndeterminate = $true
                $controls.OverallPctText.Text       = '...'
                $controls.TrackBar.Value            = 1.0
                $controls.TrackPctText.Text         = '100%'
                $controls.CurrentTrackText.Text     = 'Rip complete. Tagging, moving, and syncing...'
                $controls.CurrentTrackText.FontWeight = 'SemiBold'
                # Hide the rip-only chrome that no longer applies.
                $controls.TrackBarRow.Visibility       = 'Collapsed'
                $controls.StatsRow.Visibility          = 'Collapsed'
                $controls.FailedSectorsText.Visibility = 'Collapsed'
                $controls.CancelButton.Visibility      = 'Collapsed'
                # Show the tagging bar (filled live by ProgressCallback,
                # or by the status-text heuristic below if the
                # callback hasn't arrived yet).
                $controls.TaggingBarRow.Visibility     = 'Visible'
                $controls.TaggingBar.Value             = 0.0
                $controls.TaggingPctText.Text          = ''
            }
            # Live overall progress fed by Invoke-RipperPostProcess.
            $ovFrac = [double]$state['PostProcessOverallFraction']
            $msg    = [string]$state['PostProcessStatus']
            # Phase 6.4: robocopy doesn't emit per-file progress, so a
            # NAS sync over the WG link can sit at the same overall
            # fraction for many seconds. Show an indeterminate marquee
            # while the status line says "Syncing to *" so the parent
            # sees activity. Restore determinate on the next non-sync
            # tick so the bar can resume its climb.
            $isSyncing = $msg -and ($msg -like 'Syncing to *')
            if ($isSyncing) {
                if (-not $controls.OverallBar.IsIndeterminate) {
                    $controls.OverallBar.IsIndeterminate = $true
                    $controls.OverallPctText.Text        = '...'
                }
            } elseif ($ovFrac -gt 0) {
                # First real value (or sync just ended) -- switch from
                # indeterminate marquee to determinate.
                if ($controls.OverallBar.IsIndeterminate) {
                    $controls.OverallBar.IsIndeterminate = $false
                }
                $controls.OverallBar.Value    = $ovFrac
                $controls.OverallPctText.Text = '{0,3}%' -f [int]([Math]::Round($ovFrac * 100))
            }
            # Tagging bar: discrete count (3 / 12) is more meaningful than %.
            $tagCur = [int]$state['PostProcessTagCurrent']
            $tagTot = [int]$state['PostProcessTagTotal']
            if ($tagTot -gt 0) {
                $controls.TaggingBar.Value     = [double]$tagCur / [double]$tagTot
                $controls.TaggingPctText.Text  = "$tagCur / $tagTot"
            } else {
                # Outside tagging phase. Topping the bar up off either
                # of two signals so a stalled overall fraction (no
                # callback yet) doesn't leave the bar stuck at 0:
                #   1. ovFrac past the tagging share (~0.55), OR
                #   2. status text says we're past tagging (move/sync/
                #      retention/replaygain).
                $pastTag = ($ovFrac -gt 0.55) -or ($msg -and (
                    $msg -like 'Moving to *' -or
                    $msg -like 'Syncing to *' -or
                    $msg -like 'Computing ReplayGain*' -or
                    $msg -like 'Updating sync state*' -or
                    $msg -like 'Local retention*'))
                if ($controls.TaggingBar.Value -lt 1.0 -and $pastTag) {
                    $controls.TaggingBar.Value    = 1.0
                    $controls.TaggingPctText.Text = 'done'
                }
            }
            # Live status line (driven by Invoke-RipperPostProcess /
            # Invoke-RipperSync via -StatusCallback). Reuse the AR row
            # so we don't have to grow the window.
            if ($msg) {
                $controls.ArStatusText.Text = $msg
            }
            return
        }

        # Check for completion (normal, error, or cancel). Use indexer
        # access on $state — see closeDelay catch comment.
        # Guard via $state['Closing'] because $timer.Stop() inside a
        # DispatcherTimer Tick is asynchronous — the timer may already
        # have queued another tick onto the dispatcher, which would then
        # create a second closeDelay and call $window.Close() again
        # (throws "Cannot index into a null array" once the window is
        # mid-close). Set the guard FIRST, then do everything else.
        if ($state['RipDone'] -and $state['PostProcessDone'] -and -not $state['Closing']) {
            $state['Closing'] = $true
            $timer.Stop()
            # Brief pause so the user sees "100%" for a beat before the
            # window vanishes on a fast rip.
            if (-not $state['Cancel'] -and -not $state['RipError']) {
                $controls.OverallBar.IsIndeterminate = $false
                $controls.OverallBar.Value    = 1.0
                $controls.OverallPctText.Text = '100%'
                $controls.TrackBar.Value      = 1.0
                $controls.TrackPctText.Text   = '100%'
                if ($state['UiInPostProcess']) {
                    $controls.TaggingBar.Value    = 1.0
                    $controls.TaggingPctText.Text = 'done'
                }
                $controls.CurrentTrackText.Text = if ($state['UiInPostProcess']) {
                    'All done. Closing...'
                } else {
                    'Rip complete. Closing...'
                }
            } elseif ($state['Cancel']) {
                $controls.CurrentTrackText.Text = 'Cancelled.'
            } elseif ($state['RipError']) {
                $controls.CurrentTrackText.Text = "Error: $($state['RipError'].Exception.Message)"
            }
            # Close immediately. The previous 600 ms hold via a nested
            # DispatcherTimer + .GetNewClosure() pattern was the source
            # of the manual-test-3-through-9 failures (the inner
            # closure couldn't see $state, so its catch handler threw
            # "Cannot index into a null array" trying to record the
            # actual exception, which ShowDialog then re-raised as the
            # cryptic NRE). Start-Ripper pops a success summary dialog
            # right after this returns, so the user gets confirmation
            # of the result; the cosmetic "100% for a beat" hold isn't
            # worth the closure-capture rabbit hole.
            try { $window.Close() } catch { }
        }
        } catch {
            if (-not $state['UiError']) { $state['UiError'] = $_ }
            try { [System.IO.File]::AppendAllText(
                (Join-Path $env:TEMP 'musicripper-ui-error.log'),
                "[main tick] $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n`r`n"
            ) } catch { }
            try { $timer.Stop() } catch { }
            try { $window.Close() } catch { }
        }
    }
    $timer.Add_Tick($tickHandler)

    # --- Cancel button & [X] window-close -----------------------------------
    $confirmCancel = {
        # Ignore the cancel request once the rip has entered its terminal
        # phase — "cancel" makes no sense once the rip is already wrapping
        # up. Indexer access on $state — see manual-test-5 / -6 lessons.
        if ($state['RipDone'] -or $state['Cancel']) { return $true }
        $resp = [System.Windows.MessageBox]::Show(
            $window,
            "Cancel the rip? Partial FLAC files will be deleted.",
            'Cancel rip?',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        return ($resp -eq [System.Windows.MessageBoxResult]::Yes)
    }

    $controls.CancelButton.Add_Click({
        if (& $confirmCancel) {
            $state['Cancel'] = $true
            $controls.CancelButton.IsEnabled = $false
            $controls.CancelButton.Content   = 'Cancelling...'
            $controls.CurrentTrackText.Text  = 'Cancelling — finishing current buffer...'
        }
    }.GetNewClosure())

    $window.Add_Closing({
        param($sender, $e)
        # Closing fires when the closeDelay tick calls $window.Close()
        # AND when the user clicks [X]. Both paths must use indexer
        # access on $state — dot-property access here was the source
        # of the manual-test-7 NRE that ShowDialog rewrapped as the
        # cryptic "Cannot index into a null array".
        try {
            if ($state['RipDone']) { return }           # allow close
            if ($state['Cancel'])  { $e.Cancel = $true; return }  # cancel in progress
            if (& $confirmCancel) {
                $state['Cancel'] = $true
                $e.Cancel = $true                    # wait for rip to unwind
                $controls.CancelButton.IsEnabled = $false
                $controls.CancelButton.Content   = 'Cancelling...'
                $controls.CurrentTrackText.Text  = 'Cancelling — finishing current buffer...'
            } else {
                $e.Cancel = $true
            }
        } catch {
            # Don't let a Closing-handler exception bubble out of
            # ShowDialog as a confusing NRE — capture and allow close.
            if (-not $state['UiError']) { $state['UiError'] = $_ }
            try { [System.IO.File]::AppendAllText(
                (Join-Path $env:TEMP 'musicripper-ui-error.log'),
                "[Closing] $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n`r`n"
            ) } catch { }
        }
    }.GetNewClosure())

    $timer.Start()

    # --- Show (modal to caller, but window has its own message pump) -------
    [void]$window.ShowDialog()

    # --- Teardown ----------------------------------------------------------
    try { $ps.EndInvoke($asyncHandle) | Out-Null } catch { }
    try { $ps.Dispose() } catch { }
    try { $rs.Close();   $rs.Dispose() } catch { }

    if ($state['RipError']) {
        Write-RipperLog ERROR 'Show-RipProgress' "Rip threw: $($state['RipError'].Exception.Message)"
        if ($state['RipError'].ScriptStackTrace) {
            Write-RipperLog ERROR 'Show-RipProgress' "ScriptStackTrace:`n$($state['RipError'].ScriptStackTrace)"
        }
        throw $state['RipError']
    }
    if ($state['UiError']) {
        # A WPF tick handler threw; ShowDialog wraps that as the unhelpful
        # NRE. Surface the real exception + stack here so we can see what
        # the actual failure was. The rip itself may well have succeeded
        # (FLACs on disk) — caller decides whether to keep RipResult.
        Write-RipperLog ERROR 'Show-RipProgress' "UI tick threw: $($state['UiError'].Exception.Message)"
        if ($state['UiError'].ScriptStackTrace) {
            Write-RipperLog ERROR 'Show-RipProgress' "ScriptStackTrace:`n$($state['UiError'].ScriptStackTrace)"
        }
        # If we have a usable rip result, return it anyway — losing it to
        # a UI cosmetic bug is the worst possible outcome.
        if ($state['RipResult']) {
            if ($PostProcessAction) {
                return [pscustomobject]@{
                    Rip              = $state['RipResult']
                    PostProcess      = $state['PostProcessResult']
                    PostProcessError = $state['PostProcessError']
                }
            }
            return $state['RipResult']
        }
        throw $state['UiError']
    }
    if ($PostProcessAction) {
        # Phase 6.2.C return shape: caller passed a post-process action,
        # so always return the structured triple even if the action ran
        # to nothing (RipResult $null on cancel/fail).
        return [pscustomobject]@{
            Rip              = $state['RipResult']
            PostProcess      = $state['PostProcessResult']
            PostProcessError = $state['PostProcessError']
        }
    }
    $state['RipResult']
}
