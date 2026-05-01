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
        $sel = $driveCombo.SelectedItem
        if (-not $sel) { return }
        $driveObj = $sel.Tag
        $shared.Phase     = 'running'
        $shared.Result    = $null
        $shared.Error     = $null
        $shared.DriveName = $driveObj.Name

        $statusText.Text       = "Querying AccurateRip for '$($driveObj.Name)'..."
        $statusText.Foreground = '#666'
        $progBar.Visibility    = 'Visible'
        $progBar.IsIndeterminate = $true
        $lookupBtn.IsEnabled   = $false
        $driveCombo.IsEnabled  = $false
        $okBtn.IsEnabled       = $false

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('shared',         $shared)
        $rs.SessionStateProxy.SetVariable('repoRoot',       $RepoRoot)
        $rs.SessionStateProxy.SetVariable('driveName',      $driveObj.Name)
        $rs.SessionStateProxy.SetVariable('cachedListPath', $cachedListPath)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Set-StrictMode -Version 3.0
            $ErrorActionPreference = 'Stop'
            try {
                Import-Module (Join-Path $repoRoot 'src\lib\DriveRegistration.psd1') -Force
                $offset = Find-RipperAccurateRipOffset -DriveName $driveName `
                                                       -CachedListPath $cachedListPath
                $shared.Result = $offset
                $shared.Phase  = 'done'
            } catch {
                $shared.Error = $_.Exception.Message
                $shared.Phase = 'error'
            }
        })
        [void]$ps.BeginInvoke()
    }.GetNewClosure()

    $lookupBtn.Add_Click({ & $startLookup }.GetNewClosure())

    # ---- Tick: poll $shared and update UI -----------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if ($shared.Phase -eq 'done') {
            $progBar.IsIndeterminate = $false
            $progBar.Visibility      = 'Collapsed'
            $lookupBtn.IsEnabled     = $true
            $driveCombo.IsEnabled    = $true
            $okBtn.IsEnabled         = $true
            if ($null -ne $shared.Result) {
                $offsetText.Text       = [string]$shared.Result
                $statusText.Text       = "Found offset $($shared.Result) for '$($shared.DriveName)'."
                $statusText.Foreground = '#070'
            } else {
                $statusText.Text       = "No AccurateRip offset found for '$($shared.DriveName)'. Enter the value manually if you know it, or leave 0 (rips will still work but AR verification will be unreliable)."
                $statusText.Foreground = '#a60'
                if (-not $offsetText.Text) { $offsetText.Text = '0' }
            }
            $shared.Phase = 'idle'
        }
        elseif ($shared.Phase -eq 'error') {
            $progBar.IsIndeterminate = $false
            $progBar.Visibility      = 'Collapsed'
            $lookupBtn.IsEnabled     = $true
            $driveCombo.IsEnabled    = $true
            $okBtn.IsEnabled         = $true
            $statusText.Text         = "Lookup failed: $($shared.Error)"
            $statusText.Foreground   = '#a00'
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
