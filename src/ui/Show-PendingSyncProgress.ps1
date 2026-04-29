<#
.SYNOPSIS
    Phase 6.5: WPF dialog that drives Invoke-RipperPendingSync with
    live progress and produces a friendly summary screen at the end.

.DESCRIPTION
    Pipeline position:
        Shown by Start-Ripper.ps1 once at startup, BEFORE the
        do/while disc loop, when (a) cfg.RetryPendingSyncOnStartup
        is true and (b) sync-state.json contains at least one entry
        with a non-OK target. Skipped silently otherwise.

    Layout:
      - Pre-flight panel: list of pending albums up front so the
        user knows what's about to be retried (and can Cancel out
        if they don't want to wait).
      - Working panel:
          * "Album N of M" overall progress bar (segments)
          * Per-album progress bar (target N of M segments)
          * Status line ("Syncing to SynologyNAS for Mannheim
            Steamroller - Christmas (1984)...")
      - Summary panel (replaces Working when done):
          * "All N albums are now synced." (green) OR
          * "K of N albums synced. M still failing." (amber)
            with a friendly explanation referencing the auto-retry
            policy and pointing to ./src/tools/Sync-PendingAlbums.ps1
          * [OK] button -> closes with Action='Done'

    Cancel:
      - The Cancel button trips a synchronized flag that the worker
        runspace polls between albums. The currently in-flight album
        is allowed to finish (robocopy is hard to interrupt cleanly
        and a half-stopped copy just leaves a partial file the next
        retry would re-do). On cancel the dialog jumps straight to
        the summary panel with the partial result + an extra note.
      - Returns Action='Cancelled' so the caller knows to fall
        through to the normal rip flow rather than treating it as
        a crash.

    Cross-runspace plumbing:
      - Synchronised hashtable $state holds: Cancel (bool),
        Plan (object[]), Phase (string), AlbumIdx, AlbumTotal,
        AlbumLabel, AlbumKey, Done (bool), Summary (hashtable),
        Error (object).
      - Worker runspace dot-sources every dependency (same
        re-import pattern as Show-RipProgress.ps1's PostProcess
        action) and calls Invoke-RipperPendingSync with a
        ProgressCallback that mutates $state and a CancelRequested
        scriptblock that reads $state.Cancel.
      - DispatcherTimer on the UI thread polls $state every 250ms
        and updates the progress bars / status / panel visibility.

    Returns a [pscustomobject]:
        Action     'Done' | 'Cancelled' | 'Error'
        Summary    [hashtable] mirror of Invoke-RipperPendingSync's
                   return (Total, Synced, StillFailing, Skipped,
                   Cancelled, Albums)
        Error      [object] only when Action='Error'

.NOTES
    Per Phase-4/5.2 lesson: Dispatcher.add_UnhandledException sink
    installed and writes to
    %LOCALAPPDATA%\MusicRipper\logs\pending-sync-dispatcher.log.
#>

function Show-RipperPendingSyncProgress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [object]$Config,
        [Parameter(Mandatory)] [string]$RepoRoot,
        # Optional Window owner so the dialog centers over its parent.
        $Owner = $null
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null
    Add-Type -AssemblyName WindowsBase           | Out-Null

    # ---- Pre-flight: are there any pending albums at all? ----------------
    # Same logic as Invoke-RipperPendingSync but read-only, so we can skip
    # the dialog entirely when nothing's pending. Cheap to do twice.
    $configuredTargets = @()
    if ($Config.PSObject.Properties['SyncTargets'] -and $Config.SyncTargets) {
        $configuredTargets = @($Config.SyncTargets | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($configuredTargets.Count -eq 0) {
        return [pscustomobject]@{ Action='Done'; Summary=@{ Total=0;Synced=0;StillFailing=0;Skipped=0;Cancelled=$false;Albums=@() }; Error=$null }
    }

    $stateMap = Get-RipperLibrarySyncState -LibraryRoot $LibraryRoot
    $planResult = Get-RipperPendingSyncPlan -State $stateMap -ConfiguredTargets $configuredTargets
    $plan = @($planResult.Plan)
    if ($plan.Count -eq 0) {
        return [pscustomobject]@{ Action='Done'; Summary=@{ Total=0;Synced=0;StillFailing=0;Skipped=0;Cancelled=$false;Albums=@() }; Error=$null }
    }
    if ($planResult.Pruned) {
        try { Save-RipperLibrarySyncState -LibraryRoot $LibraryRoot -Index $stateMap } catch { }
    }

    # Convert plan into a flat list of human labels for the up-front panel.
    $planLabels = @()
    $discIndex = $null
    try { $discIndex = Get-RipperLibraryDiscIndex -LibraryRoot $LibraryRoot } catch { $discIndex = $null }
    foreach ($p in $plan) {
        $label = $p.Key
        $discId = if ($p.Entry.PSObject.Properties['DiscId']) { [string]$p.Entry.DiscId } else { '' }
        if ($discId -and $discIndex -and $discIndex.ContainsKey($discId)) {
            $row = $discIndex[$discId]
            if ($row.PSObject.Properties['Label'] -and $row.Label) { $label = [string]$row.Label }
        }
        $bad = @()
        foreach ($n in $configuredTargets) {
            if (-not $p.Entry.Targets.PSObject.Properties[$n]) { $bad += "$n=missing"; continue }
            $st = [string]$p.Entry.Targets.$n.Status
            if ($st -ne 'OK') { $bad += "$n=$st" }
        }
        $planLabels += [pscustomobject]@{
            Label = $label
            Detail = ($bad -join ', ')
        }
    }

    # ---- Build XAML ------------------------------------------------------
    $totalAlbumLabel = "{0} album(s) need to retry sync to {1}" -f $plan.Count, ($configuredTargets -join ', ')
    $totalAlbumLabelEsc = [System.Security.SecurityElement]::Escape($totalAlbumLabel)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MusicRipper - Catching up on pending syncs"
        Width="640" Height="500"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>  <!-- header -->
      <RowDefinition Height="*"/>     <!-- body (panels) -->
      <RowDefinition Height="Auto"/>  <!-- buttons -->
    </Grid.RowDefinitions>

    <!-- Header -->
    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock x:Name="HeaderText" FontSize="16" FontWeight="SemiBold"
                 Text="Catching up on pending syncs"/>
      <TextBlock x:Name="SubHeaderText" Margin="0,4,0,0" Foreground="#555"
                 TextWrapping="Wrap"
                 Text="$totalAlbumLabelEsc"/>
    </StackPanel>

    <!-- Body: 3 panels, only one visible at a time -->
    <Grid Grid.Row="1">

      <!-- Pre-flight panel: list of pending albums + Start / Cancel -->
      <Grid x:Name="PreflightPanel" Visibility="Visible">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" TextWrapping="Wrap" Margin="0,0,0,8" Foreground="#333"
                   Text="A previous run didn't finish syncing every album to your sync target(s). We'll retry these now -- you can cancel and rip discs instead, and we'll try again next launch (or you can run ./src/tools/Sync-PendingAlbums.ps1 manually)."/>
        <Border Grid.Row="1" BorderBrush="#CCC" BorderThickness="1" Padding="6">
          <ListView x:Name="PreflightList" BorderThickness="0">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Album" Width="380" DisplayMemberBinding="{Binding Label}"/>
                <GridViewColumn Header="Pending targets" Width="190" DisplayMemberBinding="{Binding Detail}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Border>
      </Grid>

      <!-- Working panel: progress bars + status -->
      <Grid x:Name="WorkingPanel" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="WorkingStatusText" Margin="0,0,0,12"
                   FontSize="14" TextWrapping="Wrap"
                   Text="Starting..."/>
        <Grid Grid.Row="1" Margin="0,0,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="80"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="60"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="Overall" VerticalAlignment="Center" Foreground="#555"/>
          <ProgressBar Grid.Column="1" x:Name="OverallBar" Height="18" Minimum="0" Maximum="1" Value="0"/>
          <TextBlock Grid.Column="2" x:Name="OverallText" Margin="8,0,0,0" VerticalAlignment="Center"
                     TextAlignment="Right" FontWeight="Bold" Text="0 / 0"/>
        </Grid>
        <Grid Grid.Row="2" Margin="0,0,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="80"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="60"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="Album" VerticalAlignment="Center" Foreground="#555"/>
          <ProgressBar Grid.Column="1" x:Name="AlbumBar" Height="14" Minimum="0" Maximum="1" Value="0" IsIndeterminate="True"/>
          <TextBlock Grid.Column="2" x:Name="AlbumText" Margin="8,0,0,0" VerticalAlignment="Center"
                     TextAlignment="Right" Text=""/>
        </Grid>
        <TextBlock Grid.Row="3" x:Name="CurrentAlbumText" Margin="0,8,0,0"
                   FontStyle="Italic" Foreground="#666" TextWrapping="Wrap" Text=""/>
      </Grid>

      <!-- Summary panel -->
      <Grid x:Name="SummaryPanel" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="SummaryHeadline" FontSize="16" FontWeight="SemiBold"
                   Margin="0,0,0,10" TextWrapping="Wrap" Text=""/>
        <TextBlock Grid.Row="1" x:Name="SummaryBody" TextWrapping="Wrap"
                   Margin="0,0,0,12" Foreground="#333" Text=""/>
        <Border Grid.Row="2" BorderBrush="#CCC" BorderThickness="1" Padding="6">
          <ListView x:Name="SummaryList" BorderThickness="0">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Album" Width="320" DisplayMemberBinding="{Binding Label}"/>
                <GridViewColumn Header="Result" Width="80" DisplayMemberBinding="{Binding Status}"/>
                <GridViewColumn Header="Detail" Width="180" DisplayMemberBinding="{Binding Diagnostic}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Border>
      </Grid>
    </Grid>

    <!-- Buttons -->
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="StartButton"  Content="Sync now" Padding="14,6" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="CancelButton" Content="Cancel (rip discs instead)" Padding="14,6" Margin="0,0,8,0" IsCancel="True"/>
      <Button x:Name="OkButton"     Content="OK" Padding="14,6" MinWidth="80" Visibility="Collapsed" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { try { $window.Owner = $Owner } catch { } }

    # Per Phase-4/5.2 lesson: dispatcher unhandled-exception sink.
    $logDir = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $dispatcherLog = Join-Path $logDir 'pending-sync-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $msg = "[$([DateTime]::Now.ToString('o'))] $($e.Exception.GetType().FullName): $($e.Exception.Message)`n$($e.Exception.StackTrace)`n"
            Add-Content -LiteralPath $dispatcherLog -Value $msg
        } catch { }
        $e.Handled = $true
    })

    $controls = @{}
    foreach ($n in @(
        'HeaderText','SubHeaderText',
        'PreflightPanel','PreflightList',
        'WorkingPanel','WorkingStatusText','OverallBar','OverallText',
        'AlbumBar','AlbumText','CurrentAlbumText',
        'SummaryPanel','SummaryHeadline','SummaryBody','SummaryList',
        'StartButton','CancelButton','OkButton'
    )) {
        $controls[$n] = $window.FindName($n)
    }

    # Pre-populate the up-front list.
    foreach ($row in $planLabels) {
        $controls.PreflightList.Items.Add($row) | Out-Null
    }

    # ---- Shared state for the worker runspace ---------------------------
    $shared = [hashtable]::Synchronized(@{
        Cancel        = $false
        Phase         = 'preflight'   # preflight | working | done | error
        AlbumIdx      = 0
        AlbumTotal    = $plan.Count
        AlbumKey      = ''
        AlbumLabel    = ''
        Summary       = $null
        Error         = $null
        UserAction    = ''            # 'Cancelled' if Cancel button pressed
    })

    $startWorker = {
        $shared.Phase = 'working'
        $controls.PreflightPanel.Visibility = 'Collapsed'
        $controls.WorkingPanel.Visibility   = 'Visible'
        $controls.StartButton.Visibility    = 'Collapsed'
        $controls.WorkingStatusText.Text    = 'Starting...'
        $controls.OverallBar.Value          = 0
        $controls.OverallText.Text          = "0 / $($shared.AlbumTotal)"

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('shared',      $shared)
        $rs.SessionStateProxy.SetVariable('repoRoot',    $RepoRoot)
        $rs.SessionStateProxy.SetVariable('LibraryRoot', $LibraryRoot)
        $rs.SessionStateProxy.SetVariable('Config',      $Config)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Set-StrictMode -Version 3.0
            $ErrorActionPreference = 'Stop'
            try {
                Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
                Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
                . (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')
                . (Join-Path $repoRoot 'src\sync\Get-LibrarySyncState.ps1')
                . (Join-Path $repoRoot 'src\sync\Invoke-RipperSync.ps1')
                . (Join-Path $repoRoot 'src\sync\Sync-ToOneDrive.ps1')
                . (Join-Path $repoRoot 'src\sync\Sync-ToSynologyNAS.ps1')
                . (Join-Path $repoRoot 'src\sync\Invoke-LibraryRetention.ps1')
                . (Join-Path $repoRoot 'src\sync\Invoke-PendingSync.ps1')
                . (Join-Path $repoRoot 'src\ui\Show-TargetExistsDialog.ps1')

                $cb = {
                    param($Phase, $AlbumIdx, $AlbumTotal, $AlbumKey, $AlbumLabel, $ResultStatus, $ResultDetail)
                    $shared.Phase      = $Phase
                    $shared.AlbumIdx   = $AlbumIdx
                    $shared.AlbumTotal = $AlbumTotal
                    $shared.AlbumKey   = $AlbumKey
                    $shared.AlbumLabel = $AlbumLabel
                }
                $cancelCb = { return [bool]$shared.Cancel }

                $shared.Summary = Invoke-RipperPendingSync `
                    -LibraryRoot      $LibraryRoot `
                    -Config           $Config `
                    -ProgressCallback $cb `
                    -CancelRequested  $cancelCb
                $shared.Phase = 'done'
            } catch {
                $shared.Error = $_
                $shared.Phase = 'error'
            }
        })
        # Fire and forget; the runspace cleans itself up after the
        # tick handler sees Phase=done|error.
        $shared.PsRef = $ps
        $shared.RsRef = $rs
        [void]$ps.BeginInvoke()
    }.GetNewClosure()

    # Wire buttons.
    $controls.StartButton.Add_Click({ & $startWorker }.GetNewClosure())
    $controls.CancelButton.Add_Click({
        if ($shared.Phase -eq 'working') {
            $shared.Cancel = $true
            $controls.CancelButton.IsEnabled = $false
            $controls.WorkingStatusText.Text = 'Cancelling after current album finishes...'
        } else {
            # Pre-flight: just close.
            $shared.UserAction = 'Cancelled'
            $window.Close()
        }
    }.GetNewClosure())
    $controls.OkButton.Add_Click({ $window.Close() }.GetNewClosure())

    # ---- Tick: poll $shared and update UI -------------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)

    # Helpers as variables -- WPF Add_Click can't see script-scope functions
    # (per Phase-1 pitfall in repo memory).
    $_showSummary = {
        $sum = $shared.Summary
        $controls.WorkingPanel.Visibility = 'Collapsed'
        $controls.SummaryPanel.Visibility = 'Visible'
        $controls.CancelButton.Visibility = 'Collapsed'
        $controls.OkButton.Visibility     = 'Visible'
        $controls.OkButton.Focus() | Out-Null

        if (-not $sum) {
            $controls.SummaryHeadline.Text = 'Nothing to do.'
            $controls.SummaryBody.Text     = ''
            return
        }

        # Populate the per-album list.
        foreach ($a in $sum.Albums) {
            $controls.SummaryList.Items.Add([pscustomobject]@{
                Label      = $a.Label
                Status     = $a.Status
                Diagnostic = $a.Diagnostic
            }) | Out-Null
        }

        if ($sum.Cancelled) {
            $controls.SummaryHeadline.Text = "Stopped at your request."
            $controls.SummaryHeadline.Foreground = '#A00'
            $controls.SummaryBody.Text = "Synced $($sum.Synced) of $($sum.Total) album(s) before cancelling. The rest stay pending and we'll try again on the next launch (or you can run ./src/tools/Sync-PendingAlbums.ps1 manually)."
        } elseif ($sum.StillFailing -eq 0) {
            $controls.SummaryHeadline.Text = "All caught up. $($sum.Synced) album(s) synced."
            $controls.SummaryHeadline.Foreground = '#080'
            $controls.SummaryBody.Text = "Some earlier rips couldn't be pushed to your sync target(s) (probably the NAS or OneDrive was offline). MusicRipper just retried them automatically -- everything is now mirrored."
        } else {
            $controls.SummaryHeadline.Text = "$($sum.Synced) of $($sum.Total) album(s) synced. $($sum.StillFailing) still failing."
            $controls.SummaryHeadline.Foreground = '#A60'
            $controls.SummaryBody.Text = "Some albums still couldn't reach the sync target. We'll try again automatically next time you launch MusicRipper. Common causes: the NAS is off, OneDrive is offline, or saved credentials need refreshing. To investigate, run ./src/tools/Test-SynologySync.ps1 (NAS) or check Tools > sync-state.json."
        }
    }.GetNewClosure()

    $_showError = {
        $controls.WorkingPanel.Visibility = 'Collapsed'
        $controls.SummaryPanel.Visibility = 'Visible'
        $controls.CancelButton.Visibility = 'Collapsed'
        $controls.OkButton.Visibility     = 'Visible'
        $controls.SummaryHeadline.Text       = 'The retry crashed.'
        $controls.SummaryHeadline.Foreground = '#A00'
        $msg = if ($shared.Error) { $shared.Error.Exception.Message } else { 'unknown error' }
        $controls.SummaryBody.Text = "An unexpected error occurred while retrying pending syncs:`n`n  $msg`n`nThe rip pipeline is unaffected. See the dispatcher log at $dispatcherLog."
    }.GetNewClosure()

    # WPF Add_ handlers can't see locals in our outer func via .GetNewClosure
    # if those locals reference each other. Bind them to script scope so
    # the tick handler can call them.
    Set-Variable -Name '_showSummary' -Value $_showSummary -Scope Script
    Set-Variable -Name '_showError'   -Value $_showError   -Scope Script

    $timer.Add_Tick({
        try {
            switch ($shared.Phase) {
                'working' {
                    $i = [int]$shared.AlbumIdx
                    $t = [int]$shared.AlbumTotal
                    if ($t -gt 0) {
                        $controls.OverallBar.Value = [double]$i / [double]$t
                        $controls.OverallText.Text = "$i / $t"
                    }
                    $controls.AlbumText.Text = if ($t -gt 0) { "Album $i of $t" } else { '' }
                    if ($shared.AlbumLabel) {
                        $controls.WorkingStatusText.Text = "Syncing: $($shared.AlbumLabel)"
                        $controls.CurrentAlbumText.Text  = $shared.AlbumKey
                    }
                }
                'done'  { $timer.Stop(); & $script:_showSummary }
                'error' { $timer.Stop(); & $script:_showError }
            }
        } catch {
            try { Add-Content -LiteralPath $dispatcherLog -Value "[tick] $($_.Exception.Message)`n" } catch { }
        }
    }.GetNewClosure())
    $timer.Start()

    try {
        [void]$window.ShowDialog()
    } finally {
        $timer.Stop()
        # Best-effort: stop the worker pipeline if it's still running.
        if ($shared.PsRef) {
            try { $shared.PsRef.Stop()  } catch { }
            try { $shared.PsRef.Dispose() } catch { }
        }
        if ($shared.RsRef) {
            try { $shared.RsRef.Close()   } catch { }
            try { $shared.RsRef.Dispose() } catch { }
        }
    }

    # Decide return Action.
    $action = if ($shared.UserAction -eq 'Cancelled') {
        'Cancelled'
    } elseif ($shared.Phase -eq 'error') {
        'Error'
    } elseif ($shared.Summary -and $shared.Summary.Cancelled) {
        'Cancelled'
    } else {
        'Done'
    }

    [pscustomobject]@{
        Action  = $action
        Summary = $shared.Summary
        Error   = $shared.Error
    }
}
