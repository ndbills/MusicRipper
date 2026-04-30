<#
.SYNOPSIS
    Phase 7: friendly modal shown when MusicRipper hits an uncaught
    exception that escaped the per-disc safety net.

.DESCRIPTION
    Pipeline position:
        Last-resort handler for the entire Start-Ripper.ps1 script
        body. Per-disc errors are caught inside Invoke-RipperOneDiscCycle
        and surfaced via plain MessageBox (the rip loop continues).
        This dialog only fires when something escapes that catch
        (typically: a problem in startup wiring, the resync flow, or
        the between-discs / WireGuard cleanup blocks).

    The point is parent-friendly framing -- the parent should never
    have to read PowerShell stack traces. They get a calm message,
    a path they can copy with one click, and a Close button. The
    engineer-readable details are in the log file.

    UI elements:
      * Reassuring lead ("the disc was not damaged").
      * What-to-do-next sentence ("share the log with <you>").
      * Read-only multi-line text box with a one-line summary
        (Exception type + Message). Stack/inner details go to the
        log only.
      * Read-only path field showing the active log file.
      * "Copy log path" button that puts the path on the clipboard.
      * "Open log folder" button (best-effort Invoke-Item).
      * "Close" button (default + IsCancel + window-X all close).

    The dialog is best-effort: if WPF assembly load fails (e.g. a
    truly broken pwsh install), the caller's outer catch falls back
    to a Show-RipperInfo / Write-RipperLog combo so the user still
    sees something.

.PARAMETER Exception
    The [System.Exception] (or [System.Management.Automation.ErrorRecord]'s
    .Exception) that escaped. Required.

.PARAMETER LogPath
    Absolute path to the active log file. Optional; defaults to
    Get-RipperLogPath. May be $null / missing if logging never
    started.

.PARAMETER ContactName
    Optional name to drop into the "share the log with X" sentence.
    Defaults to "the maintainer".

.NOTES
    Per Phase-4 / 5.2 lesson: dispatcher unhandled-exception sink
    installed immediately after XamlReader.Load and writes to
    %LOCALAPPDATA%\MusicRipper\logs\fatal-error-dispatcher.log.
#>

Set-StrictMode -Version 3.0

function Show-RipperFatalErrorDialog {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Exception] $Exception,

        [string] $LogPath,

        [string] $ContactName = 'the maintainer'
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null
    Add-Type -AssemblyName WindowsBase           | Out-Null

    if (-not $LogPath) {
        try { $LogPath = Get-RipperLogPath } catch { $LogPath = '' }
    }
    $logPathDisplay = if ($LogPath) { $LogPath } else { '(no log file -- logging never started)' }

    $exType    = $Exception.GetType().FullName
    $exMessage = if ($Exception.Message) { $Exception.Message } else { '(no message)' }
    $summary   = "$exType`r`n$exMessage"

    $titleEsc   = [System.Security.SecurityElement]::Escape('MusicRipper - something went wrong')
    $contactEsc = [System.Security.SecurityElement]::Escape($ContactName)
    $summaryEsc = [System.Security.SecurityElement]::Escape($summary)
    $pathEsc    = [System.Security.SecurityElement]::Escape($logPathDisplay)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$titleEsc"
        Width="560" SizeToContent="Height"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" ShowInTaskbar="True">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0"
               Text="Something went wrong."
               FontSize="16" FontWeight="Bold" Margin="0,0,0,8"/>

    <TextBlock Grid.Row="1" TextWrapping="Wrap" Margin="0,0,0,12">
      <Run Text="Don't worry -- the disc in the drive was not damaged. Please share the log file below with "/>
      <Run Text="$contactEsc"/>
      <Run Text=" and they will take a look. You can close MusicRipper now."/>
    </TextBlock>

    <TextBlock Grid.Row="2" Text="What happened (technical detail):"
               FontWeight="SemiBold" Margin="0,0,0,4"/>
    <TextBox   Grid.Row="3" Name="DetailBox"
               Text="$summaryEsc"
               IsReadOnly="True" TextWrapping="Wrap"
               FontFamily="Consolas" FontSize="11"
               Background="#fafafa" BorderBrush="#ccc"
               Padding="6" MinHeight="64" MaxHeight="160"
               VerticalScrollBarVisibility="Auto"
               Margin="0,0,0,12"/>

    <TextBlock Grid.Row="4" Text="Log file:"
               FontWeight="SemiBold" Margin="0,0,0,4"/>
    <TextBox   Grid.Row="5" Name="PathBox"
               Text="$pathEsc"
               IsReadOnly="True" TextWrapping="NoWrap"
               FontFamily="Consolas" FontSize="11"
               Background="#fafafa" BorderBrush="#ccc"
               Padding="6"
               Margin="0,0,0,12"/>

    <TextBlock Grid.Row="6" Name="StatusText"
               Text="" Foreground="#0a7a0a" FontStyle="Italic"
               Margin="0,0,0,8" Height="18"/>

    <StackPanel Grid.Row="7" Orientation="Horizontal"
                HorizontalAlignment="Right">
      <Button Name="CopyBtn"  Content="Copy log path" Width="120" Margin="0,0,8,0"/>
      <Button Name="OpenBtn"  Content="Open log folder" Width="120" Margin="0,0,8,0"/>
      <Button Name="CloseBtn" Content="Close" Width="80"
              IsDefault="True" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Dispatcher unhandled-exception sink (Phase-4 lesson). If a binding
    # error fires here we write it to a sidecar so the *outer* fatal
    # handler isn't itself silently swallowed.
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\fatal-error-dispatcher.log'
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

    # Topmost-then-clear so the dialog steals focus past the minimised
    # host. Same idiom as Show-CredentialDialog / Show-PendingSyncProgress.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    $copyBtn   = $window.FindName('CopyBtn')
    $openBtn   = $window.FindName('OpenBtn')
    $closeBtn  = $window.FindName('CloseBtn')
    $pathBox   = $window.FindName('PathBox')
    $statusTxt = $window.FindName('StatusText')

    # Disable Copy / Open if no log file.
    if (-not $LogPath) {
        $copyBtn.IsEnabled = $false
        $openBtn.IsEnabled = $false
    }

    $copyBtn.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($pathBox.Text)
            $statusTxt.Text = 'Log path copied to clipboard.'
        } catch {
            $statusTxt.Foreground = 'Red'
            $statusTxt.Text = "Couldn't copy: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    $openBtn.Add_Click({
        try {
            $logFile = $pathBox.Text
            if ($logFile -and (Test-Path -LiteralPath $logFile -PathType Leaf)) {
                # explorer.exe /select,"<file>" opens the parent folder
                # with the file pre-selected (matches "Show in folder"
                # behaviour). Note: NO space between /select, and the
                # path -- explorer parses the comma as the separator
                # and would treat a leading space as part of the path.
                Start-Process -FilePath 'explorer.exe' `
                    -ArgumentList "/select,`"$logFile`"" | Out-Null
                $statusTxt.Text = "Opened folder with '$(Split-Path -Leaf $logFile)' selected."
            } else {
                # File is gone (logging never started, or the user
                # deleted it after the dialog opened). Best-effort
                # fall back to opening the parent folder un-selected.
                $folder = if ($logFile) { Split-Path -Parent $logFile } else { '' }
                if ($folder -and (Test-Path -LiteralPath $folder)) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`"" | Out-Null
                    $statusTxt.Foreground = '#a60'
                    $statusTxt.Text = "Log file is gone; opened the folder instead."
                } else {
                    $statusTxt.Foreground = 'Red'
                    $statusTxt.Text = "Log file and folder both missing: $logFile"
                }
            }
        } catch {
            $statusTxt.Foreground = 'Red'
            $statusTxt.Text = "Couldn't open folder: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    $closeBtn.Add_Click({
        $window.Close()
    }.GetNewClosure())

    [void]$window.ShowDialog()
}
