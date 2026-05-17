<#
.SYNOPSIS
    Phase 6.6.E: WPF "Register optical drive" dialog -- in-app
    replacement for `setup/Register-Drive.ps1`.

.DESCRIPTION
    Detects the optical drive(s) attached to this machine, looks up the
    AccurateRip read offset, and returns the chosen drive + offset back
    to the caller. The parent config dialog stamps the result onto $cfg
    and persists it via the normal Save flow.

    Layout:
      - Drive ComboBox       (auto-populated; current cfg drive pre-
                              selected when present)
      - "Look up offset"     (runs in a worker runspace so the UI
                              stays responsive; marquee progress bar)
      - Offset TextBox       (auto-filled by lookup; user can override
                              -- e.g. when the drive isn't in the cache
                              and AccurateRip is unreachable)
      - Status text          (live status: "Looking up...", success
                              line, or "no match" with a hint to set
                              0 or look the offset up manually)
      - OK / Cancel

    Returns a hashtable @{ Drive = 'D:'; Offset = 6 } on OK, or $null
    on Cancel / window close.

.NOTES
    Uses the standard Topmost-then-clear focus-steal trick (parent
    pwsh host is usually minimised to tray) and the dispatcher
    unhandled-exception sink pattern.

    The captured-hashtable result-passing pattern is required because
    inside a dot-sourced function .GetNewClosure() handlers can't
    round-trip $script:* writes back to a sibling read at the
    function level (see /memories/powershell.md "WPF Add_Click
    closures and $script: scope").
#>

Set-StrictMode -Version 3.0

# Load deps. The dialog is dot-sourced from Start-Ripper so these
# Import-Module calls are idempotent in the normal flow; they're
# here so the dialog can also be sourced standalone for repro/test.
$libRoot = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libRoot 'DriveRegistration.psd1') -Force
# Logging is also imported by the parent runspace; load defensively
# so the dispatcher-tick log lines below never throw if the dialog
# is sourced standalone (Phase 6.4.4).
Import-Module (Join-Path $libRoot 'Logging.psd1') -Force
# v0.3.0: Updater.psm1 owns Get-RipperAccurateRipDatabaseUrl (the
# centralized URL the 'Browse AccurateRip database' button opens).
Import-Module (Join-Path $libRoot 'Updater.psd1') -Force

function Show-RipperRegisterDriveDialog {
<#
.SYNOPSIS
    Modal WPF dialog for picking an optical drive + AccurateRip offset.

.PARAMETER CurrentDrive
    Currently-saved drive letter (e.g. 'D:'). Used to pre-select the
    matching ComboBox row when the drive is still present.

.PARAMETER CurrentOffset
    Currently-saved offset (samples). Pre-fills the Offset textbox so
    a user who only wants to re-pick the drive doesn't have to retype.

.PARAMETER RepoRoot
    Path to the repo root (so the dialog can locate
    data/driveoffsets.cached.json without re-deriving it).

.PARAMETER Owner
    Optional parent Window for modality / centring.

.OUTPUTS
    Hashtable @{ Drive='D:'; Offset=6 } on OK, or $null on Cancel.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$CurrentDrive  = $null,
        [Nullable[int]]$CurrentOffset = $null,
        [Parameter(Mandatory)] [string]$RepoRoot,
        $Owner = $null
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null

    $cachedListPath = Join-Path $RepoRoot 'data\driveoffsets.cached.json'

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MusicRipper - register optical drive"
        Width="540" SizeToContent="Height"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" ShowInTaskbar="False">
  <StackPanel Margin="14">

    <TextBlock TextWrapping="Wrap" Margin="0,0,0,12">
      MusicRipper needs to know which optical drive to use and its
      <Bold>AccurateRip read offset</Bold> (a small per-drive value
      used to verify rips against the AccurateRip database). The
      lookup tries the live AccurateRip page first and falls back
      to a bundled cache.
    </TextBlock>

    <TextBlock Text="Optical drive" FontWeight="Bold"/>
    <ComboBox x:Name="DriveCombo" Margin="0,2,0,12" Padding="4"/>

    <TextBlock Text="AccurateRip offset (samples)" FontWeight="Bold"/>
    <Grid Margin="0,2,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="120"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="OffsetText" Grid.Column="0" Padding="4"
               ToolTip="Integer; positive = drive reads ahead. 0 disables AR verification."/>
      <TextBlock Grid.Column="1"/>
      <Button   x:Name="LookupButton" Grid.Column="2"
                Content="Look up offset" Padding="10,4" Margin="6,0,0,0"
                ToolTip="Query AccurateRip for the selected drive's known offset."/>
    </Grid>

    <ProgressBar x:Name="ProgBar" Height="6" Margin="0,0,0,8"
                 IsIndeterminate="False" Visibility="Collapsed"/>

    <TextBlock x:Name="StatusText" TextWrapping="Wrap"
               Foreground="#666" Margin="0,0,0,12"/>

    <!-- v0.3.0: 'Drive not detected correctly?' escape hatch.
         USB-to-SATA adapters / docking stations mask the optical
         drive's real model with the adapter's chipset name, so the
         auto-lookup against the AccurateRip page misses. Two ways
         out from here:
           - type the underlying drive model and look it up directly
           - browse the AccurateRip database in your browser to find
             the right model + offset (then either type the model
             above or the offset directly into the field higher up).
         Collapsed by default so normal users don't see the clutter.
    -->
    <Expander Header="Drive not detected correctly? (USB adapter / docking station)"
              Margin="0,0,0,12" Foreground="#444">
      <StackPanel Margin="0,8,4,0">
        <TextBlock TextWrapping="Wrap" Margin="0,0,0,8"
                   Foreground="#666" FontSize="11">
          USB-to-SATA adapters often mask the drive's real model name
          with the adapter's chipset name. Type your drive's actual
          model below to look it up directly, or browse the
          AccurateRip database in your browser to find the right value.
        </TextBlock>
        <Grid Margin="0,0,0,6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="ManualDriveText" Grid.Column="0" Padding="4"
                   ToolTip="The drive's actual model name, e.g. 'TSSTcorp CDDVDW SH-224DB'."/>
          <Button  x:Name="ManualLookupBtn" Grid.Column="1"
                   Content="Look up by model" Padding="10,4" Margin="6,0,0,0"
                   ToolTip="Search the AccurateRip database using this typed model name instead of the drive name Windows reports."/>
        </Grid>
        <Button x:Name="BrowseDbBtn" Content="Browse AccurateRip database (web)"
                HorizontalAlignment="Left" Padding="10,4"
                ToolTip="Open http://www.accuraterip.com/driveoffsets.htm in your default browser."/>
      </StackPanel>
    </Expander>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="OkBtn"     Content="OK"     Width="90"
              Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="CancelBtn" Content="Cancel" Width="90"
              IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)

    if ($Owner) { try { $window.Owner = $Owner } catch {} }
    Set-RipperWindowIcon $window

    # Dispatcher unhandled-exception sink.
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\register-drive-dialog-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex  = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            try {
                $dir = Split-Path -Parent $sidecar
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            } catch {}
        } catch {}
        $e.Handled = $true
    })

    # Topmost-then-clear so we surface above the minimised host.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    $driveCombo  = $window.FindName('DriveCombo')
    $offsetText  = $window.FindName('OffsetText')
    $lookupBtn   = $window.FindName('LookupButton')
    $progBar     = $window.FindName('ProgBar')
    $statusText  = $window.FindName('StatusText')
    # v0.3.0: manual-lookup escape hatch.
    $manualText  = $window.FindName('ManualDriveText')
    $manualBtn   = $window.FindName('ManualLookupBtn')
    $browseBtn   = $window.FindName('BrowseDbBtn')
    $okBtn       = $window.FindName('OkBtn')
    $cancelBtn   = $window.FindName('CancelBtn')

    # ---- Populate drive list ------------------------------------------
    $drives = @(Get-RipperOpticalDrives)
    if ($drives.Count -eq 0) {
        $statusText.Text = 'No optical drives detected. Plug in a USB CD/DVD drive and re-open this dialog.'
        $statusText.Foreground = '#a00'
        $driveCombo.IsEnabled = $false
        $lookupBtn.IsEnabled  = $false
        $okBtn.IsEnabled      = $false
    } else {
        foreach ($d in $drives) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = "$($d.Drive)   $($d.Name)"
            $item.Tag     = $d
            [void]$driveCombo.Items.Add($item)
        }
        # Pre-select current cfg drive if still present, else first row.
        $idx = 0
        if ($CurrentDrive) {
            for ($i = 0; $i -lt $drives.Count; $i++) {
                if ($drives[$i].Drive -eq $CurrentDrive) { $idx = $i; break }
            }
        }
        $driveCombo.SelectedIndex = $idx
    }

    if ($null -ne $CurrentOffset) {
        $offsetText.Text = [string]$CurrentOffset
    }

    # ---- Lookup worker runspace --------------------------------------
    # Shared state for cross-runspace handoff. Phase: 'idle' | 'running'
    # | 'done' | 'error'. Result: int? on done, string on error.
    $shared = [hashtable]::Synchronized(@{
        Phase  = 'idle'
        Result = $null
        Error  = $null
        DriveName = ''
    })

    $startLookup = {
        # v0.3.0: parameterized over $args[0] = drive-name string.
        # Both LookupButton (passes the ComboBox's selected drive name)
        # and ManualLookupBtn (passes the user-typed model from the
        # Expander) call this. Empty / whitespace -> no-op + warning
        # status, so a stray click doesn't kick off a useless lookup.
        #
        # v0.3.0: the second positional arg toggles the matcher's
        # bi-directional mode. Auto-lookup (Windows-reported name) is
        # always richer than AR entries, so we leave the strict
        # forward-direction rule on (preserves v6.4.5 firmware-variant
        # disambiguation). Manual lookup passes -MatchPartialModel
        # because the user often types just a bare model number
        # ('UJ8E2') that's SHORTER than the full AR entry
        # ('Panasonic UJ8E2') -- the reverse-direction match.
        param(
            [string]$DriveName,
            [bool]$MatchPartialModel = $false
        )
        if ([string]::IsNullOrWhiteSpace($DriveName)) {
            $statusText.Text       = 'Pick a drive (or type a model name) first.'
            $statusText.Foreground = '#a00'
            return
        }
        $DriveName = $DriveName.Trim()

        $shared.Phase     = 'running'
        $shared.Result    = $null
        $shared.Error     = $null
        $shared.DriveName = $DriveName

        $statusText.Text       = "Querying AccurateRip for '$DriveName'..."
        $statusText.Foreground = '#666'
        $progBar.Visibility    = 'Visible'
        $progBar.IsIndeterminate = $true
        $lookupBtn.IsEnabled   = $false
        $manualBtn.IsEnabled   = $false
        $driveCombo.IsEnabled  = $false
        $okBtn.IsEnabled       = $false

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('shared',             $shared)
        $rs.SessionStateProxy.SetVariable('repoRoot',           $RepoRoot)
        $rs.SessionStateProxy.SetVariable('driveName',          $DriveName)
        $rs.SessionStateProxy.SetVariable('cachedListPath',     $cachedListPath)
        $rs.SessionStateProxy.SetVariable('matchPartialModel',  [bool]$MatchPartialModel)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Set-StrictMode -Version 3.0
            $ErrorActionPreference = 'Stop'
            try {
                Import-Module (Join-Path $repoRoot 'src\lib\DriveRegistration.psd1') -Force
                # Phase 6.4.4: rich entry (Offset + MatchedName + Source)
                # so the parent runspace can log WHICH AccurateRip row
                # matched the Windows drive name. Helps confirm the
                # right physical drive was identified.
                $shared.Result = Find-RipperAccurateRipEntry `
                                    -DriveName          $driveName `
                                    -CachedListPath     $cachedListPath `
                                    -MatchPartialModel:$matchPartialModel
                $shared.Phase  = 'done'
            } catch {
                $shared.Error = $_.Exception.Message
                $shared.Phase = 'error'
            }
        })
        [void]$ps.BeginInvoke()
    }.GetNewClosure()

    $lookupBtn.Add_Click({
        # Auto-lookup against the drive Windows reports for the
        # ComboBox-selected row. Strict forward-direction matching
        # only -- the Windows-reported name is always richer than
        # the AR entry, so reverse-direction matching would only
        # introduce false positives here (v6.4.5 firmware-variant).
        $sel = $driveCombo.SelectedItem
        if (-not $sel) {
            $statusText.Text       = 'Pick a drive first.'
            $statusText.Foreground = '#a00'
            return
        }
        & $startLookup $sel.Tag.Name $false
    }.GetNewClosure())

    $manualBtn.Add_Click({
        # v0.3.0: lookup against the user-typed model string from the
        # Expander. Used when the ComboBox-selected drive is masked
        # by a USB-to-SATA adapter so the auto-lookup keeps missing.
        # Passes -MatchPartialModel because bare-model input ('UJ8E2')
        # is typically SHORTER than the AR entry ('Panasonic UJ8E2')
        # -- needs the reverse-direction match.
        & $startLookup $manualText.Text $true
    }.GetNewClosure())

    $browseBtn.Add_Click({
        # v0.3.0: open the AccurateRip drive-offsets index page in the
        # user's default browser. ProcessStartInfo + UseShellExecute is
        # the proven-from-Show-UpdateDialog WPF-event pattern; raw URLs
        # occasionally trip Start-Process's parameter binding.
        $url = Get-RipperAccurateRipDatabaseUrl
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName        = $url
            $psi.UseShellExecute = $true
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        } catch {
            Write-RipperLog WARN 'Show-RegisterDriveDialog' "Browse AccurateRip click failed to open '$url': $($_.Exception.Message)"
            $statusText.Text       = "Couldn't open browser. Visit $url manually."
            $statusText.Foreground = '#a00'
        }
    }.GetNewClosure())

    # ---- Tick: poll $shared and update UI -----------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if ($shared.Phase -eq 'done') {
            $progBar.IsIndeterminate = $false
            $progBar.Visibility      = 'Collapsed'
            $lookupBtn.IsEnabled     = $true
            $manualBtn.IsEnabled     = $true
            $driveCombo.IsEnabled    = $true
            $okBtn.IsEnabled         = $true
            if ($null -ne $shared.Result) {
                $entry = $shared.Result
                $offsetText.Text = [string]$entry.Offset
                $statusText.Text = "Found offset $($entry.Offset) for '$($shared.DriveName)' (matched AccurateRip entry: '$($entry.MatchedName)', source: $($entry.Source))."
                $statusText.Foreground = '#070'
                Write-RipperLog INFO 'Show-RegisterDriveDialog' "AR lookup HIT for drive '$($shared.DriveName)': offset=$($entry.Offset), matched='$($entry.MatchedName)', source=$($entry.Source)."
            } else {
                $statusText.Text       = "No AccurateRip offset found for '$($shared.DriveName)'. Try the 'Drive not detected correctly?' panel below to look up the underlying drive model, or enter the value manually if you know it (0 = AR verification disabled)."
                $statusText.Foreground = '#a60'
                if (-not $offsetText.Text) { $offsetText.Text = '0' }
                Write-RipperLog INFO 'Show-RegisterDriveDialog' "AR lookup MISS for drive '$($shared.DriveName)': no normalized substring match in live page or cache."
            }
            $shared.Phase = 'idle'
        }
        elseif ($shared.Phase -eq 'error') {
            $progBar.IsIndeterminate = $false
            $progBar.Visibility      = 'Collapsed'
            $lookupBtn.IsEnabled     = $true
            $manualBtn.IsEnabled     = $true
            $driveCombo.IsEnabled    = $true
            $okBtn.IsEnabled         = $true
            $statusText.Text         = "Lookup failed: $($shared.Error)"
            $statusText.Foreground   = '#a00'
            Write-RipperLog WARN 'Show-RegisterDriveDialog' "AR lookup ERROR for drive '$($shared.DriveName)': $($shared.Error)"
            $shared.Phase = 'idle'
        }
    }.GetNewClosure())
    $timer.Start()

    # Captured-hashtable result (see /memories/powershell.md note).
    $resultBox = @{ Value = $null }

    $okBtn.Add_Click({
        $sel = $driveCombo.SelectedItem
        if (-not $sel) {
            $statusText.Text       = 'Pick a drive first.'
            $statusText.Foreground = '#a00'
            return
        }
        $driveObj = $sel.Tag
        $offsetRaw = $offsetText.Text.Trim()
        if (-not ($offsetRaw -match '^-?\d+$')) {
            $statusText.Text       = 'Offset must be an integer (positive, 0, or negative).'
            $statusText.Foreground = '#a00'
            $offsetText.Focus() | Out-Null
            return
        }
        $resultBox.Value = @{
            Drive  = [string]$driveObj.Drive
            Offset = [int]$offsetRaw
        }
        # Phase 6.4.4: log the registration outcome with the actual
        # Windows-reported drive name so a later support diagnostic
        # can confirm exactly which physical drive was registered.
        Write-RipperLog INFO 'Show-RegisterDriveDialog' "Drive registration confirmed by user: drive=$([string]$driveObj.Drive), name='$([string]$driveObj.Name)', offset=$([int]$offsetRaw)."
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $cancelBtn.Add_Click({
        $resultBox.Value = $null
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    $window.Add_Closed({ try { $timer.Stop() } catch {} }.GetNewClosure())

    [void]$window.ShowDialog()
    return $resultBox.Value
}
