<#
.SYNOPSIS
    Phase 8 (D-032): WPF dialog that drives the self-update flow.

.DESCRIPTION
    Three logical states, all rendered in the same compact window
    so the parent never has to chase a moving dialog:

      1. Checking      -- "Checking GitHub for updates..." indeterminate
                          progress bar. Worker runspace queries the
                          GitHub Releases API.
      2. Result        -- Either "You're up to date." (single OK
                          button), "Update available: <version>"
                          (Update button + Cancel), or
                          "Couldn't check (no internet?)" (Retry +
                          Cancel).
      3. Applying      -- Indeterminate progress + a status text line
                          that updates per phase ("Downloading...",
                          "Extracting...", "Installing new files...",
                          "Re-running setup chain..."). Buttons
                          disabled. On completion: status text becomes
                          "Update complete" or "Update failed" and
                          OK becomes the only enabled button.

    Cross-runspace state via the established Synchronized hashtable
    pattern (see Show-PendingSyncProgress for the original). Worker
    runspace re-imports modules + re-dot-sources every dep INSIDE
    AddScript -- per the cross-runspace logging gotcha (Phase 7
    follow-on), $script: state in the parent is invisible to workers.

.PARAMETER Owner
    Optional WPF Window owner. Centred on owner if supplied.

.PARAMETER InstallRoot
    Live MusicRipper install path. Required because the dialog runs
    from %TEMP% during the apply step (the source tree is being
    replaced underneath us) and needs to know where the live install
    lives.

.OUTPUTS
    [bool] $true if an update was applied successfully, $false on any
    other outcome (up-to-date, cancelled, network error, apply
    failure). The shortcut entry point doesn't act on the return value
    -- the dialog is its own self-contained UI -- but the value is
    still useful for unit-style integration tests.

.NOTES
    This file is dot-sourced from Update-MusicRipper.ps1 -- it is NOT
    a standalone script. The reason there's no script-level `param(...)`
    block: the [System.Windows.Window]$Owner parameter on
    Show-RipperUpdateDialog is parsed at file-load time, and PowerShell's
    type resolution for `[System.Windows.Window]` requires
    PresentationFramework to be ALREADY loaded into the AppDomain. So
    the `Add-Type -AssemblyName PresentationFramework` call below MUST
    happen before any param block referencing WPF types. A previous
    version of this file had a script-level param block above the
    Add-Type calls, which crashed on first launch on fresh test
    machines (where the dev shell hadn't already pre-loaded WPF for
    other reasons). Keep the Add-Type calls at the very top.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Load WPF assemblies BEFORE any function-level param block in this
# file references [System.Windows.Window]. These four are the same set
# every WPF dialog in the project loads (Show-RipperConfigDialog.ps1,
# Show-PendingSyncProgress.ps1, etc.); Add-Type is idempotent so
# loading them again here when the host has already imported them is
# a fast no-op.
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# Load deps. The dialog can be sourced standalone (from
# Update-MusicRipper.ps1) so we import everything we need here rather
# than relying on a parent script's chain.
$libRoot = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libRoot 'Logging.psd1') -Force
Import-Module (Join-Path $libRoot 'Common.psd1')  -Force
Import-Module (Join-Path $libRoot 'Updater.psd1') -Force

function Show-RipperUpdateDialog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$InstallRoot,
        [System.Windows.Window]$Owner
    )

    # ---- XAML --------------------------------------------------------
    # Three rows: title + status (1), release notes (2; collapses when
    # not in 'available' state), buttons (3). The release-notes panel
    # uses a TextBox so the parent can scroll if a release has long
    # notes; we lock it read-only so they can't accidentally edit.
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MusicRipper - Update"
        Width="520" Height="360"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        SizeToContent="Manual"
        Background="#FAFAFA">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Row 0: title + status text + indeterminate progress -->
    <StackPanel Grid.Row="0">
      <TextBlock x:Name="TitleText" FontSize="16" FontWeight="Bold" Margin="0,0,0,6"/>
      <TextBlock x:Name="StatusText" TextWrapping="Wrap" Foreground="#444" Margin="0,0,0,8"/>
      <ProgressBar x:Name="ProgressBar" Height="6" IsIndeterminate="True" Margin="0,0,0,8"/>
    </StackPanel>

    <!-- Row 1: release notes (visible only in 'available' state) -->
    <Border x:Name="NotesBorder" Grid.Row="1" BorderBrush="#DDD" BorderThickness="1" Padding="6" Margin="0,4,0,0" Visibility="Collapsed">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBox x:Name="NotesText" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                 TextWrapping="Wrap" FontFamily="Segoe UI" FontSize="12"/>
      </ScrollViewer>
    </Border>

    <!-- Row 2: action buttons -->
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="ViewBtn"    Content="View on GitHub" Padding="14,6" Margin="0,0,8,0" Visibility="Collapsed"/>
      <Button x:Name="UpdateButton" Content="Update now" Padding="14,6" Margin="0,0,8,0" Visibility="Collapsed" IsDefault="True"/>
      <Button x:Name="RetryButton"  Content="Retry"      Padding="14,6" Margin="0,0,8,0" Visibility="Collapsed"/>
      <Button x:Name="CancelButton" Content="Cancel"     Padding="14,6" Margin="0,0,8,0" IsCancel="True"/>
      <Button x:Name="OkButton"     Content="OK"         Padding="14,6" MinWidth="80" Visibility="Collapsed"/>
    </StackPanel>
  </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { try { $window.Owner = $Owner } catch { } }
    Set-RipperWindowIcon $window

    # Foreground steal -- launched from a Minimized .lnk so the host
    # pwsh starts hidden; without this the WPF appears behind other
    # windows. Same idiom as Show-PendingSyncProgress.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.WindowState = 'Normal'
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    # Dispatcher unhandled-exception sink (Phase-4/5.2 rule applies to
    # every WPF window in the project).
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
    $titleText    = $window.FindName('TitleText')
    $statusText   = $window.FindName('StatusText')
    $progressBar  = $window.FindName('ProgressBar')
    $notesBorder  = $window.FindName('NotesBorder')
    $notesText    = $window.FindName('NotesText')
    $viewBtn      = $window.FindName('ViewBtn')
    $updateBtn    = $window.FindName('UpdateButton')
    $retryBtn     = $window.FindName('RetryButton')
    $cancelBtn    = $window.FindName('CancelButton')
    $okBtn        = $window.FindName('OkButton')

    # ---- Cross-runspace state ---------------------------------------
    # Phase = 'check' | 'check-done' | 'apply' | 'apply-done'
    # CheckResult / ApplyResult populated by the worker; UI ticks
    # transition us between states.
    $shared = [hashtable]::Synchronized(@{
        Phase           = 'idle'
        CheckResult     = $null   # @{ Latest=...; Comparison=...; Local=... } or $null on network error
        CheckError      = $null
        ApplyDetail     = ''      # status text the worker pushes during apply
        ApplyResult     = $null   # hashtable from Invoke-RipperUpdateApply
        ApplyError      = $null
        Cancelled       = $false  # flipped by the cancel button mid-check
    })

    # Capture the result the orchestrator returns (true iff an apply
    # succeeded). Local capture box is the established WPF closure idiom
    # (see /memories/powershell.md "WPF Add_Click closures and $script:
    # scope").
    $resultBox = @{ Value = $false }

    # ---- State transitions ------------------------------------------
    # Helpers that rebuild the UI for each state. Closure-captured
    # references to all controls + $shared.

    $repoRootPath = $InstallRoot   # alias for closures below

    $setCheckingState = {
        $titleText.Text   = 'Checking for updates...'
        $statusText.Text  = 'Contacting GitHub.'
        $progressBar.Visibility    = 'Visible'
        $progressBar.IsIndeterminate = $true
        $notesBorder.Visibility    = 'Collapsed'
        $viewBtn.Visibility        = 'Collapsed'
        $updateBtn.Visibility      = 'Collapsed'
        $retryBtn.Visibility       = 'Collapsed'
        $okBtn.Visibility          = 'Collapsed'
        $cancelBtn.Visibility      = 'Visible'
        $cancelBtn.IsEnabled       = $true
    }.GetNewClosure()

    $setUpToDateState = {
        param($localVer)
        $titleText.Text  = "You're up to date."
        $statusText.Text = "Installed version: $localVer. No newer release available on GitHub right now."
        $progressBar.Visibility = 'Collapsed'
        $notesBorder.Visibility = 'Collapsed'
        $viewBtn.Visibility     = 'Collapsed'
        $updateBtn.Visibility   = 'Collapsed'
        $retryBtn.Visibility    = 'Collapsed'
        $cancelBtn.Visibility   = 'Collapsed'
        $okBtn.Visibility       = 'Visible'
        $okBtn.IsDefault        = $true
        $okBtn.Focus() | Out-Null
    }.GetNewClosure()

    $setUpdateAvailableState = {
        param($latest, $localVer)
        $titleText.Text   = "Update available: $($latest.Version)"
        $statusText.Text  = "Installed version: $localVer. Click 'Update now' to download and apply."
        $progressBar.Visibility = 'Collapsed'
        $notesBorder.Visibility = 'Visible'
        $notes = if ($latest.Notes) { $latest.Notes.Trim() } else { '(No release notes provided.)' }
        $notesText.Text   = $notes
        # Show 'View on GitHub' only when the API gave us a release
        # page URL. The MainBranch fallback (no Releases yet) returns
        # HtmlUrl='' and gets no button -- there is no release page
        # for a bare-branch zip.
        $hasUrl = $latest.PSObject.Properties['HtmlUrl'] -and $latest.HtmlUrl
        if ($hasUrl) {
            $viewBtn.Visibility = 'Visible'
            $viewBtn.IsEnabled  = $true
        } else {
            $viewBtn.Visibility = 'Collapsed'
        }
        $updateBtn.Visibility   = 'Visible'
        $updateBtn.IsEnabled    = $true
        $retryBtn.Visibility    = 'Collapsed'
        $cancelBtn.Visibility   = 'Visible'
        $cancelBtn.IsEnabled    = $true
        $okBtn.Visibility       = 'Collapsed'
        $updateBtn.Focus() | Out-Null
    }.GetNewClosure()

    $setCheckErrorState = {
        param($errMsg)
        $titleText.Text   = "Couldn't check for updates"
        $statusText.Text  = "GitHub couldn't be reached. Check your internet connection and try again.`n`n($errMsg)"
        $progressBar.Visibility = 'Collapsed'
        $notesBorder.Visibility = 'Collapsed'
        $viewBtn.Visibility     = 'Collapsed'
        $updateBtn.Visibility   = 'Collapsed'
        $retryBtn.Visibility    = 'Visible'
        $retryBtn.IsEnabled     = $true
        $cancelBtn.Visibility   = 'Visible'
        $cancelBtn.IsEnabled    = $true
        $okBtn.Visibility       = 'Collapsed'
        $retryBtn.Focus() | Out-Null
    }.GetNewClosure()

    $setApplyingState = {
        $titleText.Text  = 'Updating MusicRipper...'
        $statusText.Text = 'Starting update.'
        $progressBar.Visibility    = 'Visible'
        $progressBar.IsIndeterminate = $true
        $notesBorder.Visibility = 'Collapsed'
        $viewBtn.Visibility   = 'Collapsed'
        $updateBtn.Visibility = 'Collapsed'
        $retryBtn.Visibility  = 'Collapsed'
        $cancelBtn.IsEnabled  = $false   # don't allow mid-apply cancel
        $okBtn.Visibility     = 'Collapsed'
    }.GetNewClosure()

    $setApplyDoneState = {
        param($success, $detailMsg)
        if ($success) {
            $titleText.Text  = 'Update complete!'
            $statusText.Text = "MusicRipper has been updated. The new version will run the next time you launch it from the desktop shortcut."
        } else {
            $titleText.Text  = 'Update failed'
            $statusText.Text = $detailMsg
        }
        $progressBar.Visibility = 'Collapsed'
        $notesBorder.Visibility = 'Collapsed'
        $viewBtn.Visibility     = 'Collapsed'
        $updateBtn.Visibility   = 'Collapsed'
        $retryBtn.Visibility    = 'Collapsed'
        $cancelBtn.Visibility   = 'Collapsed'
        $okBtn.Visibility       = 'Visible'
        $okBtn.IsDefault        = $true
        $okBtn.Focus() | Out-Null
    }.GetNewClosure()

    # ---- Worker runspaces ------------------------------------------
    # Two distinct workers: one for the check, one for the apply.
    # Both follow the established cross-runspace pattern (Synchronized
    # hashtable + DispatcherTimer poll).

    $startCheck = {
        & $setCheckingState
        $shared.Phase       = 'check'
        $shared.CheckResult = $null
        $shared.CheckError  = $null

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('shared',   $shared)
        $rs.SessionStateProxy.SetVariable('libRoot',  $libRoot)
        $rs.SessionStateProxy.SetVariable('logPath',  (Get-RipperLogPath))
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Set-StrictMode -Version 3.0
            $ErrorActionPreference = 'Stop'
            try {
                Import-Module (Join-Path $libRoot 'Logging.psd1')
                Import-Module (Join-Path $libRoot 'Common.psd1')
                Import-Module (Join-Path $libRoot 'Updater.psd1')
                if ($logPath) { Set-RipperLogPath -Path $logPath }

                $latest    = Get-RipperLatestRelease
                $localVer  = Get-RipperVersion
                if (-not $latest) {
                    # Per Get-RipperLatestRelease docstring: it always
                    # returns SOMETHING (Release or MainBranch
                    # fallback). $null indicates a real network error.
                    $shared.CheckError = 'GitHub could not be reached.'
                    $shared.Phase = 'check-done'
                    return
                }
                $cmp = Compare-RipperVersion -Local $localVer -Remote $latest.Version
                $shared.CheckResult = @{
                    Latest     = $latest
                    Comparison = $cmp
                    Local      = $localVer
                }
                $shared.Phase = 'check-done'
            } catch {
                $shared.CheckError = $_.Exception.Message
                $shared.Phase      = 'check-done'
            }
        })
        [void]$ps.BeginInvoke()
    }.GetNewClosure()

    $startApply = {
        & $setApplyingState
        $shared.Phase       = 'apply'
        $shared.ApplyDetail = 'Preparing.'
        $shared.ApplyResult = $null
        $shared.ApplyError  = $null

        $latest = $shared.CheckResult.Latest

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('shared',      $shared)
        $rs.SessionStateProxy.SetVariable('libRoot',     $libRoot)
        $rs.SessionStateProxy.SetVariable('logPath',     (Get-RipperLogPath))
        $rs.SessionStateProxy.SetVariable('installRoot', $repoRootPath)
        $rs.SessionStateProxy.SetVariable('zipUrl',      $latest.ZipballUrl)
        $rs.SessionStateProxy.SetVariable('newVersion',  $latest.Version)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Set-StrictMode -Version 3.0
            $ErrorActionPreference = 'Stop'
            try {
                Import-Module (Join-Path $libRoot 'Logging.psd1')
                Import-Module (Join-Path $libRoot 'Common.psd1')
                Import-Module (Join-Path $libRoot 'Updater.psd1')
                if ($logPath) { Set-RipperLogPath -Path $logPath }

                # Stage area in %TEMP% -- per design (don't touch the
                # install root with downloaded bytes until we know the
                # extraction succeeded).
                $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
                                       ('musicripper-update-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
                $zipPath = Join-Path $stageRoot 'source.zip'
                $extract = Join-Path $stageRoot 'extracted'
                New-Item -ItemType Directory -Path $extract -Force | Out-Null

                Write-RipperLog INFO 'Updater' "Apply: downloading $zipUrl -> $zipPath"
                $shared.ApplyDetail = 'Downloading new version.'
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath `
                                  -UseBasicParsing -ErrorAction Stop

                $shared.ApplyDetail = 'Extracting.'
                Write-RipperLog INFO 'Updater' "Apply: extracting -> $extract"
                Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

                $shared.ApplyDetail = 'Installing new files.'
                $progressCb = {
                    param($info)
                    $shared.ApplyDetail = "$($info.Phase): $($info.Detail)"
                }
                $applyResult = Invoke-RipperUpdateApply `
                                    -InstallRoot      $installRoot `
                                    -StagingRoot      $extract `
                                    -ProgressCallback $progressCb

                if (-not $applyResult.Success) {
                    $shared.ApplyError  = $applyResult.ErrorMessage
                    $shared.ApplyResult = $applyResult
                    $shared.Phase       = 'apply-done'
                    return
                }

                # Best-effort: re-run setup chain. Failures here don't
                # invalidate the update (the new files ARE in place);
                # we surface them as warnings but report apply success.
                $shared.ApplyDetail = 'Refreshing dependencies (one moment).'
                $depsScript = Join-Path $installRoot 'setup\Install-Dependencies.ps1'
                if (Test-Path -LiteralPath $depsScript) {
                    try {
                        & $depsScript | Out-Null
                    } catch {
                        Write-RipperLog WARN 'Updater' "Re-run of Install-Dependencies failed (update files in place; you may want to re-run it manually): $($_.Exception.Message)"
                    }
                }
                $shortcutScript = Join-Path $installRoot 'setup\Install-Shortcut.ps1'
                if (Test-Path -LiteralPath $shortcutScript) {
                    try {
                        & $shortcutScript | Out-Null
                    } catch {
                        Write-RipperLog WARN 'Updater' "Re-run of Install-Shortcut failed: $($_.Exception.Message)"
                    }
                }

                # Prune old backups (keep last 2).
                try {
                    Remove-RipperOldUpdateBackups -InstallRoot $installRoot -Keep 2
                } catch {
                    Write-RipperLog WARN 'Updater' "Backup pruning failed: $($_.Exception.Message)"
                }

                # Best-effort cleanup of staging area.
                try { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

                Write-RipperLog INFO 'Updater' "Apply complete: now at $newVersion (backup retained at '$($applyResult.BackupPath)')."
                $shared.ApplyResult = $applyResult
                $shared.Phase       = 'apply-done'
            } catch {
                $shared.ApplyError = $_.Exception.Message
                $shared.Phase      = 'apply-done'
            }
        })
        [void]$ps.BeginInvoke()
    }.GetNewClosure()

    # ---- Tick: poll $shared and drive UI -----------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        switch ($shared.Phase) {
            'check-done' {
                $shared.Phase = 'idle'
                if ($shared.CheckError) {
                    & $setCheckErrorState $shared.CheckError
                    return
                }
                $cmp = $shared.CheckResult.Comparison
                if ($cmp -eq 'UpToDate' -or $cmp -eq 'LocalAhead') {
                    & $setUpToDateState $shared.CheckResult.Local
                } else {
                    & $setUpdateAvailableState $shared.CheckResult.Latest $shared.CheckResult.Local
                }
            }
            'apply' {
                if ($shared.ApplyDetail) {
                    $statusText.Text = [string]$shared.ApplyDetail
                }
            }
            'apply-done' {
                $shared.Phase = 'idle'
                if ($shared.ApplyError) {
                    & $setApplyDoneState $false "Update failed: $($shared.ApplyError)"
                } elseif ($shared.ApplyResult -and -not $shared.ApplyResult.Success) {
                    & $setApplyDoneState $false $shared.ApplyResult.ErrorMessage
                } else {
                    & $setApplyDoneState $true ''
                    $resultBox.Value = $true
                }
            }
        }
    }.GetNewClosure())
    $timer.Start()

    # ---- Button handlers -------------------------------------------
    $updateBtn.Add_Click({ & $startApply }.GetNewClosure())
    $retryBtn.Add_Click(  { & $startCheck }.GetNewClosure())
    $viewBtn.Add_Click({
        # Open the release page in the user's default browser. The
        # shell-execute trick (UseShellExecute=$true, no FileName
        # validation needed) is the most reliable launcher for an
        # http(s) URL from a WPF event handler -- Start-Process
        # occasionally trips on PowerShell parameter binding when the
        # URL contains special chars. We only set $viewBtn.Visibility
        # in the available state when $latest.HtmlUrl is non-empty,
        # so $shared.CheckResult.Latest.HtmlUrl is guaranteed safe to
        # read here.
        try {
            $url = [string]$shared.CheckResult.Latest.HtmlUrl
            if ($url) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName        = $url
                $psi.UseShellExecute = $true
                [System.Diagnostics.Process]::Start($psi) | Out-Null
            }
        } catch {
            Write-RipperLog WARN 'Updater' "View on GitHub click failed to open '$url': $($_.Exception.Message)"
        }
    }.GetNewClosure())
    $cancelBtn.Add_Click({
        $shared.Cancelled = $true
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())
    $okBtn.Add_Click({
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $window.Add_Closed({ try { $timer.Stop() } catch { } }.GetNewClosure())

    # Kick off the initial check then show the dialog.
    & $startCheck
    [void]$window.ShowDialog()
    return $resultBox.Value
}
