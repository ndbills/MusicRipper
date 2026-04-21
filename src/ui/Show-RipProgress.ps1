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

.OUTPUTS
    pscustomobject — exactly what Invoke-RipperRip returned, or $null if
    an unrecoverable error prevented starting the rip.

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
        [bool]$ContactNetwork = $true
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
        Height="360" Width="620"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>  <!-- album headline -->
      <RowDefinition Height="Auto"/>  <!-- current track -->
      <RowDefinition Height="Auto"/>  <!-- per-track bar -->
      <RowDefinition Height="Auto"/>  <!-- overall bar -->
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
    <Grid Grid.Row="2" Margin="0,2,0,6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <ProgressBar Grid.Column="0" x:Name="TrackBar"   Height="14" Minimum="0" Maximum="1" Value="0"/>
      <TextBlock   Grid.Column="1" x:Name="TrackPctText" Margin="8,0,0,0" VerticalAlignment="Center"
                   MinWidth="42" TextAlignment="Right" Text="  0%"/>
    </Grid>

    <!-- Row 3: overall bar -->
    <Grid Grid.Row="3" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock   Grid.Column="0" Text="Overall" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#555"/>
      <ProgressBar Grid.Column="1" x:Name="OverallBar" Height="18" Minimum="0" Maximum="1" Value="0"/>
      <TextBlock   Grid.Column="2" x:Name="OverallPctText" Margin="8,0,0,0" VerticalAlignment="Center"
                   MinWidth="46" TextAlignment="Right" FontWeight="Bold" Text="  0%"/>
    </Grid>

    <!-- Row 4: stats (Elapsed | ETA | Speed) -->
    <Grid Grid.Row="4" Margin="0,0,0,8">
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

    <!-- Row 5: AR/CTDB status -->
    <TextBlock Grid.Row="5" x:Name="ArStatusText" Margin="0,0,0,4"
               Foreground="#444" FontSize="12" Text="AccurateRip: pending..."/>

    <!-- Row 6: failed sector warning (collapsed when zero) -->
    <TextBlock Grid.Row="6" x:Name="FailedSectorsText" Margin="0,0,0,4"
               Foreground="#b00" FontWeight="Bold" FontSize="12"
               Visibility="Collapsed" Text=""/>

    <!-- Row 8: footer -->
    <DockPanel Grid.Row="8" LastChildFill="False">
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

    $controls = @{}
    foreach ($n in @(
        'AlbumText','ArtistText','CurrentTrackText',
        'TrackBar','TrackPctText','OverallBar','OverallPctText',
        'ElapsedText','EtaText','SpeedText',
        'ArStatusText','FailedSectorsText','ModeText','CancelButton'
    )) { $controls[$n] = $window.FindName($n) }

    # Pre-populate the headline so the window never looks "empty" before
    # the first progress callback arrives.
    $controls.AlbumText.Text  = [string]$Metadata.Album
    $controls.ArtistText.Text = [string]$Metadata.AlbumArtist
    $totalTracks = @($Metadata.Tracks).Count
    $controls.CurrentTrackText.Text = "Opening drive $($DiscIdInfo.DriveLetter)..."

    # --- Shared state across UI thread and rip runspace --------------------
    # Synchronized hashtable: both threads can write, reads are atomic per
    # key. Simpler than a ManualResetEvent for our "latest wins" progress
    # pattern.
    $state = [hashtable]::Synchronized(@{
        Cancel         = $false        # UI -> rip
        Progress       = $null         # rip -> UI (hashtable from Invoke-RipperRip OnProgress)
        RipResult      = $null         # rip -> UI, set at end
        RipError       = $null         # rip -> UI if it threw
        RipDone        = $false        # rip -> UI: terminal state reached
        Closing        = $false        # UI tick -> UI tick: guard against re-entry
        UiError        = $null         # UI tick -> caller (after ShowDialog re-raises NRE)
        StartedAt      = [DateTime]::UtcNow
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

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        # Runspace doesn't inherit StrictMode/EAP from the caller; set
        # them explicitly so the rip behaves the same way it does in
        # tests, and so missing-property accesses fail loudly instead of
        # silently corrupting state.
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
        try {
            . (Join-Path $repoRoot 'src\core\Invoke-Rip.ps1')
            $progressCb = {
                param($payload)
                # Latest-wins: UI reads whatever is in $state.Progress at
                # its next timer tick. Dropping intermediate updates is
                # exactly what we want for a 10 Hz readout.
                $state['Progress'] = $payload
            }
            $cancelHolder = ,$false
            $cancelRef    = [ref]$cancelHolder[0]
            $r = Invoke-RipperRip `
                    -DiscIdInfo $DiscIdInfo `
                    -Metadata $Metadata `
                    -OutputRoot $OutputRoot `
                    -OnProgress $progressCb `
                    -CancelRequested $cancelRef `
                    -ContactNetwork $ContactNetwork
            $state['RipResult'] = $r
        } catch {
            $state['RipError'] = $_
        } finally {
            $state['RipDone'] = $true
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

        # Check for completion (normal, error, or cancel). Use indexer
        # access on $state — see closeDelay catch comment.
        # Guard via $state['Closing'] because $timer.Stop() inside a
        # DispatcherTimer Tick is asynchronous — the timer may already
        # have queued another tick onto the dispatcher, which would then
        # create a second closeDelay and call $window.Close() again
        # (throws "Cannot index into a null array" once the window is
        # mid-close). Set the guard FIRST, then do everything else.
        if ($state['RipDone'] -and -not $state['Closing']) {
            $state['Closing'] = $true
            $timer.Stop()
            # Brief pause so the user sees "100%" for a beat before the
            # window vanishes on a fast rip.
            if (-not $state['Cancel'] -and -not $state['RipError']) {
                $controls.OverallBar.Value    = 1.0
                $controls.OverallPctText.Text = '100%'
                $controls.TrackBar.Value      = 1.0
                $controls.TrackPctText.Text   = '100%'
                $controls.CurrentTrackText.Text = 'Rip complete. Closing...'
            } elseif ($state['Cancel']) {
                $controls.CurrentTrackText.Text = 'Cancelled.'
            } elseif ($state['RipError']) {
                $controls.CurrentTrackText.Text = "Error: $($state['RipError'].Exception.Message)"
            }
            # 600 ms hold; shorter than a human blink-and-look cycle.
            $closeDelay = New-Object System.Windows.Threading.DispatcherTimer
            $closeDelay.Interval = [TimeSpan]::FromMilliseconds(600)
            # GetNewClosure() captures $closeDelay + $window from the
            # current scope so the inner Tick handler can reach them
            # under StrictMode 3 (timer ticks otherwise fire in a fresh
            # scope where these locals don't exist).
            $closeDelay.Add_Tick({
                try {
                    $closeDelay.Stop()
                    $window.Close()
                } catch {
                    # Indexer syntax — dot-property assignment on a
                    # synchronized hashtable from a dispatcher tick
                    # context fails under StrictMode 3 ("property X
                    # cannot be found"). Indexer bypasses that adapter.
                    $state['UiError'] = $_
                    try { [System.IO.File]::AppendAllText(
                        (Join-Path $env:TEMP 'musicripper-ui-error.log'),
                        "[closeDelay tick] $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n`r`n"
                    ) } catch { }
                }
            }.GetNewClosure())
            $closeDelay.Start()
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
        if ($state['RipResult']) { return $state['RipResult'] }
        throw $state['UiError']
    }
    $state['RipResult']
}
