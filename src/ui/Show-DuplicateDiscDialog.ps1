<#
.SYNOPSIS
    Phase 5.8: WPF dialog shown when an inserted disc is found in the
    cross-session DiscId index (i.e. it was already ripped in some
    previous run).

.DESCRIPTION
    Pipeline position:
        Called from Start-Ripper.ps1's Invoke-RipperOneDiscCycle, right
        after the in-session "RippedDiscs" check and before metadata
        lookup. Trigger is `Find-RipperLibraryDiscIndexEntry` returning
        a non-null entry.

    Three actions:
        - Skip rip       -> default. Eject + return to between-discs.
        - Open folder    -> Invoke-Item the prior album path; the dialog
                            stays open so the parent can decide what to
                            do after looking at the existing rip.
        - Rip again      -> proceed with the rip; the new copy lands
                            side-by-side as `<Album> (<Year>) [rip 2]`
                            (then [rip 3], etc.) via Move-RipToLibrary's
                            -AllowSideBySide switch.

    Closing via the title-bar X is treated as Skip.

    Returns a [pscustomobject] with:
        Action   'Skip' | 'RipAgain'

.NOTES
    Per Phase-4 / 5.2 lesson: a Dispatcher.add_UnhandledException sink is
    installed immediately after XamlReader.Load and writes to a sidecar
    log under %LOCALAPPDATA%\MusicRipper\logs\duplicate-disc-dispatcher.log.
#>

function Show-RipperDuplicateDiscDialog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Friendly label of the prior rip ("Artist - Album (Year)").
        [Parameter(Mandatory)] [string]$AlbumLabel,

        # Absolute path to the prior rip folder.
        [Parameter(Mandatory)] [string]$AlbumPath,

        # When this disc was originally ripped (ISO-8601 string or
        # DateTime). Optional but adds context.
        [object]$RippedAt,

        # Optional Window owner so the dialog centers over its parent.
        $Owner = $null
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null

    $rippedAtText = ''
    if ($RippedAt) {
        try {
            $dt = if ($RippedAt -is [datetime]) { $RippedAt } else { [datetime]$RippedAt }
            $rippedAtText = "Originally ripped: " + $dt.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        } catch { $rippedAtText = "Originally ripped: $RippedAt" }
    }

    $labelEsc    = [System.Security.SecurityElement]::Escape($AlbumLabel)
    $pathEsc     = [System.Security.SecurityElement]::Escape($AlbumPath)
    $rippedAtEsc = [System.Security.SecurityElement]::Escape($rippedAtText)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MusicRipper - Disc Already in Library"
        Width="560" Height="340"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        SizeToContent="Manual">
  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0"
               Text="This disc is already in your library."
               FontSize="16" FontWeight="Bold" Margin="0,0,0,12"/>

    <Border Grid.Row="1" BorderBrush="#ccc" BorderThickness="1"
            Padding="12" Background="#fafafa" CornerRadius="3">
      <StackPanel>
        <TextBlock Text="$labelEsc"
                   FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap"/>
        <TextBlock Text="$pathEsc"
                   FontFamily="Consolas" FontSize="11"
                   Foreground="#555" TextWrapping="Wrap"
                   Margin="0,6,0,0"/>
        <TextBlock x:Name="RippedAtText"
                   Text="$rippedAtEsc"
                   FontSize="11" FontStyle="Italic" Foreground="#666"
                   Margin="0,6,0,0"/>
      </StackPanel>
    </Border>

    <TextBlock Grid.Row="2"
               Text="What would you like to do?"
               Margin="0,16,0,8" FontSize="13"/>

    <TextBlock Grid.Row="3"
               Text="(Closing this window or pressing Esc skips the rip.)"
               Foreground="#888" FontStyle="Italic" FontSize="11"
               Margin="0,0,0,12"/>

    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="OpenFolderButton"
              Content="Open folder..."
              Width="130" Height="34" Margin="0,0,10,0"
              ToolTip="Open the existing album folder in File Explorer so you can confirm it's there. The dialog stays open."/>
      <Button x:Name="SkipButton"
              Content="Skip rip"
              Width="120" Height="34" Margin="0,0,10,0"
              IsCancel="True"
              ToolTip="Don't rip this disc. Ejects the CD and returns to the disc-insert prompt. (Same as pressing Esc or closing the window.)"/>
      <Button x:Name="RipAgainButton"
              Content="Rip again (keep both)"
              Width="180" Height="34"
              IsDefault="True"
              Background="#0a7" Foreground="White" FontWeight="Bold"
              ToolTip="Rip this disc again as a side-by-side copy. The new rip lands in '<Album> [rip 2]' so it doesn't overwrite the existing one."/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $window.Owner = $Owner }

    if (-not $rippedAtText) {
        $window.FindName('RippedAtText').Visibility = 'Collapsed'
    }

    # Dispatcher sink (Phase-4 / 5.2 rule).
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\duplicate-disc-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            if ($ex.InnerException) {
                $msg += "`n-- inner: $($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)"
            }
            Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            try { Write-RipperLog ERROR 'Show-RipperDuplicateDiscDialog' "Dispatcher exception: $($ex.GetType().FullName): $($ex.Message) (sidecar: $sidecar)" } catch {}
        } catch {}
        $e.Handled = $true
    })

    $state = [hashtable]::Synchronized(@{ Action = 'Skip' })

    $skip       = $window.FindName('SkipButton')
    $openFolder = $window.FindName('OpenFolderButton')
    $ripAgain   = $window.FindName('RipAgainButton')

    $skip.Add_Click({
        $state.Action = 'Skip'
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    $ripAgain.Add_Click({
        $state.Action = 'RipAgain'
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    # Open folder stays open so the user can decide after looking at the
    # prior rip. Best-effort -- if Invoke-Item fails (folder gone since
    # the index check, locked share, etc.) we just log and move on.
    $openFolder.Tag = $AlbumPath
    $openFolder.Add_Click({
        $p = $this.Tag
        try {
            if (Test-Path -LiteralPath $p) {
                Invoke-Item -LiteralPath $p
            } else {
                try { Write-RipperLog WARN 'Show-RipperDuplicateDiscDialog' "Open folder: path no longer exists: $p" } catch {}
            }
        } catch {
            try { Write-RipperLog WARN 'Show-RipperDuplicateDiscDialog' "Open folder failed: $($_.Exception.Message)" } catch {}
        }
    }.GetNewClosure())

    [void]$window.ShowDialog()

    [pscustomobject]@{ Action = $state.Action }
}
