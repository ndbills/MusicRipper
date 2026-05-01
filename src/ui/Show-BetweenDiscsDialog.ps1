<#
.SYNOPSIS
    Phase 5.7: between-discs WPF dialog for continuous mode.

.DESCRIPTION
    Pipeline position:
        Shown by Start-Ripper.ps1 after each per-disc cycle when
        cfg.ContinuousMode is true. Sits between iterations of the
        outer rip loop:

            ... -> Move-ToLibrary -> eject -> Show-BetweenDiscsDialog ->
                   (RipNext) loop again, or (Quit) Stop-RipperLog + exit.

    Hybrid disc-detection:
        - The dialog renders with two buttons: [Rip Next Disc] [Quit].
        - In parallel a DispatcherTimer polls [IO.DriveInfo]::IsReady on
          the configured drive letter every ~1.5s on the UI thread. When
          IsReady transitions false -> true (a disc was just inserted),
          the dialog auto-closes with Action='RipNext' so the parent
          doesn't have to click anything. If a disc is already loaded
          when the dialog opens (e.g. EjectAfterRip is false), the timer
          waits for the eject-then-insert transition first.
        - Closing the window via the title-bar X is treated as 'Quit'.

        Why polling instead of Win32_VolumeChangeEvent? The CIM event
        sink runs in a child runspace where $script: scope does not
        reach our module variables, and Win32_VolumeChangeEvent is also
        unreliable for optical media on some Windows builds. A 1.5s
        DispatcherTimer is bullet-proof, costs ~nothing, and runs on
        the UI thread so closing the window from the tick handler is
        safe (no Dispatcher.Invoke marshalling required).

    Returns a [pscustomobject] with:
        Action    'RipNext' | 'Quit'
        Trigger   'Button' | 'AutoDetected' | 'WindowClose'

.NOTES
    Per Phase-4 / 5.2 lesson: a Dispatcher.add_UnhandledException sink is
    installed immediately after XamlReader.Load and writes to a sidecar
    log under %LOCALAPPDATA%\MusicRipper\logs\between-discs-dispatcher.log
    so any binding / template error is captured instead of bubbling up as
    a silent NRE at ShowDialog.

    Auto-detect uses System.Windows.Threading.DispatcherTimer (UI-thread
    polling of [IO.DriveInfo]::IsReady). Stopped in finally{} regardless
    of how the window closes.
#>

function Show-RipperBetweenDiscsDialog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Drive letter to watch for disc arrival (e.g. 'D:'). Optional;
        # if null/empty, the auto-detect path is skipped and only the
        # buttons are wired up.
        [string]$DriveLetter,

        # Optional summary text shown above the buttons (e.g. "Last rip:
        # Verified — Pink Floyd / The Wall"). Multi-line OK.
        [string]$LastRipSummary,

        # Index of the current rip in the session (1-based). Surfaced in
        # the title bar so the parent can see "Disc 4 done" at a glance.
        [int]$DiscCount = 0,

        # Optional Window owner so the dialog centers over its parent.
        $Owner = $null
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null

    $title = if ($DiscCount -gt 0) {
        $word = if ($DiscCount -eq 1) { 'CD' } else { 'CDs' }
        "MusicRipper - $DiscCount $word ripped so far"
    } else {
        'MusicRipper - Insert Next Disc'
    }
    # XAML escapes for the dynamic title (basic safety; we control the input).
    $titleEsc = [System.Security.SecurityElement]::Escape($title)
    $summary = if ($LastRipSummary) { $LastRipSummary } else { '' }
    $summaryEsc = [System.Security.SecurityElement]::Escape($summary)
    $watchMsg = if ($DriveLetter) {
        "Pop the next CD into $DriveLetter -- the rip will start automatically."
    } else {
        '(Drive watcher unavailable.)'
    }
    $watchEsc = [System.Security.SecurityElement]::Escape($watchMsg)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$titleEsc"
        Width="540" Height="320"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        SizeToContent="Manual">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0"
               Text="Ready for the next CD!"
               FontSize="16" FontWeight="Bold" Margin="0,0,0,12"/>

    <Border Grid.Row="1" BorderBrush="#ccc" BorderThickness="1" Padding="10"
            Background="#fafafa">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBlock x:Name="SummaryText"
                   Text="$summaryEsc"
                   TextWrapping="Wrap" FontFamily="Consolas" FontSize="12"/>
      </ScrollViewer>
    </Border>

    <TextBlock Grid.Row="2"
               x:Name="WatchText"
               Text="$watchEsc"
               Foreground="#666" FontStyle="Italic"
               Margin="0,10,0,4"/>

    <TextBlock Grid.Row="3"
               Text="Tip: a stack of CDs is fine -- MusicRipper waits between each one."
               Foreground="#888" FontSize="11"
               Margin="0,0,0,10"/>

    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="QuitButton"     Content="I'm done -- Quit"
              Width="140" Height="34" Margin="0,0,10,0"
              ToolTip="Stop ripping and close MusicRipper."/>
      <Button x:Name="RipNextButton"  Content="Rip Next Disc"
              Width="160" Height="34" IsDefault="True"
              Background="#0a7" Foreground="White" FontWeight="Bold"
              ToolTip="Continue with the next CD. Insert it into the drive when prompted."/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $window.Owner = $Owner }
    Set-RipperWindowIcon $window

    # Phase 5.11: see Show-DuplicateDiscDialog -- steal foreground from
    # whatever was last in focus, since the host pwsh window is minimized.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    # Dispatcher sink (Phase-4 / 5.2 rule): every WPF window we open
    # gets an unhandled-exception sink writing to a per-window sidecar.
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\between-discs-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            if ($ex.InnerException) {
                $msg += "`n-- inner: $($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)"
            }
            Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            try { Write-RipperLog ERROR 'Show-RipperBetweenDiscsDialog' "Dispatcher exception: $($ex.GetType().FullName): $($ex.Message) (sidecar: $sidecar)" } catch {}
        } catch {}
        $e.Handled = $true
    })

    $rip  = $window.FindName('RipNextButton')
    $quit = $window.FindName('QuitButton')
    $watchText = $window.FindName('WatchText')

    # Result hashtable shared with the WMI subscriber. .Synchronized so the
    # CIM-event runspace can flip it without races.
    $state = [hashtable]::Synchronized(@{
        Action  = 'Quit'      # default if the X is clicked
        Trigger = 'WindowClose'
    })

    $rip.Add_Click({
        $state.Action  = 'RipNext'
        $state.Trigger = 'Button'
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $quit.Add_Click({
        $state.Action  = 'Quit'
        $state.Trigger = 'Button'
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    # --- Hybrid auto-detect via DispatcherTimer polling ------------------
    # Poll [IO.DriveInfo]::IsReady on the UI thread every 1.5s. Trigger
    # on a false -> true transition so we don't fire if a disc is already
    # loaded when the dialog opens (covers EjectAfterRip=$false). Runs on
    # the UI thread so closing the window from the tick handler doesn't
    # need Dispatcher.Invoke marshalling.
    $timer = $null
    if ($DriveLetter) {
        try {
            $letter = ($DriveLetter -replace '[\\\s]+$','')
            if ($letter -notmatch ':$') { $letter = "${letter}:" }
            $driveInfo = [System.IO.DriveInfo]::new($letter)
            # Baseline: capture current readiness so we only fire on a
            # transition. If the drive is empty now, $lastReady=$false and
            # the next insert wins immediately. If a disc is already in
            # there, the parent has to eject first (then insert) -- which
            # is the expected EjectAfterRip=$false flow.
            $lastReady = $false
            try { $lastReady = [bool]$driveInfo.IsReady } catch { $lastReady = $false }

            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
            # Stash everything the tick handler needs on the timer's Tag
            # so we don't depend on $script: scope (which the tick still
            # sees, but Tag keeps the dependency explicit).
            $timer.Tag = [pscustomobject]@{
                Drive     = $driveInfo
                LastReady = $lastReady
                Window    = $window
                State     = $state
            }
            $timer.Add_Tick({
                $ctx = $this.Tag
                $now = $false
                try { $now = [bool]$ctx.Drive.IsReady } catch { $now = $false }
                if ((-not $ctx.LastReady) -and $now) {
                    # Transition empty -> ready: a disc just arrived.
                    $this.Stop()
                    $ctx.State.Action  = 'RipNext'
                    $ctx.State.Trigger = 'AutoDetected'
                    try { $ctx.Window.DialogResult = $true } catch {}
                    $ctx.Window.Close()
                    return
                }
                $ctx.LastReady = $now
            })
            $timer.Start()
        } catch {
            try { Write-RipperLog WARN 'Show-RipperBetweenDiscsDialog' "Drive watcher init failed: $($_.Exception.Message). Falling back to button-only mode." } catch {}
            $watchText.Text = '(Drive watcher unavailable -- click Rip Next Disc when ready.)'
            $timer = $null
        }
    }

    try {
        [void]$window.ShowDialog()
    } finally {
        if ($timer) {
            try { $timer.Stop() } catch {}
        }
    }

    [pscustomobject]@{
        Action  = $state.Action
        Trigger = $state.Trigger
    }
}
