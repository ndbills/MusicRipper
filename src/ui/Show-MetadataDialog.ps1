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

    # Build a Number -> source-track lookup so we can carry over per-track
    # fields the dialog doesn't expose (ArtistSort). User can't add/remove
    # rows in the dialog, so the source track set is authoritative.
    $srcTrackByNumber = @{}
    if ($src -and $src.PSObject.Properties['Tracks'] -and $src.Tracks) {
        foreach ($st in @($src.Tracks)) {
            $srcTrackByNumber[[int]$st.Number] = $st
        }
    }

    # Rebuild Tracks: marry edited Title/Artist with preserved Number/Length/MBIDs.
    $newTracks = foreach ($row in @($ViewModel.Tracks)) {
        $srcT = $srcTrackByNumber[[int]$row.Number]
        $artistSort = $null
        $artists = $null
        $releaseTrackMbid = $null
        # Prefer the source's ArtistMbid (may be a string[] for multi-artist
        # credits). Fall back to the row's flat string only if the source
        # didn't carry it (legacy candidates).
        $artistMbid = [string]$row.ArtistMbid
        if ($srcT) {
            if ($srcT.PSObject.Properties['ArtistSort'])       { $artistSort       = [string]$srcT.ArtistSort }
            if ($srcT.PSObject.Properties['Artists'])          { $artists          = $srcT.Artists }
            if ($srcT.PSObject.Properties['ReleaseTrackMbid']) { $releaseTrackMbid = [string]$srcT.ReleaseTrackMbid }
            if ($srcT.PSObject.Properties['ArtistMbid'] -and $srcT.ArtistMbid) { $artistMbid = $srcT.ArtistMbid }
        }
        [pscustomobject]@{
            Number           = [int]$row.Number
            Title            = [string]$row.Title
            Artist           = [string]$row.Artist
            Artists          = $artists
            ArtistSort       = $artistSort
            ArtistMbid       = $artistMbid
            RecordingMbid    = [string]$row.RecordingMbid
            ReleaseTrackMbid = $releaseTrackMbid
            LengthMs         = [int]$row.LengthMs
        }
    }

    $year = $null
    if ($null -ne $ViewModel.Year -and $ViewModel.Year -ne '') {
        $year = [int]$ViewModel.Year
    }

    # Helper: pull a property from $src or return $null if absent (strict-safe).
    $srcProp = {
        param($name)
        if ($src -and $src.PSObject.Properties[$name]) { $src.$name } else { $null }
    }

    $out = [pscustomobject]@{
        AlbumArtist      = [string]$ViewModel.AlbumArtist
        AlbumArtists     = & $srcProp 'AlbumArtists'
        AlbumArtistSort  = & $srcProp 'AlbumArtistSort'
        AlbumArtistMbid  = $src.AlbumArtistMbid
        Album            = [string]$ViewModel.Album
        Media            = & $srcProp 'Media'
        ReleaseMbid      = $src.ReleaseMbid
        ReleaseGroupMbid = $src.ReleaseGroupMbid
        Year             = $year
        ReleaseDate      = & $srcProp 'ReleaseDate'
        OriginalYear     = & $srcProp 'OriginalYear'
        OriginalDate     = & $srcProp 'OriginalDate'
        Country          = $src.Country
        ReleaseStatus    = & $srcProp 'ReleaseStatus'
        ReleaseType      = & $srcProp 'ReleaseType'
        Script           = & $srcProp 'Script'
        Language         = & $srcProp 'Language'
        Asin             = & $srcProp 'Asin'
        Barcode          = & $srcProp 'Barcode'
        LabelName        = & $srcProp 'LabelName'
        CatalogNumber    = & $srcProp 'CatalogNumber'
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

function Show-RipperCoverArtPicker {
<#
.SYNOPSIS
    Show the "Change cover…" modal. Queries every configured cover-art
    provider for the current candidate, shows a thumbnail per provider
    that returned bytes, and returns the picked response (or $null on
    cancel / no-change).

.DESCRIPTION
    Pipeline position:
        Sub-modal opened from Show-RipperMetadataDialog when the user
        clicks "Change cover…". Unlike the default cover-art chain
        (first-non-empty wins), this picker runs every provider and
        presents the results side-by-side so the user can compare.

        UI shape:
            top   - status line ("Looking up cover art…" / "3 of 3
                    providers returned art" etc)
            mid   - ListView with a thumbnail-only template (cover
                    image 180x180 + source caption below)
            bttm  - Keep current / Use selected / Cancel buttons

.PARAMETER Owner
    Owner Window for proper modal parenting.

.PARAMETER Candidate
    The metadata candidate the user is currently viewing. Provider
    lookups key off its .ReleaseMbid / .AlbumArtist / .Album.

.PARAMETER OnLookup
    Scriptblock invoked once the modal opens. Receives the candidate
    and must return an array of cover-art responses
    (@{Source; Bytes; Url; Diagnostic}) — typically the output of
    Get-RipperCoverArtCandidates. The modal renders each response
    that has non-empty Bytes as a pickable thumbnail.

.PARAMETER CurrentBytes
    Optional byte[] — the image currently bound to the main dialog's
    cover. When supplied, the modal renders a synthetic "(current)"
    row at the top so the user can reset to it.

.EXAMPLE
    PS> $pick = Show-RipperCoverArtPicker -Owner $w -Candidate $vm.Source `
                    -OnLookup { param($c) Get-RipperCoverArtCandidates -Candidate $c }
    PS> if ($pick) { $best.CoverArtBytes = $pick.Bytes }
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [System.Windows.Window]$Owner,

        [Parameter(Mandatory)]
        [pscustomobject]$Candidate,

        [Parameter(Mandatory)]
        [scriptblock]$OnLookup,

        [byte[]]$CurrentBytes
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml | Out-Null

    # Picker-specific converter (DecodePixelWidth=240 to match the larger
    # ~140px tiles in this dialog). MUST NOT share a class name with
    # Show-RipperTextSearchDialog's converter -- that one decodes at 80
    # for the metadata-dialog thumbnails, and whichever Add-Type fires
    # first wins for the whole session, leaving the loser's consumer
    # stuck with the wrong decode size. Symptom of the collision was
    # blurry tiles in this picker after the user had opened the text-
    # search modal earlier in the session (Phase 5.3 latent bug,
    # surfaced during 5.7 manual verification).
    if (-not ('MusicRipper.BytesToLargeImageConverter' -as [type])) {
        $refAsms = @(
            [System.Windows.Data.IValueConverter].Assembly.Location
            [System.Windows.Media.Imaging.BitmapImage].Assembly.Location
            [System.Windows.DependencyObject].Assembly.Location
            [psobject].Assembly.Location
        )
        Add-Type -ReferencedAssemblies $refAsms -TypeDefinition @'
using System;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Windows.Data;
using System.Windows.Media.Imaging;

namespace MusicRipper {
    public class BytesToLargeImageConverter : IValueConverter {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture) {
            PSObject pso = value as PSObject;
            if (pso != null) value = pso.BaseObject;
            byte[] bytes = value as byte[];
            if (bytes == null || bytes.Length == 0) return null;
            try {
                BitmapImage bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.DecodePixelWidth = 240;
                bmp.StreamSource = new MemoryStream(bytes);
                bmp.EndInit();
                bmp.Freeze();
                return bmp;
            } catch {
                return null;
            }
        }
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) {
            throw new NotImplementedException();
        }
    }
}
'@
    }

    $asmName = [MusicRipper.BytesToLargeImageConverter].Assembly.GetName().Name
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:mr="clr-namespace:MusicRipper;assembly=$asmName"
        Title="Change cover art" Height="520" Width="780"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <mr:BytesToLargeImageConverter x:Key="BytesToImg"/>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" x:Name="StatusText" Margin="0,0,0,8"
               Foreground="#444" FontStyle="Italic"
               Text="Looking up cover art from every provider..."/>

    <ListView Grid.Row="1" x:Name="ThumbsList" SelectionMode="Single"
              ScrollViewer.HorizontalScrollBarVisibility="Disabled"
              ScrollViewer.VerticalScrollBarVisibility="Auto">
      <ListView.ItemsPanel>
        <ItemsPanelTemplate>
          <WrapPanel Orientation="Horizontal"/>
        </ItemsPanelTemplate>
      </ListView.ItemsPanel>
      <ListView.ItemTemplate>
        <DataTemplate>
          <Border BorderBrush="#888" BorderThickness="1" Background="#F8F8F8"
                  Margin="4" Padding="6" Width="210">
            <StackPanel>
              <Border BorderBrush="#CCC" BorderThickness="1" Background="#EEE"
                      Width="180" Height="180" HorizontalAlignment="Center"
                      SnapsToDevicePixels="True" UseLayoutRounding="True">
                <Image Source="{Binding Bytes, Converter={StaticResource BytesToImg}}"
                       Stretch="Uniform"
                       RenderOptions.BitmapScalingMode="HighQuality"/>
              </Border>
              <TextBlock Text="{Binding Source}" FontWeight="Bold"
                         HorizontalAlignment="Center" Margin="0,6,0,0"/>
              <TextBlock Text="{Binding SizeLabel}" Foreground="#666"
                         HorizontalAlignment="Center" FontSize="11"/>
            </StackPanel>
          </Border>
        </DataTemplate>
      </ListView.ItemTemplate>
    </ListView>

    <DockPanel Grid.Row="2" Margin="0,8,0,0" LastChildFill="False">
      <Button x:Name="CancelButton" Content="Cancel"        DockPanel.Dock="Right" Padding="14,4" MinWidth="110" Margin="6,0,0,0"/>
      <Button x:Name="UseButton"    Content="Use selected"  DockPanel.Dock="Right" Padding="14,4" MinWidth="130" IsEnabled="False"
              Background="#0a7" Foreground="White" FontWeight="Bold"/>
    </DockPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $window.Owner = $Owner }

    # Phase-4 lesson: always install a dispatcher unhandled-exception
    # sink on any new WPF window so binding / template errors get
    # logged instead of bubbling as a silent NRE at ShowDialog.
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\cover-picker-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            if ($ex.InnerException) {
                $msg += "`n-- inner: $($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)"
            }
            Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            try { Write-RipperLog ERROR 'Show-RipperCoverArtPicker' "Dispatcher exception: $($ex.GetType().FullName): $($ex.Message) (sidecar: $sidecar)" } catch {}
        } catch {}
        $e.Handled = $true
    })

    $controls = @{}
    foreach ($n in @('StatusText','ThumbsList','UseButton','CancelButton')) {
        $controls[$n] = $window.FindName($n)
    }

    $state = [pscustomobject]@{ Picked = $null }

    $controls.ThumbsList.Add_SelectionChanged({
        $controls.UseButton.IsEnabled = ($null -ne $controls.ThumbsList.SelectedItem)
    }.GetNewClosure())

    $controls.UseButton.Add_Click({
        $sel = $controls.ThumbsList.SelectedItem
        if ($sel) {
            # Strip the PSObject wrapper around the ItemsSource row so
            # the caller gets the original cover-art response shape.
            $obj = $sel
            if ($obj -is [System.Management.Automation.PSObject]) {
                $obj = $obj.PSObject.BaseObject
            }
            $state.Picked = $sel
            $window.DialogResult = $true
            $window.Close()
        }
    }.GetNewClosure())

    $controls.CancelButton.Add_Click({
        $state.Picked = $null
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    # Fire the lookup once the window is shown so the spinner message
    # is visible before we start hitting the network. Dispatcher.Invoke
    # on ContextIdle pattern: the window is up, layout done, now go.
    $window.Add_ContentRendered({
        try {
            $results = & $OnLookup $Candidate
            $rows = @()
            if ($CurrentBytes -and $CurrentBytes.Length -gt 0) {
                $rows += [pscustomobject]@{
                    Source    = '(current)'
                    Bytes     = $CurrentBytes
                    Url       = $null
                    SizeLabel = "$([math]::Round($CurrentBytes.Length / 1024)) KB"
                }
            }
            foreach ($r in @($results)) {
                if ($r -and $r.Bytes -and $r.Bytes.Length -gt 0) {
                    $rows += [pscustomobject]@{
                        Source    = [string]$r.Source
                        Bytes     = [byte[]]$r.Bytes
                        Url       = [string]$r.Url
                        SizeLabel = "$([math]::Round($r.Bytes.Length / 1024)) KB"
                    }
                }
            }
            $controls.ThumbsList.ItemsSource = $rows
            $hitCount = @($results | Where-Object { $_ -and $_.Bytes }).Count
            $totalCount = @($results).Count
            $controls.StatusText.Text = if ($rows.Count -eq 0) {
                'No cover art found from any provider.'
            } else {
                "$hitCount of $totalCount provider(s) returned art. Pick one and click Use selected."
            }
        } catch {
            $controls.StatusText.Text = "Cover-art lookup failed: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    [void]$window.ShowDialog()
    return $state.Picked
}

function Show-RipperTextSearchDialog {
<#
.SYNOPSIS
    Show the "Search by text…" sub-modal and return the user's pick
    (a single normalized candidate) or $null on cancel.

.DESCRIPTION
    Pipeline position:
        Sub-modal opened from Show-RipperMetadataDialog when the user
        clicks "Search by text…". Lets them type artist/album/year,
        toggle the providers to search, fire off the lookup, and pick
        one result. The picked candidate is returned to the caller
        which appends it to the main dialog's candidate list.

        UI shape (single window):
            top   - input fields (Artist / Album / Year)
            mid   - dynamic checkbox row, one per provider, plus an
                    "All providers" master toggle (default: checked)
            bttm  - results ListView with Source / Artist / Album /
                    Year / Tracks columns
            row   - Search / Use selected / Cancel buttons

.PARAMETER Owner
    Owner Window for proper modal parenting (centers over the parent
    and preserves taskbar grouping).

.PARAMETER Providers
    Names of providers to render as checkboxes, in chain order. Each
    name appears in the search payload's Providers field when its
    checkbox is ticked.

.PARAMETER OnSearch
    Scriptblock invoked when the user clicks "Search". Receives a
    hashtable @{Artist; Album; Year; Providers} and must return an
    object with a .Candidates property (the
    Search-RipperMetadataByText result shape).

.PARAMETER InitialArtist
    Pre-populates the Artist textbox.

.PARAMETER InitialAlbum
    Pre-populates the Album textbox.

.PARAMETER InitialYear
    Pre-populates the Year textbox.

.PARAMETER CachedState
    Optional. A previous-result snapshot from a prior invocation in
    the same session, of the shape
        @{ Artist; Album; Year; Providers; Candidates; StatusText }
    When supplied, the modal opens with the result list and the
    Artist/Album/Year/Providers controls all pre-populated as the
    user left them. Lets the user re-open the modal, see what they
    last searched, and either pick a different candidate or refine
    the criteria and re-search.

.EXAMPLE
    PS> Show-RipperTextSearchDialog -Owner $w -Providers @('MusicBrainz') -OnSearch $cb
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [System.Windows.Window]$Owner,

        [Parameter(Mandatory)]
        [string[]]$Providers,

        [Parameter(Mandatory)]
        [scriptblock]$OnSearch,

        [string]$InitialArtist = '',
        [string]$InitialAlbum  = '',
        [string]$InitialYear   = '',

        [hashtable]$CachedState
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml | Out-Null

    # Compile a tiny IValueConverter once per session that turns a
    # byte[] (the candidate's CoverArtBytes) into a Frozen BitmapImage
    # WPF can render. We bind to CoverArtBytes directly with this
    # converter rather than an Add-Member CoverImage property because
    # PSObject reflection through TypeDescriptor is unreliable for CLR-
    # typed values (string note-properties bind fine; BitmapImage ones
    # surface as null in DataTemplate bindings on some builds).
    if (-not ('MusicRipper.BytesToImageConverter' -as [type])) {
        # Resolve the .NET 9 WPF assemblies via real types so Add-Type
        # doesn't pick up the .NET Framework 4.0 reference assemblies
        # (which would mismatch with the WPF runtime version PowerShell
        # 7 actually loads -- "uses 'WindowsBase' which has a higher
        # version than referenced assembly" build error).
        $refAsms = @(
            [System.Windows.Data.IValueConverter].Assembly.Location
            [System.Windows.Media.Imaging.BitmapImage].Assembly.Location
            [System.Windows.DependencyObject].Assembly.Location
            [psobject].Assembly.Location
        )
        Add-Type -ReferencedAssemblies $refAsms -TypeDefinition @'
using System;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Windows.Data;
using System.Windows.Media.Imaging;

namespace MusicRipper {
    public class BytesToImageConverter : IValueConverter {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture) {
            // WPF data binding through PSObject's ICustomTypeDescriptor
            // surfaces NoteProperty values still wrapped in PSObject;
            // unwrap to the BaseObject before the byte[] cast or it
            // silently returns null and the thumbnail goes blank.
            PSObject pso = value as PSObject;
            if (pso != null) value = pso.BaseObject;
            byte[] bytes = value as byte[];
            if (bytes == null || bytes.Length == 0) return null;
            try {
                BitmapImage bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.DecodePixelWidth = 80;
                bmp.StreamSource = new MemoryStream(bytes);
                bmp.EndInit();
                bmp.Freeze();
                return bmp;
            } catch {
                return null;
            }
        }
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) {
            throw new NotImplementedException();
        }
    }
}
'@
    }

    # The XAML declares the converter in Window.Resources via a
    # clr-namespace:assembly= mapping to the Add-Type'd assembly above.
    # This is the only reliable way to make {StaticResource BytesToImg}
    # resolve from inside a DataTemplate: Window.Resources.Add() after
    # XamlReader.Load is too late -- DataTemplates resolve StaticResource
    # against the resource dictionary as it stood at parse time.
    $asmName = [MusicRipper.BytesToImageConverter].Assembly.GetName().Name
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:mr="clr-namespace:MusicRipper;assembly=$asmName"
        Title="Search metadata by text" Height="540" Width="780"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <mr:BytesToImageConverter x:Key="BytesToImg"/>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Row 0: input fields -->
    <Grid Grid.Row="0" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="80"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Artist:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox   Grid.Column="1" x:Name="ArtistBox" Margin="0,0,12,0"/>
      <TextBlock Grid.Column="2" Text="Album:"  VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox   Grid.Column="3" x:Name="AlbumBox"  Margin="0,0,12,0"/>
      <TextBlock Grid.Column="4" Text="Year:"   VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox   Grid.Column="5" x:Name="YearBox"/>
    </Grid>

    <!-- Row 1: provider checkboxes (dynamically populated) -->
    <DockPanel Grid.Row="1" Margin="0,0,0,8" LastChildFill="True">
      <TextBlock Text="Providers:" Width="80" VerticalAlignment="Center"/>
      <CheckBox x:Name="AllProvidersCheck" Content="All providers"
                VerticalAlignment="Center" Margin="0,0,16,0" IsChecked="True"/>
      <ItemsControl x:Name="ProvidersHost">
        <ItemsControl.ItemsPanel>
          <ItemsPanelTemplate>
            <StackPanel Orientation="Horizontal"/>
          </ItemsPanelTemplate>
        </ItemsControl.ItemsPanel>
      </ItemsControl>
    </DockPanel>

    <!-- Row 2: search button + status -->
    <DockPanel Grid.Row="2" Margin="0,0,0,8" LastChildFill="True">
      <Button x:Name="SearchButton" Content="Search" DockPanel.Dock="Right"
              Padding="14,4" MinWidth="100" IsDefault="True"
              Background="#0a7" Foreground="White" FontWeight="Bold"/>
      <TextBlock x:Name="StatusText" VerticalAlignment="Center" Foreground="#444" FontStyle="Italic"
                 Text="Type at least an artist or an album, then click Search."/>
    </DockPanel>

    <!-- Row 3: results -->
    <ListView Grid.Row="3" x:Name="ResultsList" SelectionMode="Single">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Cover" Width="68">
            <GridViewColumn.CellTemplate>
              <DataTemplate>
                <Image Source="{Binding CoverArtBytes, Converter={StaticResource BytesToImg}}"
                       Width="56" Height="56" Stretch="Uniform"/>
              </DataTemplate>
            </GridViewColumn.CellTemplate>
          </GridViewColumn>
          <GridViewColumn Header="Source" Width="100"  DisplayMemberBinding="{Binding Source}"/>
          <GridViewColumn Header="Artist" Width="190"  DisplayMemberBinding="{Binding AlbumArtist}"/>
          <GridViewColumn Header="Album"  Width="230"  DisplayMemberBinding="{Binding Album}"/>
          <GridViewColumn Header="Year"   Width="60"   DisplayMemberBinding="{Binding Year}"/>
          <GridViewColumn Header="Tracks" Width="60"   DisplayMemberBinding="{Binding TrackCount}"/>
        </GridView>
      </ListView.View>
    </ListView>

    <!-- Row 4: action buttons -->
    <DockPanel Grid.Row="4" Margin="0,8,0,0" LastChildFill="False">
      <Button x:Name="CancelButton" Content="Cancel"        DockPanel.Dock="Right" Padding="14,4" MinWidth="110" Margin="6,0,0,0"/>
      <Button x:Name="UseButton"    Content="Use selected"  DockPanel.Dock="Right" Padding="14,4" MinWidth="130" IsEnabled="False"/>
    </DockPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $window.Owner = $Owner }

    # Phase-4 lesson: WPF re-raises tick / binding / template errors as
    # a generic NullReferenceException at the call site of ShowDialog,
    # making the original failure invisible. Always install a dispatcher
    # unhandled-exception sink that writes a sidecar log so we can
    # actually see what blew up. The crash that motivated this was a
    # template error after Search returned candidates; without this
    # handler the user just sees the window vanish.
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\text-search-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            if ($ex.InnerException) {
                $msg += "`n-- inner: $($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)`n$($ex.InnerException.StackTrace)"
            }
            Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            try { Write-RipperLog ERROR 'Show-RipperTextSearchDialog' "Dispatcher exception: $($ex.GetType().FullName): $($ex.Message) (sidecar: $sidecar)" } catch {}
        } catch {}
        $e.Handled = $true
    })

    $controls = @{}
    foreach ($n in @('ArtistBox','AlbumBox','YearBox','AllProvidersCheck','ProvidersHost',
                      'SearchButton','StatusText','ResultsList','UseButton','CancelButton')) {
        $controls[$n] = $window.FindName($n)
    }
    $controls.ArtistBox.Text = $InitialArtist
    $controls.AlbumBox.Text  = $InitialAlbum
    $controls.YearBox.Text   = $InitialYear

    # Dynamic provider checkboxes — one per name, all checked by default,
    # and grouped under the "All providers" master toggle.
    $providerChecks = @{}
    foreach ($p in $Providers) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content     = [string]$p
        $cb.IsChecked   = $true
        $cb.Margin      = '0,0,12,0'
        $cb.VerticalAlignment = 'Center'
        [void]$controls.ProvidersHost.Items.Add($cb)
        $providerChecks[[string]$p] = $cb
    }

    $state = [pscustomobject]@{
        Picked     = $null
        # Snapshot returned to the caller so it can be passed back as
        # -CachedState next time the user opens the modal in this session.
        LastSearch = $null
    }

    # If the caller passed a session cache, re-hydrate the controls
    # before wiring up handlers so the user picks up where they left
    # off. The CachedState shape is a hashtable -- see -CachedState
    # docstring above.
    if ($CachedState) {
        if ($CachedState.ContainsKey('Artist'))   { $controls.ArtistBox.Text = [string]$CachedState['Artist'] }
        if ($CachedState.ContainsKey('Album'))    { $controls.AlbumBox.Text  = [string]$CachedState['Album']  }
        if ($CachedState.ContainsKey('Year') -and $CachedState['Year']) {
            $controls.YearBox.Text = [string]$CachedState['Year']
        }
        if ($CachedState.ContainsKey('Providers') -and $CachedState['Providers']) {
            $checked = @($CachedState['Providers'])
            foreach ($k in @($providerChecks.Keys)) {
                $providerChecks[$k].IsChecked = ($checked -contains $k)
            }
            $controls.AllProvidersCheck.IsChecked = ($checked.Count -eq $providerChecks.Count)
        }
        if ($CachedState.ContainsKey('Candidates') -and $CachedState['Candidates']) {
            $cands = @($CachedState['Candidates'])
            $controls.ResultsList.ItemsSource = $cands
            if ($CachedState.ContainsKey('StatusText') -and $CachedState['StatusText']) {
                $controls.StatusText.Text = [string]$CachedState['StatusText']
            } else {
                $controls.StatusText.Text = "$($cands.Count) cached match(es) — pick one or refine and Search."
            }
        }
    }

    # When "All" toggles, mirror to every provider checkbox. The reverse
    # path (a provider toggle clearing "All") is handled by individual
    # handlers below — keeps the master checkbox an honest reflection.
    $controls.AllProvidersCheck.Add_Click({
        $on = [bool]$controls.AllProvidersCheck.IsChecked
        foreach ($k in $providerChecks.Keys) {
            $providerChecks[$k].IsChecked = $on
        }
    }.GetNewClosure())
    foreach ($k in $providerChecks.Keys) {
        $providerChecks[$k].Add_Click({
            $allOn = $true
            foreach ($kk in $providerChecks.Keys) {
                if (-not $providerChecks[$kk].IsChecked) { $allOn = $false; break }
            }
            $controls.AllProvidersCheck.IsChecked = $allOn
        }.GetNewClosure())
    }

    $controls.ResultsList.Add_SelectionChanged({
        $controls.UseButton.IsEnabled = ($null -ne $controls.ResultsList.SelectedItem)
    }.GetNewClosure())

    $controls.SearchButton.Add_Click({
        $artist = ([string]$controls.ArtistBox.Text).Trim()
        $album  = ([string]$controls.AlbumBox.Text).Trim()
        $yearText = ([string]$controls.YearBox.Text).Trim()
        $year = 0
        if ($yearText -and -not [int]::TryParse($yearText, [ref]$year)) {
            [System.Windows.MessageBox]::Show('Year must be a number (or left blank).',
                'MusicRipper', 'OK', 'Warning') | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($artist) -and [string]::IsNullOrWhiteSpace($album)) {
            [System.Windows.MessageBox]::Show('Please enter an artist or album to search.',
                'MusicRipper', 'OK', 'Warning') | Out-Null
            return
        }
        $picked = @()
        foreach ($k in $providerChecks.Keys) {
            if ($providerChecks[$k].IsChecked) { $picked += $k }
        }
        if ($picked.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Please pick at least one provider.',
                'MusicRipper', 'OK', 'Warning') | Out-Null
            return
        }

        try {
            $controls.SearchButton.IsEnabled = $false
            $controls.StatusText.Text = "Searching $($picked -join ', ')…"
            $controls.ResultsList.ItemsSource = $null
            $controls.UseButton.IsEnabled = $false

            $payload = @{
                Artist    = $artist
                Album     = $album
                Year      = $year
                Providers = $picked
            }
            $result = & $OnSearch $payload

            $cands = @()
            if ($result -and $result.PSObject.Properties['Candidates']) {
                $cands = @($result.Candidates)
            }
            $controls.ResultsList.ItemsSource = $cands
            $statusMsg = if ($cands.Count -eq 0) {
                'No matches.'
            } else {
                "$($cands.Count) match(es) — pick one and click Use selected."
            }
            $controls.StatusText.Text = $statusMsg
            # Snapshot for the caller's session cache.
            $state.LastSearch = @{
                Artist     = $artist
                Album      = $album
                Year       = $year
                Providers  = @($picked)
                Candidates = @($cands)
                StatusText = $statusMsg
            }
        } catch {
            $controls.StatusText.Text = "Search failed: $($_.Exception.Message)"
        } finally {
            $controls.SearchButton.IsEnabled = $true
        }
    }.GetNewClosure())

    $controls.UseButton.Add_Click({
        $sel = $controls.ResultsList.SelectedItem
        if ($sel) {
            $state.Picked = $sel
            $window.DialogResult = $true
            $window.Close()
        }
    }.GetNewClosure())

    $controls.CancelButton.Add_Click({
        $state.Picked = $null
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    [void]$window.ShowDialog()
    return @{
        Picked     = $state.Picked
        LastSearch = $state.LastSearch
    }
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
        - "Search by text…" opens a sub-modal (artist/album/year +
          per-provider checkboxes) that invokes -OnTextSearch and
          appends the picked candidate to the dropdown.

.PARAMETER Metadata
    The full result object from Get-RipperDiscMetadata (has .Candidates,
    .BestMatch, .Status, .DiscId).

.PARAMETER OnResearch
    Optional scriptblock invoked when the user clicks "Re-search
    MusicBrainz". Must return a fresh metadata result of the same shape
    as -Metadata. If not supplied, the button is hidden.

.PARAMETER OnTextSearch
    Optional scriptblock invoked when the user clicks "Search by text…"
    and submits the sub-modal. Receives a hashtable with keys
    Artist, Album, Year, Providers and must return a result of the
    Search-RipperMetadataByText shape (with .Candidates). If not
    supplied, the button is hidden.

.PARAMETER TextSearchProviders
    Names of providers (string[]) to render as checkboxes inside the
    text-search sub-modal. Typically the output of
    Get-RipperTextSearchProviderNames. Empty/null hides the
    "Search by text…" button.

.PARAMETER EjectAfterRip
    Phase 5.4. Initial state of the "Eject disc when done" checkbox in
    the action-button row. Default $true matches the historical
    parent-friendly batch behaviour. Returned on the result object as
    .EjectAfterRip so the caller can honour the user's per-rip choice.

.PARAMETER OnPickCover
    Phase 5.3. Optional scriptblock invoked when the user clicks
    "Change cover…". Receives the currently-viewed candidate and must
    return an array of cover-art responses
    (@{Source; Bytes; Url; Diagnostic}), typically the output of
    Get-RipperCoverArtCandidates. If the user picks one, the main
    dialog updates its cover preview and stashes the new bytes on
    the candidate's .CoverArtBytes. If not supplied, the button is
    hidden.

.EXAMPLE
    PS> $r = Show-RipperMetadataDialog -Metadata $meta
    PS> if ($r.Action -eq 'Rip') { Invoke-Rip -Metadata $r.Metadata }
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Metadata,

        [scriptblock]$OnResearch,

        [scriptblock]$OnTextSearch,

        [string[]]$TextSearchProviders,

        [bool]$EjectAfterRip = $true,

        [scriptblock]$OnPickCover
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
              Width="220" Height="220" HorizontalAlignment="Left" VerticalAlignment="Top"
              SnapsToDevicePixels="True" UseLayoutRounding="True">
        <Image x:Name="CoverImage" Stretch="Uniform"
               RenderOptions.BitmapScalingMode="HighQuality"
               SnapsToDevicePixels="True" UseLayoutRounding="True"/>
      </Border>
      <Button Grid.Column="0" x:Name="PickCoverButton" Content="Change cover…"
              HorizontalAlignment="Left" VerticalAlignment="Top" Width="220" Margin="0,226,0,0"
              Padding="8,4"
              ToolTip="Look up cover art from every configured provider and pick a different one. The current cover stays selected unless you Use one."/>
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
          <Button x:Name="ResearchButton"   Content="Re-search MusicBrainz"
                  DockPanel.Dock="Right" Padding="8,2" Margin="6,0,0,0"/>
          <Button x:Name="TextSearchButton" Content="Search by text…"
                  DockPanel.Dock="Right" Padding="8,2" Margin="6,0,0,0"
                  ToolTip="Look up an artist+album by text across the configured metadata providers."/>
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
      <CheckBox x:Name="EjectCheck" Content="Eject disc when done" DockPanel.Dock="Right"
                VerticalAlignment="Center" Margin="0,0,16,0"
                ToolTip="Uncheck to keep the tray closed after the rip / review / cancel finishes. Default comes from your config.json EjectAfterRip setting."/>
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
        'CoverImage','StatusText','CandidateCombo','ResearchButton','TextSearchButton','DiscIdText',
        'AlbumBox','ArtistBox','YearBox','CompilationBox','TracksGrid',
        'RipButton','ReviewButton','CancelButton','ActionHint','EjectCheck','PickCoverButton'
    )) {
        $controls[$name] = $window.FindName($name)
    }
    $controls.EjectCheck.IsChecked = [bool]$EjectAfterRip

    if (-not $OnResearch)   { $controls.ResearchButton.Visibility   = 'Collapsed' }
    if (-not $OnTextSearch -or -not $TextSearchProviders -or @($TextSearchProviders).Count -eq 0) {
        $controls.TextSearchButton.Visibility = 'Collapsed'
    }
    if (-not $OnPickCover)  { $controls.PickCoverButton.Visibility = 'Collapsed' }

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
        Metadata        = $Metadata
        ViewModels      = @()       # parallel to Metadata.Candidates
        CurrentVm       = $null
        Result          = $null     # set by button handlers
        # Per-session cache for the "Search by text..." sub-modal so the
        # user can re-open it and find their previous criteria + results
        # intact. Hashtable shape: see Show-RipperTextSearchDialog
        # -CachedState parameter.
        TextSearchCache = $null
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
        # Reflect the picked candidate's provider in the status strip so
        # the user always sees which source the currently-selected match
        # came from (especially after a text-search appends a new row
        # with a different .Source than the original disc-id pick).
        $src = if ($vm.Source -and $vm.Source.PSObject.Properties['Source'] -and $vm.Source.Source) {
            [string]$vm.Source.Source
        } else { 'unknown source' }
        $controls.StatusText.Text = "Selected match from $src."
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
    # Report which source(s) fed the candidate list so Phase 5.2's
    # provider chain is visible to the user (a GnuDB match used to
    # label itself "Single MusicBrainz match" — confusing).
    $sourceLabel = 'MusicBrainz'
    if (@($state.Metadata.Candidates).Count -gt 0) {
        $srcs = @($state.Metadata.Candidates |
                  Where-Object { $_.PSObject.Properties['Source'] -and $_.Source } |
                  ForEach-Object { [string]$_.Source } |
                  Select-Object -Unique)
        if ($srcs.Count -gt 0) { $sourceLabel = $srcs -join ' / ' }
    }
    $statusText = switch ($state.Metadata.Status) {
        'Match'       { "Single $sourceLabel match." }
        'MultiMatch'  { "$(@($state.Metadata.Candidates).Count) matches from $sourceLabel — pick one." }
        'NoMatch'     { 'No metadata match for this disc.' }
        'Offline'     { 'All metadata providers offline — placeholder shown.' }
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

    $controls.TextSearchButton.Add_Click({
        try {
            $controls.TextSearchButton.IsEnabled = $false
            # Seed the modal with the user's current AlbumArtist/Album/Year
            # edits — it's the obvious starting point ("the disc-id pick
            # was wrong, but I know roughly what it should say"). On
            # subsequent invocations within the same session, pass the
            # cached state so the user sees their previous results and
            # criteria intact (and can refine and re-search).
            $textResult = Show-RipperTextSearchDialog `
                -Owner       $window `
                -Providers   $TextSearchProviders `
                -OnSearch    $OnTextSearch `
                -InitialArtist ([string]$controls.ArtistBox.Text) `
                -InitialAlbum  ([string]$controls.AlbumBox.Text) `
                -InitialYear   ([string]$controls.YearBox.Text) `
                -CachedState   $state.TextSearchCache
            # Always update the session cache (even on cancel) so the
            # criteria the user typed survives until the dialog closes.
            if ($textResult -and $textResult.LastSearch) {
                $state.TextSearchCache = $textResult.LastSearch
            }
            $picked = if ($textResult) { $textResult.Picked } else { $null }
            if ($picked) {
                # Append the picked candidate to the existing list (we want
                # the disc-id matches to remain visible alongside) and
                # re-render the dropdown with the new entry selected.
                $existing = @($state.Metadata.Candidates)
                $merged   = $existing + @($picked)
                $state.Metadata = [pscustomobject]@{
                    DiscId          = $state.Metadata.DiscId
                    Status          = $state.Metadata.Status
                    BestMatch       = $picked
                    Candidates      = $merged
                    ProviderResults = if ($state.Metadata.PSObject.Properties['ProviderResults']) { $state.Metadata.ProviderResults } else { @() }
                }
                & $rebuildViewModels
                & $populateCombo
                $newIdx = $controls.CandidateCombo.Items.Count - 1
                if ($newIdx -ge 0) { $controls.CandidateCombo.SelectedIndex = $newIdx }
                $controls.RipButton.IsEnabled = $true
            }
        } catch {
            [System.Windows.MessageBox]::Show("Text search failed:`n$($_.Exception.Message)",
                'MusicRipper', 'OK', 'Warning') | Out-Null
        } finally {
            $controls.TextSearchButton.IsEnabled = $true
        }
    }.GetNewClosure())

    $controls.PickCoverButton.Add_Click({
        try {
            $controls.PickCoverButton.IsEnabled = $false
            $vm = $state.CurrentVm
            if (-not $vm) { return }
            # Current in-memory cover bytes (may have been swapped by a
            # prior PickCover invocation) get shown as "(current)" so the
            # user can always compare before committing.
            $currentBytes = $null
            if ($vm.Source -and ($vm.Source.PSObject.Properties.Name -contains 'CoverArtBytes') -and $vm.Source.CoverArtBytes) {
                $currentBytes = [byte[]]$vm.Source.CoverArtBytes
            }
            $picked = Show-RipperCoverArtPicker `
                -Owner        $window `
                -Candidate    $vm.Source `
                -OnLookup     $OnPickCover `
                -CurrentBytes $currentBytes
            if ($picked -and $picked.Bytes) {
                # Stash on the underlying candidate so convertFrom picks it
                # up, and refresh the visible preview immediately.
                $vm.Source | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue ([byte[]]$picked.Bytes) -Force
                & $bindCoverArt $vm.Source
            }
        } catch {
            [System.Windows.MessageBox]::Show("Cover-art picker failed:`n$($_.Exception.Message)",
                'MusicRipper', 'OK', 'Warning') | Out-Null
        } finally {
            $controls.PickCoverButton.IsEnabled = $true
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
            Action        = 'Rip'
            Metadata      = & $convertFrom -ViewModel $state.CurrentVm
            EjectAfterRip = [bool]$controls.EjectCheck.IsChecked
        }
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $controls.ReviewButton.Add_Click({
        & $applyEditsToCurrentVm
        $state.Result = [pscustomobject]@{
            Action        = 'Review'
            Metadata      = & $convertFrom -ViewModel $state.CurrentVm
            EjectAfterRip = [bool]$controls.EjectCheck.IsChecked
        }
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $controls.CancelButton.Add_Click({
        $state.Result = [pscustomobject]@{ Action = 'Cancel'; Metadata = $null; EjectAfterRip = [bool]$controls.EjectCheck.IsChecked }
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    $window.Add_Closing({
        # If the user X'd out without using a button, treat as Cancel.
        if (-not $state.Result) {
            $state.Result = [pscustomobject]@{ Action = 'Cancel'; Metadata = $null; EjectAfterRip = [bool]$controls.EjectCheck.IsChecked }
        }
    }.GetNewClosure())

    [void]$window.ShowDialog()
    return $state.Result
}
