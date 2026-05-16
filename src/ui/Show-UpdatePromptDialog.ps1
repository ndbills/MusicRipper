<#
.SYNOPSIS
    v0.2.0: Lightweight WPF prompt shown by Start-Ripper at launch
    when a newer GitHub Release is available. Pure UX: the actual
    update mechanics live in the standalone Update-MusicRipper.ps1
    updater (this dialog launches that script + signals
    Start-Ripper to exit cleanly).

.DESCRIPTION
    Why a SEPARATE dialog from Show-UpdateDialog.ps1 (the standalone
    Update shortcut's dialog):

      Show-UpdateDialog.ps1     = full "I clicked Update on purpose"
                                  flow. Does its own GitHub check,
                                  shows Checking/Result/Applying
                                  states, runs the apply pipeline
                                  in-process (works because it lives
                                  in %TEMP% via the self-mutation
                                  bootstrap, so the install dir is
                                  free to be replaced).

      Show-UpdatePromptDialog   = "We noticed a newer version while
                                  you were just trying to rip a CD."
                                  Pure prompt UI. The check already
                                  happened (headless) in Start-Ripper
                                  before we got here. There's no
                                  "Applying" state because applying
                                  in-process from the install dir
                                  would collide with Start-Ripper's
                                  ~30 open script handles (every
                                  dot-source). Instead, Update Now
                                  hands off to Update-MusicRipper.ps1
                                  (which DOES bootstrap itself into
                                  %TEMP% first) and Start-Ripper
                                  exits cleanly.

    Layout: title + status line, scrollable release-notes panel,
    three buttons (View on GitHub | Update now | Not now). Modelled
    on Show-UpdateDialog's available-state row.

.PARAMETER ReleaseInfo
    Hashtable returned by Get-RipperLatestRelease. Required fields:
    Version, Notes, HtmlUrl. Source must be 'Release' (caller
    filters out the MainBranch fallback before invoking us; we
    don't want to prompt to "update" to a moving main-branch zip
    unprompted on every launch).

.PARAMETER LocalVersion
    Currently-installed version string (Get-RipperVersion). Shown
    in the status line so the parent can see what's getting
    replaced.

.PARAMETER Owner
    Optional WPF Window owner. We won't usually have one at startup
    (Start-Ripper has no host window yet), so this is just future-
    proofing for callers that DO want to chain dialogs.

.OUTPUTS
    [string] one of:
      'Update' = user clicked Update now. Caller should launch
                 Update-MusicRipper.ps1 and exit.
      'Skip'   = user clicked Not now / closed the window. Caller
                 should continue normal startup.

.NOTES
    No network calls from this file. The check has already happened.
    No file mutations either. Pure UI.

    Add-Type calls MUST be at the very top so the function-level
    [System.Windows.Window] type on $Owner parses on a fresh host.
    See Show-UpdateDialog.ps1 for the war story.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Load WPF assemblies BEFORE any function-level param block in this
# file references [System.Windows.Window]. See Show-UpdateDialog.ps1
# (the parse-time-WPF-type war story). Add-Type is idempotent.
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# Common.psm1 provides Set-RipperWindowIcon; tolerate absence in
# pathological test scenarios.
$commonPath = Join-Path $PSScriptRoot '..\lib\Common.psd1'
if (Test-Path -LiteralPath $commonPath) {
    Import-Module $commonPath -Force
}

function Show-RipperUpdatePromptDialog {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable]$ReleaseInfo,
        [Parameter(Mandatory)] [string]$LocalVersion,
        [System.Windows.Window]$Owner
    )

    # ---- XAML --------------------------------------------------------
    # Three rows: title + status (auto), release notes (fills), buttons
    # (auto). Window size matches the standalone Update dialog so the
    # two feel like siblings; this one is just shorter content-wise.
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MusicRipper - update available"
        Width="520" Height="380"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        SizeToContent="Manual"
        Background="#FAFAFA">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0">
      <TextBlock x:Name="TitleText"  FontSize="16" FontWeight="Bold" Margin="0,0,0,6"/>
      <TextBlock x:Name="StatusText" TextWrapping="Wrap" Foreground="#444" Margin="0,0,0,8"/>
    </StackPanel>

    <Border Grid.Row="1" BorderBrush="#DDD" BorderThickness="1" Padding="6" Margin="0,4,0,0">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBox x:Name="NotesText" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                 TextWrapping="Wrap" FontFamily="Segoe UI" FontSize="12"/>
      </ScrollViewer>
    </Border>

    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="ViewBtn"   Content="View on GitHub" Padding="14,6" Margin="0,0,8,0" Visibility="Collapsed"/>
      <Button x:Name="UpdateBtn" Content="Update now"    Padding="14,6" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="SkipBtn"   Content="Not now"       Padding="14,6" MinWidth="80" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { try { $window.Owner = $Owner } catch { } }
    try { Set-RipperWindowIcon $window } catch { }

    # Foreground-steal at Loaded. Start-Ripper minimises the host
    # console; without this Topmost dance the WPF can appear behind
    # the user's actual work. Same idiom every dialog uses.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.WindowState = 'Normal'
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    # Dispatcher unhandled-exception sink (Phase-4/5.2 rule applies
    # to every WPF window in the project). Log to the same place the
    # standalone updater logs.
    $logDir = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $dispatcherLog = Join-Path $logDir 'update-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $msg = "[$([DateTime]::Now.ToString('o'))] $($e.Exception.GetType().FullName): $($e.Exception.Message)`n$($e.Exception.StackTrace)`n"
            Add-Content -LiteralPath $dispatcherLog -Value $msg
        } catch { }
        $e.Handled = $true
    })

    # ---- Bind named controls ----------------------------------------
    $titleText  = $window.FindName('TitleText')
    $statusText = $window.FindName('StatusText')
    $notesText  = $window.FindName('NotesText')
    $viewBtn    = $window.FindName('ViewBtn')
    $updateBtn  = $window.FindName('UpdateBtn')
    $skipBtn    = $window.FindName('SkipBtn')

    # ---- Seed UI from $ReleaseInfo ----------------------------------
    $titleText.Text  = "Update available: v$($ReleaseInfo.Version)"
    $statusText.Text = "You're on v$LocalVersion. A newer release is on GitHub. Update now, or skip and rip your CD first -- you can always run the 'MusicRipper - Update' shortcut later."

    # NB: $ReleaseInfo is a [hashtable] from Get-RipperLatestRelease,
    # so $ReleaseInfo.PSObject.Properties['Foo'] does NOT see
    # hashtable keys (it surfaces the .NET dictionary internals like
    # Keys / Count). Use ContainsKey() for presence and dot-notation
    # for the value -- the PowerShell adapter routes both to the
    # underlying dictionary correctly. v0.2.1 fix.
    $notesBody = if ($ReleaseInfo.ContainsKey('Notes') -and $ReleaseInfo.Notes) {
        ([string]$ReleaseInfo.Notes).Trim()
    } else {
        '(No release notes provided.)'
    }
    $notesText.Text = $notesBody

    $hasUrl = $ReleaseInfo.ContainsKey('HtmlUrl') -and $ReleaseInfo.HtmlUrl
    if ($hasUrl) {
        $viewBtn.Visibility = 'Visible'
    }

    # ---- Result capture box (the established WPF closure idiom; see
    # /memories/powershell.md "WPF Add_Click closures and $script:
    # scope"). Default 'Skip' so the cancel/close paths all do the
    # right thing without explicit handlers.
    $resultBox = @{ Value = 'Skip' }

    # ---- Button handlers --------------------------------------------
    $updateBtn.Add_Click({
        $resultBox.Value = 'Update'
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $skipBtn.Add_Click({
        $resultBox.Value = 'Skip'
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    $viewBtn.Add_Click({
        # Open the release page in the user's default browser. Using
        # ProcessStartInfo + UseShellExecute is more reliable from a
        # WPF event than Start-Process for raw URLs. Same approach as
        # Show-UpdateDialog.ps1's ViewBtn.
        try {
            $url = [string]$ReleaseInfo.HtmlUrl
            if ($url) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName        = $url
                $psi.UseShellExecute = $true
                [System.Diagnostics.Process]::Start($psi) | Out-Null
            }
        } catch {
            # Swallow; the prompt is best-effort. The dispatcher
            # exception sink would already have caught a real crash.
        }
    }.GetNewClosure())

    [void]$window.ShowDialog()
    return $resultBox.Value
}
