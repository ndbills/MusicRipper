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
        - In parallel it subscribes to Win32_VolumeChangeEvent
          (EventType = 2 -> arrival) for the configured drive letter.
          When a disc arrives the dialog auto-closes with Action='RipNext',
          so the parent doesn't have to click anything.
        - Closing the window via the title-bar X is treated as 'Quit'.

    Returns a [pscustomobject] with:
        Action    'RipNext' | 'Quit'
        Trigger   'Button' | 'AutoDetected' | 'WindowClose'

.NOTES
    Per Phase-4 / 5.2 lesson: a Dispatcher.add_UnhandledException sink is
    installed immediately after XamlReader.Load and writes to a sidecar
    log under %LOCALAPPDATA%\MusicRipper\logs\between-discs-dispatcher.log
    so any binding / template error is captured instead of bubbling up as
    a silent NRE at ShowDialog.

    The CIM event subscription is registered with Register-CimIndicationEvent
    (-SourceIdentifier so we can unregister cleanly in a finally block) and
    is filtered to the configured drive letter to avoid picking up USB-stick
    insertions or unrelated volume changes.
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
        "MusicRipper - $DiscCount disc(s) ripped this session"
    } else {
        'MusicRipper - Insert Next Disc'
    }
    # XAML escapes for the dynamic title (basic safety; we control the input).
    $titleEsc = [System.Security.SecurityElement]::Escape($title)
    $summary = if ($LastRipSummary) { $LastRipSummary } else { '' }
    $summaryEsc = [System.Security.SecurityElement]::Escape($summary)
    $watchMsg = if ($DriveLetter) {
        "Watching $DriveLetter for a new disc..."
    } else {
        '(Drive watcher unavailable.)'
    }
    $watchEsc = [System.Security.SecurityElement]::Escape($watchMsg)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$titleEsc"
        Width="520" Height="280"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        SizeToContent="Manual">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0"
               Text="Insert the next disc, or click Quit to finish."
               FontSize="15" FontWeight="Bold" Margin="0,0,0,12"/>

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
               Margin="0,10,0,10"/>

    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="QuitButton"     Content="Quit"
              Width="120" Height="34" Margin="0,0,10,0"/>
      <Button x:Name="RipNextButton"  Content="Rip Next Disc"
              Width="160" Height="34" IsDefault="True"
              Background="#0a7" Foreground="White" FontWeight="Bold"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $window.Owner = $Owner }

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

    # --- Hybrid auto-detect via WMI volume-change events ------------------
    # SourceIdentifier so we can unregister in finally{}. EventType=2 is
    # arrival ("device added"); the event's TargetInstance.DriveName is
    # the drive letter with a trailing colon (e.g. "D:").
    $sourceId = "MusicRipper.BetweenDiscs.$([guid]::NewGuid().ToString('N'))"
    $registered = $false
    if ($DriveLetter) {
        try {
            $letter = ($DriveLetter -replace '[\\\s]+$','')
            if ($letter -notmatch ':$') { $letter = "${letter}:" }
            $query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2"
            # We can't safely filter to a specific DriveName in the WQL
            # because some platforms report it on the inserted instance
            # rather than as a top-level prop -- filter in the action
            # instead.
            $script:RipperBetweenDiscsState = $state
            $script:RipperBetweenDiscsWindow = $window
            $script:RipperBetweenDiscsLetter = $letter
            Register-CimIndicationEvent `
                -SourceIdentifier $sourceId `
                -Query            $query `
                -Action {
                    try {
                        $ev = $Event.SourceEventArgs.NewEvent
                        $drv = $null
                        if ($ev) {
                            try { $drv = [string]$ev.DriveName } catch {}
                        }
                        $want = $script:RipperBetweenDiscsLetter
                        if (-not $drv -or ($drv -and $drv.ToUpperInvariant() -eq $want.ToUpperInvariant())) {
                            $st = $script:RipperBetweenDiscsState
                            $win = $script:RipperBetweenDiscsWindow
                            $st.Action  = 'RipNext'
                            $st.Trigger = 'AutoDetected'
                            # Marshal Close() onto the UI thread.
                            $win.Dispatcher.Invoke([action]{
                                try { $win.DialogResult = $true } catch {}
                                $win.Close()
                            })
                        }
                    } catch {
                        # Swallow -- we don't want a CIM hiccup to crash
                        # the dialog. Dispatcher sink will catch UI-side
                        # issues.
                    }
                } | Out-Null
            $registered = $true
        } catch {
            try { Write-RipperLog WARN 'Show-RipperBetweenDiscsDialog' "WMI subscribe failed: $($_.Exception.Message). Falling back to button-only mode." } catch {}
            $watchText.Text = '(Drive watcher unavailable -- click Rip Next Disc when ready.)'
        }
    }

    try {
        [void]$window.ShowDialog()
    } finally {
        if ($registered) {
            try { Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue } catch {}
            try { Get-EventSubscriber -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue } catch {}
        }
        Remove-Variable -Name RipperBetweenDiscsState,RipperBetweenDiscsWindow,RipperBetweenDiscsLetter -Scope Script -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        Action  = $state.Action
        Trigger = $state.Trigger
    }
}
