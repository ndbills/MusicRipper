<#
.SYNOPSIS
    Phase 5.11: WPF dialog shown when a rip's post-process detects that
    the destination album folder already exists in the library
    (Move-RipToLibrary throws with Exception.Data['TargetExists']).

.DESCRIPTION
    Pipeline position:
        Called from Start-Ripper.ps1's Invoke-RipperOneDiscCycle, in the
        catch block around Invoke-RipperPostProcess, when the underlying
        IOException is the "target already exists" case (the rip itself
        is on disk in _inbox\, untagged, untouched).

    Four actions:
        - SideBySide  -> Re-run post-process with -AllowSideBySide so
                         the new copy lands as `<Album> (<Year>) [rip 2]`.
        - Review      -> Re-run post-process with -ForceReviewQueue so
                         the new copy lands in _ReviewQueue\USER-REVIEW
                         for manual triage. (Same path as the metadata
                         dialog's "Send to Review" button.)
        - Discard     -> Move the orphaned _inbox\ folder + sidecar to
                         the system Recycle Bin (recoverable, not a
                         hard delete).
        - Leave       -> Default. Do nothing -- the orphan stays in
                         _inbox\ and the next launch (or next disc in
                         continuous mode) will offer the standard
                         orphan-resume prompt.

    Closing via the title-bar X or pressing Esc is treated as Leave.

    Returns a [pscustomobject] with:
        Action  'SideBySide' | 'Review' | 'Discard' | 'Leave'

.NOTES
    Per Phase-4 / 5.2 lesson: a Dispatcher.add_UnhandledException sink is
    installed immediately after XamlReader.Load and writes to a sidecar
    log under %LOCALAPPDATA%\MusicRipper\logs\target-exists-dispatcher.log.
#>

function Show-RipperTargetExistsDialog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Friendly label of the new (just-finished) rip ("Artist - Album").
        [Parameter(Mandatory)] [string]$AlbumLabel,

        # Absolute path to the existing album folder in the library that
        # blocked the move.
        [Parameter(Mandatory)] [string]$ExistingPath,

        # Absolute path to the just-finished rip in _inbox\ that's now
        # stranded.
        [Parameter(Mandatory)] [string]$StrandedRipPath,

        # Optional Window owner so the dialog centers over its parent.
        $Owner = $null
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null

    $labelEsc    = [System.Security.SecurityElement]::Escape($AlbumLabel)
    $existingEsc = [System.Security.SecurityElement]::Escape($ExistingPath)
    $strandedEsc = [System.Security.SecurityElement]::Escape($StrandedRipPath)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MusicRipper - Album Already in Library"
        Width="720" Height="520"
        MinWidth="640" MinHeight="460"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        SizeToContent="Manual">
  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0"
               Text="The new rip finished, but an album already exists at the target."
               FontSize="15" FontWeight="Bold" TextWrapping="Wrap" Margin="0,0,0,12"/>

    <Border Grid.Row="1" BorderBrush="#ccc" BorderThickness="1"
            Padding="12" Background="#fafafa" CornerRadius="3" Margin="0,0,0,8">
      <StackPanel>
        <TextBlock Text="$labelEsc"
                   FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap"/>
        <TextBlock FontSize="11" Foreground="#666" Margin="0,8,0,0">
          Existing library folder
          <Run Foreground="#888">(click to open in Explorer):</Run>
        </TextBlock>
        <TextBlock FontFamily="Consolas" FontSize="11" TextWrapping="Wrap">
          <Hyperlink x:Name="ExistingPathLink" Foreground="#0645AD">$existingEsc</Hyperlink>
        </TextBlock>
        <TextBlock Text="New (stranded) rip:"
                   FontSize="11" Foreground="#666" Margin="0,8,0,0"/>
        <TextBlock Text="$strandedEsc"
                   FontFamily="Consolas" FontSize="11"
                   Foreground="#222" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <TextBlock Grid.Row="2"
               Text="What would you like to do with the new rip?"
               Margin="0,12,0,8" FontSize="13" FontWeight="SemiBold"/>

    <TextBlock Grid.Row="3" TextWrapping="Wrap" FontSize="12" Foreground="#444"
               Margin="0,0,0,12" LineHeight="20">
      <Run FontWeight="Bold">Keep both</Run> -- save side-by-side as "Album (Year) [rip 2]".<LineBreak/>
      <Run FontWeight="Bold">Send to Review</Run> -- drop in _ReviewQueue\ for triage in Picard.<LineBreak/>
      <Run FontWeight="Bold">Discard new rip</Run> -- move to the Recycle Bin (recoverable).<LineBreak/>
      <Run FontWeight="Bold">Leave for now</Run> -- keep in _inbox\; resume offered next time.
    </TextBlock>

    <TextBlock Grid.Row="5"
               Text="(Closing this window or pressing Esc leaves the rip in _inbox\.)"
               Foreground="#888" FontStyle="Italic" FontSize="11"
               Margin="0,0,0,12"/>

    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="DiscardButton"
              Content="Discard new rip"
              Width="130" Height="34" Margin="0,0,10,0"
              ToolTip="Move the new rip to the Recycle Bin (you can restore it from there if you change your mind)."/>
      <Button x:Name="ReviewButton"
              Content="Send to Review"
              Width="130" Height="34" Margin="0,0,10,0"
              ToolTip="Route the new rip to _ReviewQueue\ for manual triage."/>
      <Button x:Name="LeaveButton"
              Content="Leave for now"
              Width="120" Height="34" Margin="0,0,10,0"
              IsCancel="True"
              ToolTip="Keep the new rip in _inbox\. MusicRipper will offer to finish it next time."/>
      <Button x:Name="SideBySideButton"
              Content="Keep both"
              Width="120" Height="34"
              IsDefault="True"
              Background="#0a7" Foreground="White" FontWeight="Bold"
              ToolTip="Keep both copies side-by-side. The new one lands as 'Album (Year) [rip 2]'."/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $window.Owner = $Owner }

    # Phase 5.11: see Show-DuplicateDiscDialog -- steal foreground from
    # whatever was last in focus, since the host pwsh window is minimized.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    # Dispatcher sink (Phase-4 / 5.2 rule).
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\target-exists-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            if ($ex.InnerException) {
                $msg += "`n-- inner: $($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)"
            }
            Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            try { Write-RipperLog ERROR 'Show-RipperTargetExistsDialog' "Dispatcher exception: $($ex.GetType().FullName): $($ex.Message) (sidecar: $sidecar)" } catch {}
        } catch {}
        $e.Handled = $true
    })

    $state = [hashtable]::Synchronized(@{ Action = 'Leave' })

    $sideBySide   = $window.FindName('SideBySideButton')
    $review       = $window.FindName('ReviewButton')
    $discard      = $window.FindName('DiscardButton')
    $leave        = $window.FindName('LeaveButton')
    $existingLink = $window.FindName('ExistingPathLink')

    $sideBySide.Add_Click({
        $state.Action = 'SideBySide'
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $review.Add_Click({
        $state.Action = 'Review'
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $discard.Add_Click({
        $state.Action = 'Discard'
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $leave.Add_Click({
        $state.Action = 'Leave'
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    # Hyperlink on the existing library path -- opens File Explorer in
    # place of a dedicated "Open existing..." button. Dialog stays open
    # so the user can decide after looking at the existing rip.
    # Best-effort -- if Invoke-Item fails (folder gone, locked share,
    # etc.) we just log and move on.
    $existingLink.Tag = $ExistingPath
    $existingLink.Add_Click({
        $p = $this.Tag
        try {
            if (Test-Path -LiteralPath $p) {
                Invoke-Item -LiteralPath $p
            } else {
                try { Write-RipperLog WARN 'Show-RipperTargetExistsDialog' "Open existing: path no longer exists: $p" } catch {}
            }
        } catch {
            try { Write-RipperLog WARN 'Show-RipperTargetExistsDialog' "Open existing failed: $($_.Exception.Message)" } catch {}
        }
    }.GetNewClosure())

    [void]$window.ShowDialog()

    [pscustomobject]@{ Action = $state.Action }
}

function Move-RipperFolderToRecycleBin {
<#
.SYNOPSIS
    Send a folder to the Windows Recycle Bin (recoverable). Used by the
    "Discard new rip" button on Show-RipperTargetExistsDialog.

.DESCRIPTION
    Wraps Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory with
    RecycleOption.SendToRecycleBin. Adds VisualBasic to the AppDomain
    once and reuses thereafter.

    Throws if the path doesn't exist or the recycle operation fails.
    Caller is expected to log + surface a warning dialog on failure.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Move-RipperFolderToRecycleBin: not a directory: $Path"
    }
    Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
    if ($PSCmdlet.ShouldProcess($Path, 'Send to Recycle Bin')) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
}
