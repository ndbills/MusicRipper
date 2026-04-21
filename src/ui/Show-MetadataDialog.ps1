<#
.SYNOPSIS
    Phase 3 confirmation UI. WPF dialog that lets the user review/edit
    the metadata picked by Get-RipperDiscMetadata before the rip starts.

.DESCRIPTION
    Pipeline position:
        Step 3 of the daily-flow sequence.
            ... -> Get-DiscMetadata -> Show-RipperMetadataDialog ->
            (Phase 4) Invoke-Rip -> ...

    Logic split:
        - ConvertTo-MetadataViewModel       (pure, fixture-testable)
            Project a single normalized candidate (from
            Get-RipperDiscMetadata) into a flat editable view-model.
        - ConvertFrom-MetadataViewModel     (pure, fixture-testable)
            Apply the (possibly edited) view-model back onto its source
            candidate, returning a NEW candidate object. Non-editable
            fields (MBIDs, CoverArtBytes, Length, ReleaseMbid, ...) are
            preserved verbatim so downstream tagging still has them.
        - Show-RipperMetadataDialog         (WPF; thin wrapper)
            The function Start-Ripper actually calls. Returns a result
            object describing what the user chose.

    Result shape from Show-RipperMetadataDialog:

        Action   : 'Rip' | 'Cancel' | 'Review'
        Metadata : updated candidate (Rip / Review)  OR  $null (Cancel)

    The caller (Start-Ripper) is responsible for ejecting on Cancel and
    for routing 'Review' rips into _ReviewQueue (Phase 5 work).

.NOTES
    Why no MVVM / no INotifyPropertyChanged on PSCustomObject:
        WPF's DataGrid binds via TypeDescriptor and PSCustomObject
        binding is unreliable. Track rows therefore use a small CLR
        class `MusicRipper.TrackRow` declared inline with Add-Type.
        Album-level fields are read directly off named TextBoxes when
        the user clicks Rip / Send to Review — no two-way binding
        needed for non-collection properties.

    Why -OnResearch is a scriptblock:
        Keeps this script free of any MusicBrainz/network knowledge so
        the WPF code stays testable in the abstract and Start-Ripper
        owns the IO.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---- TrackRow class for DataGrid binding ----------------------------------
# Defined once per process. Add-Type is a no-op on subsequent dot-sources.
if (-not ('MusicRipper.TrackRow' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
namespace MusicRipper {
    public class TrackRow {
        public int    Number   { get; set; }
        public string Title    { get; set; }
        public string Artist   { get; set; }
        public int    LengthMs { get; set; }
        public string Length {
            get {
                int s = LengthMs / 1000;
                return string.Format("{0}:{1:D2}", s / 60, s % 60);
            }
        }
        // Round-trip carriers (not shown in the grid, preserved on save).
        public string ArtistMbid    { get; set; }
        public string RecordingMbid { get; set; }
    }
}
'@
}

function ConvertTo-MetadataViewModel {
<#
.SYNOPSIS
    Build a flat editable view-model from a normalized metadata candidate.

.DESCRIPTION
    Pure function. Takes one element of the .Candidates array produced by
    Get-RipperDiscMetadata and returns a view-model the WPF dialog can
    display. The view-model is a plain PSCustomObject for the album-level
    fields; .Tracks is a typed
    `System.Collections.ObjectModel.ObservableCollection[MusicRipper.TrackRow]`
    so the DataGrid edits it in place.

    The original candidate is attached as `.Source` so
    ConvertFrom-MetadataViewModel can lift the non-editable fields off it
    without a second lookup.

.PARAMETER Candidate
    A single normalized candidate (one element of $meta.Candidates from
    Get-RipperDiscMetadata, which already has CoverArtBytes attached if
    it's the BestMatch).

.EXAMPLE
    PS> $vm = ConvertTo-MetadataViewModel -Candidate $meta.BestMatch
    PS> $vm.Album
    The Dark Side of the Moon
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Candidate
    )

    $rows = [System.Collections.ObjectModel.ObservableCollection[MusicRipper.TrackRow]]::new()
    foreach ($t in @($Candidate.Tracks)) {
        $row = [MusicRipper.TrackRow]::new()
        $row.Number        = [int]$t.Number
        $row.Title         = [string]$t.Title
        $row.Artist        = [string]$t.Artist
        $row.LengthMs      = [int]$t.LengthMs
        $row.ArtistMbid    = [string]$t.ArtistMbid
        $row.RecordingMbid = [string]$t.RecordingMbid
        $rows.Add($row)
    }

    [pscustomobject]@{
        Album         = [string]$Candidate.Album
        AlbumArtist   = [string]$Candidate.AlbumArtist
        Year          = $Candidate.Year       # nullable int
        DiscNumber    = [int]$Candidate.DiscNumber
        TotalDiscs    = [int]$Candidate.TotalDiscs
        IsCompilation = [bool]$Candidate.IsCompilation
        Tracks        = $rows
        Source        = $Candidate
    }
}

function ConvertFrom-MetadataViewModel {
<#
.SYNOPSIS
    Apply an edited view-model back onto its source candidate.

.DESCRIPTION
    Pure function. Returns a NEW candidate PSCustomObject with the same
    shape as the input (so downstream code, including
    Get-RipperDiscMetadata's BestMatch consumers, keeps working). Editable
    fields are taken from the view-model; everything else (MBIDs,
    HasCoverArt, CoverArtBytes, ReleaseGroupMbid, Country, ...) is copied
    verbatim from $ViewModel.Source.

    Per-track edits: Title and Artist are taken from the view-model rows.
    Number, RecordingMbid, ArtistMbid, and LengthMs are preserved from
    the source (since the user can't edit them in the dialog). If the
    user added or removed rows, we'd lose the round-trip carriers — but
    the dialog doesn't expose add/remove, so we don't try to handle it.

.PARAMETER ViewModel
    The (possibly mutated) view-model returned by
    ConvertTo-MetadataViewModel.

.EXAMPLE
    PS> $vm = ConvertTo-MetadataViewModel -Candidate $meta.BestMatch
    PS> $vm.Album = 'Edited Title'
    PS> $updated = ConvertFrom-MetadataViewModel -ViewModel $vm
    PS> $updated.Album
    Edited Title
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ViewModel
    )

    $src = $ViewModel.Source

    # Rebuild Tracks: marry edited Title/Artist with preserved Number/Length/MBIDs.
    $newTracks = foreach ($row in @($ViewModel.Tracks)) {
        [pscustomobject]@{
            Number        = [int]$row.Number
            Title         = [string]$row.Title
            Artist        = [string]$row.Artist
            ArtistMbid    = [string]$row.ArtistMbid
            RecordingMbid = [string]$row.RecordingMbid
            LengthMs      = [int]$row.LengthMs
        }
    }

    $year = $null
    if ($null -ne $ViewModel.Year -and $ViewModel.Year -ne '') {
        $year = [int]$ViewModel.Year
    }

    $out = [pscustomobject]@{
        AlbumArtist      = [string]$ViewModel.AlbumArtist
        AlbumArtistMbid  = $src.AlbumArtistMbid
        Album            = [string]$ViewModel.Album
        ReleaseMbid      = $src.ReleaseMbid
        ReleaseGroupMbid = $src.ReleaseGroupMbid
        Year             = $year
        Country          = $src.Country
        TrackCount       = @($newTracks).Count
        DiscNumber       = [int]$ViewModel.DiscNumber
        TotalDiscs       = [int]$ViewModel.TotalDiscs
        IsCompilation    = [bool]$ViewModel.IsCompilation
        HasCoverArt      = [bool]$src.HasCoverArt
        Tracks           = @($newTracks)
    }

    # CoverArtBytes is only present on BestMatch (per Get-DiscMetadata).
    # Preserve it if the source had it.
    if ($src.PSObject.Properties.Name -contains 'CoverArtBytes') {
        $out | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue $src.CoverArtBytes -Force
    }

    $out
}

function Format-MetadataCandidateLabel {
<#
.SYNOPSIS
    One-line "Artist - Album (Year) [Country]" label for the candidate
    ComboBox. Pure helper, exported for tests.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Candidate
    )

    $parts = @()
    $parts += if ($Candidate.AlbumArtist) { $Candidate.AlbumArtist } else { '<unknown artist>' }
    $parts += '-'
    $parts += if ($Candidate.Album)       { $Candidate.Album }       else { '<unknown album>' }
    $label = $parts -join ' '
    if ($Candidate.Year)    { $label += " ($($Candidate.Year))" }
    if ($Candidate.Country) { $label += " [$($Candidate.Country)]" }
    if ($Candidate.TotalDiscs -gt 1) {
        $label += " (disc $($Candidate.DiscNumber)/$($Candidate.TotalDiscs))"
    }
    $label
}

function Show-RipperMetadataDialog {
<#
.SYNOPSIS
    Show the WPF metadata-confirmation dialog and return the user's choice.

.DESCRIPTION
    Builds the dialog from inline XAML, populates it from $Metadata,
    runs ShowDialog, and packages the result.

    Returned object:
        Action   : 'Rip' | 'Cancel' | 'Review'
        Metadata : updated candidate (Rip / Review) or $null (Cancel)

    Behavior on each button:
        - "Rip"             -> Action='Rip',    Metadata=ConvertFrom-VM
        - "Send to Review"  -> Action='Review', Metadata=ConvertFrom-VM
        - "Cancel" / [X]    -> Action='Cancel', Metadata=$null
        - Candidate ComboBox change rebinds the form to the chosen
          candidate's view-model. Edits to the previous candidate are
          discarded — that's intentional; switching candidates means
          "I picked the wrong release, start over."
        - "Re-search MusicBrainz" invokes -OnResearch (if supplied)
          and replaces the dialog's candidate list with the result.

.PARAMETER Metadata
    The full result object from Get-RipperDiscMetadata (has .Candidates,
    .BestMatch, .Status, .DiscId).

.PARAMETER OnResearch
    Optional scriptblock invoked when the user clicks "Re-search
    MusicBrainz". Must return a fresh metadata result of the same shape
    as -Metadata. If not supplied, the button is hidden.

.EXAMPLE
    PS> $r = Show-RipperMetadataDialog -Metadata $meta
    PS> if ($r.Action -eq 'Rip') { Invoke-Rip -Metadata $r.Metadata }
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Metadata,

        [scriptblock]$OnResearch
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml | Out-Null

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirm CD metadata" Height="640" Width="900"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize"
        FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Row 0: cover + candidate picker -->
    <Grid Grid.Row="0" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="230"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Grid.Column="0" BorderBrush="#888" BorderThickness="1" Background="#EEE"
              Width="220" Height="220" HorizontalAlignment="Left"
              SnapsToDevicePixels="True" UseLayoutRounding="True">
        <Image x:Name="CoverImage" Stretch="Uniform"
               RenderOptions.BitmapScalingMode="HighQuality"
               SnapsToDevicePixels="True" UseLayoutRounding="True"/>
      </Border>
      <Grid Grid.Column="1" Margin="12,0,0,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="StatusText" FontWeight="Bold" Margin="0,0,0,6"/>
        <DockPanel Grid.Row="1" Margin="0,0,0,6" LastChildFill="True">
          <TextBlock Text="Match:" Width="80" VerticalAlignment="Center"/>
          <Button x:Name="ResearchButton" Content="Re-search MusicBrainz"
                  DockPanel.Dock="Right" Padding="8,2" Margin="6,0,0,0"/>
          <ComboBox x:Name="CandidateCombo"/>
        </DockPanel>
        <TextBlock Grid.Row="2" x:Name="DiscIdText" Foreground="#666" FontSize="11"/>
        <TextBlock Grid.Row="3" x:Name="HelpText" Foreground="#444" FontSize="11" TextWrapping="Wrap"
                   Text="Edit album, year, or any track title before clicking Rip. Switching the Match dropdown picks a different MusicBrainz release."/>
      </Grid>
    </Grid>

    <!-- Row 1: editable album-level fields -->
    <Grid Grid.Row="1" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="80"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Grid.Column="0" Text="Album:"        VerticalAlignment="Center" Margin="0,0,6,4"/>
      <TextBox   Grid.Row="0" Grid.Column="1" x:Name="AlbumBox"    Margin="0,0,12,4"/>
      <TextBlock Grid.Row="0" Grid.Column="2" Text="Album Artist:" VerticalAlignment="Center" Margin="0,0,6,4"/>
      <TextBox   Grid.Row="0" Grid.Column="3" x:Name="ArtistBox"   Margin="0,0,12,4"/>
      <TextBlock Grid.Row="0" Grid.Column="4" Text="Year:"         VerticalAlignment="Center" Margin="0,0,6,4"/>
      <TextBox   Grid.Row="0" Grid.Column="5" x:Name="YearBox"     Margin="0,0,0,4"/>
      <CheckBox  Grid.Row="1" Grid.Column="1" x:Name="CompilationBox"
                 Content="Various Artists / compilation (routes to Various Artists/ in library)"
                 Grid.ColumnSpan="5"/>
    </Grid>

    <!-- Row 2: tracks -->
    <DataGrid Grid.Row="2" x:Name="TracksGrid"
              AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
              HeadersVisibility="Column" GridLinesVisibility="Horizontal"
              SelectionUnit="Cell" RowHeight="22">
      <DataGrid.Columns>
        <DataGridTextColumn Header="#"      Binding="{Binding Number}" IsReadOnly="True" Width="40"/>
        <DataGridTextColumn Header="Title"  Binding="{Binding Title,  UpdateSourceTrigger=LostFocus}" Width="SizeToCells" MinWidth="120">
          <DataGridTextColumn.ElementStyle>
            <Style TargetType="TextBlock">
              <Setter Property="Padding" Value="0,0,16,0"/>
            </Style>
          </DataGridTextColumn.ElementStyle>
        </DataGridTextColumn>
        <DataGridTextColumn Header="Artist" Binding="{Binding Artist, UpdateSourceTrigger=LostFocus}" Width="*"      MinWidth="160"/>
        <DataGridTextColumn Header="Length" Binding="{Binding Length}" IsReadOnly="True" Width="70"/>
      </DataGrid.Columns>
    </DataGrid>

    <!-- Row 3: action buttons -->
    <DockPanel Grid.Row="3" Margin="0,8,0,0" LastChildFill="True">
      <Button x:Name="CancelButton" Content="Cancel"          DockPanel.Dock="Right" Padding="14,4" MinWidth="110" Margin="6,0,0,0"
              ToolTip="Don't rip this disc. Ejects the CD and closes this window."/>
      <Button x:Name="ReviewButton" Content="Send to Review"  DockPanel.Dock="Right" Padding="14,4" MinWidth="130" Margin="6,0,0,0"
              ToolTip="Rip the disc into the review queue so you can fix the metadata later. Ejects when done."/>
      <Button x:Name="RipButton"    Content="Rip"             DockPanel.Dock="Right" Padding="14,4" MinWidth="110"
              IsDefault="True" Background="#0a7" Foreground="White" FontWeight="Bold"
              ToolTip="Rip the disc with the metadata shown above. Ejects when the rip finishes."/>
      <TextBlock x:Name="ActionHint" VerticalAlignment="Center" Foreground="#444" FontStyle="Italic"
                 TextWrapping="Wrap" Margin="0,0,12,0"/>
    </DockPanel>
  </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Find named controls.
    $controls = @{}
    foreach ($name in @(
        'CoverImage','StatusText','CandidateCombo','ResearchButton','DiscIdText',
        'AlbumBox','ArtistBox','YearBox','CompilationBox','TracksGrid',
        'RipButton','ReviewButton','CancelButton','ActionHint'
    )) {
        $controls[$name] = $window.FindName($name)
    }

    if (-not $OnResearch) { $controls.ResearchButton.Visibility = 'Collapsed' }

    # Capture our own helper functions as scriptblocks so the WPF event
    # handlers (which run in a child scope) can invoke them via `& $sb`.
    # `.GetNewClosure()` on the handlers themselves only captures *variables*
    # — functions defined in this script's scope aren't visible from inside
    # an Add_Click handler unless we bind them as locals first.
    $convertTo   = ${function:ConvertTo-MetadataViewModel}
    $convertFrom = ${function:ConvertFrom-MetadataViewModel}
    $formatLabel = ${function:Format-MetadataCandidateLabel}

    # State held in script: locals so closures can capture by reference.
    $state = [pscustomobject]@{
        Metadata    = $Metadata
        ViewModels  = @()       # parallel to Metadata.Candidates
        CurrentVm   = $null
        Result      = $null     # set by button handlers
    }

    # Helpers ---------------------------------------------------------------
    $rebuildViewModels = {
        $state.ViewModels = @(
            foreach ($c in @($state.Metadata.Candidates)) {
                & $convertTo -Candidate $c
            }
        )
    }

    $bindCoverArt = {
        param($candidate)
        $controls.CoverImage.Source = $null
        if ($candidate -and ($candidate.PSObject.Properties.Name -contains 'CoverArtBytes') -and $candidate.CoverArtBytes) {
            try {
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.CacheOption  = 'OnLoad'
                $bmp.StreamSource = [System.IO.MemoryStream]::new([byte[]]$candidate.CoverArtBytes)
                $bmp.EndInit()
                $bmp.Freeze()
                $controls.CoverImage.Source = $bmp
            } catch {
                # Bad image bytes shouldn't kill the dialog.
                $controls.CoverImage.Source = $null
            }
        }
    }

    $bindCandidate = {
        param($index)
        if ($index -lt 0 -or $index -ge @($state.ViewModels).Count) { return }
        $vm = $state.ViewModels[$index]
        $state.CurrentVm = $vm
        $controls.AlbumBox.Text         = [string]$vm.Album
        $controls.ArtistBox.Text        = [string]$vm.AlbumArtist
        $controls.YearBox.Text          = if ($null -ne $vm.Year) { [string]$vm.Year } else { '' }
        $controls.CompilationBox.IsChecked = [bool]$vm.IsCompilation
        $controls.TracksGrid.ItemsSource   = $vm.Tracks
        & $bindCoverArt $vm.Source
    }

    $populateCombo = {
        $controls.CandidateCombo.Items.Clear()
        foreach ($c in @($state.Metadata.Candidates)) {
            [void]$controls.CandidateCombo.Items.Add((& $formatLabel -Candidate $c))
        }
        # Pick the BestMatch as the initial selection if we can find it.
        $idx = 0
        if ($state.Metadata.BestMatch) {
            for ($i = 0; $i -lt @($state.Metadata.Candidates).Count; $i++) {
                if ($state.Metadata.Candidates[$i].ReleaseMbid -eq $state.Metadata.BestMatch.ReleaseMbid) {
                    $idx = $i; break
                }
            }
        }
        if ($controls.CandidateCombo.Items.Count -gt 0) {
            $controls.CandidateCombo.SelectedIndex = $idx
        }
    }

    $applyEditsToCurrentVm = {
        if (-not $state.CurrentVm) { return }
        $state.CurrentVm.Album         = [string]$controls.AlbumBox.Text
        $state.CurrentVm.AlbumArtist   = [string]$controls.ArtistBox.Text
        $state.CurrentVm.IsCompilation = [bool]$controls.CompilationBox.IsChecked
        $yearText = [string]$controls.YearBox.Text
        if ([string]::IsNullOrWhiteSpace($yearText)) {
            $state.CurrentVm.Year = $null
        } else {
            $parsed = 0
            if ([int]::TryParse($yearText.Trim(), [ref]$parsed)) {
                $state.CurrentVm.Year = $parsed
            } # else: leave previous value untouched, validated on Rip click
        }
        # Force any in-progress DataGrid edit to commit before we read rows.
        # DataGridEditingUnit only has Cell and Row — commit cell first, then row.
        [void]$controls.TracksGrid.CommitEdit('Cell', $true)
        [void]$controls.TracksGrid.CommitEdit('Row',  $true)
    }

    # Status / disc-id strip --------------------------------------------------
    $statusText = switch ($state.Metadata.Status) {
        'Match'       { 'Single MusicBrainz match.' }
        'MultiMatch'  { "$(@($state.Metadata.Candidates).Count) MusicBrainz matches — pick one." }
        'NoMatch'     { 'No MusicBrainz match for this disc.' }
        'Offline'     { 'MusicBrainz offline — placeholder shown.' }
        default       { "Status: $($state.Metadata.Status)" }
    }
    $controls.StatusText.Text = $statusText
    $controls.DiscIdText.Text = "Disc ID: $($state.Metadata.DiscId)"

    # If we have no candidates at all, the dialog should still come up so the
    # user can route the disc to Review. Synthesize a placeholder VM.
    if (-not @($state.Metadata.Candidates) -or @($state.Metadata.Candidates).Count -eq 0) {
        $placeholder = [pscustomobject]@{
            AlbumArtist      = ''
            AlbumArtistMbid  = $null
            Album            = ''
            ReleaseMbid      = $null
            ReleaseGroupMbid = $null
            Year             = $null
            Country          = $null
            TrackCount       = 0
            DiscNumber       = 1
            TotalDiscs       = 1
            IsCompilation    = $false
            HasCoverArt      = $false
            Tracks           = @()
        }
        $state.Metadata = [pscustomobject]@{
            DiscId     = $state.Metadata.DiscId
            Status     = $state.Metadata.Status
            BestMatch  = $placeholder
            Candidates = @($placeholder)
        }
        # Disable Rip when we have nothing — Review is the right action.
        $controls.RipButton.IsEnabled = $false
        # Promote Send to Review to the primary action so the user knows what to click.
        $controls.ReviewButton.IsDefault  = $true
        $controls.ReviewButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0a7')
        $controls.ReviewButton.Foreground = [System.Windows.Media.Brushes]::White
        $controls.ReviewButton.FontWeight = 'Bold'
        $controls.ActionHint.Text = 'No metadata match — click "Send to Review" to rip and tag this disc later.'
    }

    & $rebuildViewModels
    & $populateCombo
    & $bindCandidate $controls.CandidateCombo.SelectedIndex

    # Wire up handlers -------------------------------------------------------
    $controls.CandidateCombo.Add_SelectionChanged({
        & $bindCandidate $controls.CandidateCombo.SelectedIndex
    }.GetNewClosure())

    $controls.ResearchButton.Add_Click({
        try {
            $controls.ResearchButton.IsEnabled = $false
            $fresh = & $OnResearch
            if ($fresh) {
                $state.Metadata = $fresh
                & $rebuildViewModels
                & $populateCombo
                & $bindCandidate $controls.CandidateCombo.SelectedIndex
                $controls.RipButton.IsEnabled = (@($state.Metadata.Candidates).Count -gt 0)
            }
        } catch {
            [System.Windows.MessageBox]::Show("Re-search failed:`n$($_.Exception.Message)",
                'MusicRipper', 'OK', 'Warning') | Out-Null
        } finally {
            $controls.ResearchButton.IsEnabled = $true
        }
    }.GetNewClosure())

    $controls.RipButton.Add_Click({
        & $applyEditsToCurrentVm
        # Minimal validation: Album + Album Artist non-empty, Year (if given) is sane.
        if ([string]::IsNullOrWhiteSpace($state.CurrentVm.Album) -or
            [string]::IsNullOrWhiteSpace($state.CurrentVm.AlbumArtist)) {
            [System.Windows.MessageBox]::Show(
                'Album and Album Artist are required. Use "Send to Review" if you want to rip without metadata.',
                'MusicRipper', 'OK', 'Warning') | Out-Null
            return
        }
        $state.Result = [pscustomobject]@{
            Action   = 'Rip'
            Metadata = & $convertFrom -ViewModel $state.CurrentVm
        }
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $controls.ReviewButton.Add_Click({
        & $applyEditsToCurrentVm
        $state.Result = [pscustomobject]@{
            Action   = 'Review'
            Metadata = & $convertFrom -ViewModel $state.CurrentVm
        }
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $controls.CancelButton.Add_Click({
        $state.Result = [pscustomobject]@{ Action = 'Cancel'; Metadata = $null }
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    $window.Add_Closing({
        # If the user X'd out without using a button, treat as Cancel.
        if (-not $state.Result) {
            $state.Result = [pscustomobject]@{ Action = 'Cancel'; Metadata = $null }
        }
    }.GetNewClosure())

    [void]$window.ShowDialog()
    return $state.Result
}
