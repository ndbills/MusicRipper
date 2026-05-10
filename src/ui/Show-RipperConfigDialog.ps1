<#
.SYNOPSIS
    Phase 6.6.B: WPF tabbed config editor.

.DESCRIPTION
    A single tabbed window that lets a user edit every field in the
    config object. Designed to replace the wall-of-Read-Host wizard
    in setup/New-RipperConfig.ps1 for non-CLI users (and to be the
    first-run hook from Start-Ripper when no config exists).

    Tabs:
      General        LibraryRoot (path+Browse), contactAddress,
                     EjectAfterRip, ContinuousMode,
                     RetryPendingSyncOnStartup. Drive is read-only
                     here -- it's managed by setup/Register-Drive.ps1
                     which probes AccurateRip.
      Metadata       Ordered checkbox list of metadata providers
                     (drives cfg.MetadataProviders order).
      Cover art      Ordered checkbox list of cover-art providers
                     (drives cfg.CoverArtProviders order).
      Sync           Ordered checkbox list of sync targets (drives
                     cfg.SyncTargets), plus per-target paths
                     (OneDriveSyncTargetRoot, SynologyUnc), the
                     credential Set/Clear buttons, the
                     SynologySyncReviewQueue checkbox, and
                     LocalRetention combobox.
      WireGuard      WireGuardTunnelName (no .conf install here --
                     setup/New-RipperConfig still owns the install/
                     SDDL flow), WireGuardAutoToggle,
                     WireGuardKeepAliveBetweenDiscs.

    Returns the saved config object (already persisted via
    Save-RipperConfig) on OK, or $null on Cancel / window close.

    Uses the same dispatcher-unhandled-exception sink pattern as
    Show-BetweenDiscsDialog.

.NOTES
    Phase 6.6 explicit decision: NO live-reload. The contract is
    "save and restart". The Save button persists immediately via
    Save-RipperConfig and shows a toast reminding the user that
    new settings apply the next time MusicRipper runs.

    Reachable from three entry points:
      - Start-Ripper.ps1 first-run (when config.json doesn't exist).
      - Start-Ripper.ps1 no-drive prompt (Phase 6.6.E/F.2 path).
      - src\tools\Show-RipperConfig.ps1 standalone adapter, fronted
        by the "MusicRipper - Settings" Start Menu shortcut
        (F-6 / Phase 8). Safe to launch while the main app is
        running -- main reads config once at startup; saved edits
        apply on the next launch. See DECISIONS.md F-6.

    The pure-logic predicates (`Test-RipperConfigEditorComplete`,
    `Move-RipperConfigEditorListItem`) are exported so the Pester
    suite can cover them without spinning a Window.
#>

Set-StrictMode -Version 3.0

# Load deps. ConfigPrompt gives us the folder/file picker shims
# already used by the CLI (so the Browse buttons match the CLI Enter
# behaviour visually). Config is required for Save + DPAPI helpers.
# ConfigDiscovery feeds the option lists.
$libRoot = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $libRoot 'ConfigPrompt.psd1')    -Force
Import-Module (Join-Path $libRoot 'Config.psd1')          -Force
Import-Module (Join-Path $libRoot 'ConfigDiscovery.psd1') -Force
Import-Module (Join-Path $libRoot 'Wireguard.psd1')       -Force
. (Join-Path $PSScriptRoot 'Show-CredentialDialog.ps1')
. (Join-Path $PSScriptRoot 'Show-RegisterDriveDialog.ps1')


function Test-RipperConfigEditorComplete {
<#
.SYNOPSIS
    Pure predicate: should the OK button be enabled given the current
    in-progress config? Pulled out so tests don't need a Window.

.DESCRIPTION
    -FirstRun       LibraryRoot + non-empty MusicBrainz contact
                    address (email or URL) + at least one sync
                    target selected. These are the irreducible
                    requirements for the rest of the pipeline to
                    even function.
    Otherwise       LibraryRoot + non-empty MusicBrainz contact
                    address. (We let an existing user temporarily
                    blank out sync targets to experiment, but the
                    contact address is required by MusicBrainz on
                    every metadata call -- erasing it would silently
                    break disc identification on the very next rip,
                    so the editor refuses to save it blank.)
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [pscustomobject]$Config,
        [switch]$FirstRun
    )
    if (-not $Config.LibraryRoot)               { return $false }
    if ($Config.LibraryRoot.Trim().Length -eq 0) { return $false }

    # Cross-field rule (applies in BOTH first-run and edit mode):
    # if OneDrive is an enabled sync target, OneDriveSyncTargetRoot
    # must be set, otherwise sync would fail at runtime.
    $st = @($Config.SyncTargets)
    if ($st -contains 'OneDrive') {
        $od = $Config.OneDriveSyncTargetRoot
        if (-not $od -or ([string]$od).Trim().Length -eq 0) { return $false }
    }
    # Same rule for SynologyNAS -- requires the UNC share to be set.
    if ($st -contains 'SynologyNAS') {
        $unc = $Config.SynologyUnc
        if (-not $unc -or ([string]$unc).Trim().Length -eq 0) { return $false }
        # And requires a stored DPAPI credential. The NAS share almost
        # always rejects ambient-session creds (different account on
        # different machines, or no cached login at all), and the most
        # common parent-hand-off failure mode is "sync fails because
        # nobody clicked Set... after entering the UNC path."
        $hasCred = $false
        if ($Config.PSObject.Properties['HasSynologyCredential']) {
            $hasCred = [bool]$Config.HasSynologyCredential
        }
        if (-not $hasCred) { return $false }
    }

    # MusicBrainz contact address is required in both modes -- MB / CTDB /
    # GnuDB all need it on every metadata call, so a blank value would
    # silently break disc identification on the very next rip.
    $contact = if ($Config.PSObject.Properties['contactAddress']) { [string]$Config.contactAddress } else { '' }
    if ([string]::IsNullOrWhiteSpace($contact)) { return $false }

    if (-not $FirstRun) { return $true }

    # First-run-only checks below.
    $st = $Config.SyncTargets
    if (-not $st -or @($st).Count -eq 0) { return $false }
    return $true
}

function Move-RipperConfigEditorListItem {
<#
.SYNOPSIS
    Pure helper: move the item at $Index of $List up (-1) or down
    (+1), clamping at the ends. Returns the new array (does not
    mutate the input).
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object[]]$List,
        [Parameter(Mandatory)] [int]$Index,
        [Parameter(Mandatory)] [ValidateSet(-1,1)] [int]$Direction
    )
    $n = $List.Count
    if ($n -le 1)             { return @($List) }
    if ($Index -lt 0 -or $Index -ge $n) { return @($List) }
    $target = $Index + $Direction
    if ($target -lt 0 -or $target -ge $n) { return @($List) }
    $copy = @($List)
    $tmp  = $copy[$Index]
    $copy[$Index]  = $copy[$target]
    $copy[$target] = $tmp
    return $copy
}

function Get-RipperOrderedCheckboxState {
<#
.SYNOPSIS
    Combine the saved order with the currently-discovered options
    into a single ordered list of @{ Name; Checked } items.

.DESCRIPTION
    The on-disk array is the source of truth for ORDER + CHECKED;
    discovery adds any new option (appended, unchecked) and drops
    any saved name that no longer exists on disk.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Saved,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Available
    )
    $availMap = @{}
    foreach ($a in $Available) { $availMap[$a] = $true }
    $out = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $seen = @{}
    foreach ($name in $Saved) {
        if ($availMap.ContainsKey($name) -and -not $seen.ContainsKey($name)) {
            $out.Add([pscustomobject]@{ Name = $name; Checked = $true })
            $seen[$name] = $true
        }
    }
    foreach ($name in $Available) {
        if (-not $seen.ContainsKey($name)) {
            $out.Add([pscustomobject]@{ Name = $name; Checked = $false })
            $seen[$name] = $true
        }
    }
    return @($out)
}


function Invoke-RipperConfigCheckboxRebuild {
<#
.SYNOPSIS
    Internal: render an ItemsControl's children from $StateRef.Value
    (an array of @{ Name; Checked } entries). Each row gets a
    CheckBox + an Up button + a Down button. Re-invoked on every
    reorder so positional captures (`$localIndex`) line up with the
    new order.

.DESCRIPTION
    Lifted to a real top-level function rather than an in-function
    scriptblock because dispatcher click closures captured via
    GetNewClosure() can't reliably resolve a sibling local
    scriptblock variable when invoked later (the scope is gone by
    the time the user clicks Up/Down). A named function sits in the
    script's command lookup table forever, so the closures find it.

.PARAMETER StateRef
    A pscustomobject with a single `Value` property holding the
    array of @{ Name; Checked } entries. Wrapped so the click
    closures can reassign the array (Move-RipperConfigEditorListItem
    returns a new array).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ItemsControl,
        [Parameter(Mandatory)] [pscustomobject]$StateRef
    )

    $ItemsControl.Items.Clear()
    $stateRef = $StateRef    # alias so closures match the local name
    for ($i = 0; $i -lt $stateRef.Value.Count; $i++) {
        $entry  = $stateRef.Value[$i]
        $row    = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,2,0,2'
        $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = 'Auto'
        $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = '*'
        $col3 = New-Object System.Windows.Controls.ColumnDefinition; $col3.Width = 'Auto'
        $col4 = New-Object System.Windows.Controls.ColumnDefinition; $col4.Width = 'Auto'
        $row.ColumnDefinitions.Add($col1); $row.ColumnDefinitions.Add($col2)
        $row.ColumnDefinitions.Add($col3); $row.ColumnDefinitions.Add($col4)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content   = $entry.Name
        $cb.IsChecked = [bool]$entry.Checked
        $cb.VerticalAlignment = 'Center'
        $cb.Margin    = '4,0,0,0'
        $localIndex   = $i
        $cb.Add_Checked({   $stateRef.Value[$localIndex].Checked = $true  }.GetNewClosure())
        $cb.Add_Unchecked({ $stateRef.Value[$localIndex].Checked = $false }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $row.Children.Add($cb) | Out-Null

        $itemsControl = $ItemsControl   # closure-captured alias
        $up = New-Object System.Windows.Controls.Button
        $up.Content = [char]0x25B2  # ▲
        $up.Width = 28; $up.Height = 22; $up.Margin = '6,0,2,0'
        $up.ToolTip = "Move '$($entry.Name)' up"
        $up.Add_Click({
            $stateRef.Value = Move-RipperConfigEditorListItem -List $stateRef.Value -Index $localIndex -Direction -1
            Invoke-RipperConfigCheckboxRebuild -ItemsControl $itemsControl -StateRef $stateRef
        }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($up, 2)
        $row.Children.Add($up) | Out-Null

        $down = New-Object System.Windows.Controls.Button
        $down.Content = [char]0x25BC  # ▼
        $down.Width = 28; $down.Height = 22; $down.Margin = '0,0,4,0'
        $down.ToolTip = "Move '$($entry.Name)' down"
        $down.Add_Click({
            $stateRef.Value = Move-RipperConfigEditorListItem -List $stateRef.Value -Index $localIndex -Direction 1
            Invoke-RipperConfigCheckboxRebuild -ItemsControl $itemsControl -StateRef $stateRef
        }.GetNewClosure())
        [System.Windows.Controls.Grid]::SetColumn($down, 3)
        $row.Children.Add($down) | Out-Null

        $ItemsControl.Items.Add($row) | Out-Null
    }
}


function Get-RipperConfigChanges {
<#
.SYNOPSIS
    Phase 6.4.4: compute a list of human-readable per-field change
    descriptions between two config snapshots. Used by the WPF Save
    handler to log what actually changed.

.DESCRIPTION
    Iterates the union of property names on $Before and $After and
    returns one string per field whose value differs. Arrays are
    compared element-by-element after stringification (the order
    matters for SyncTargets / MetadataProviders / CoverArtProviders).
    null vs empty-string is treated as no-change; both are "no value
    set." Null-to-array-or-vice-versa is reported. Returns an empty
    array when nothing changed.

    NOT a generic deep-diff: only top-level NoteProperty fields are
    walked, which is exactly what the WPF dialog mutates. Matches
    the field set persisted by Save-RipperConfig.

.PARAMETER Before
    The pre-edit snapshot (clone via `$cfg | ConvertTo-Json -Depth 10
    | ConvertFrom-Json` at dialog open time).

.PARAMETER After
    The post-edit snapshot (the live $cfg after $applyToCfg).
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Before,
        [Parameter(Mandatory)] $After
    )

    $changes = New-Object System.Collections.Generic.List[string]
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $Before.PSObject.Properties) { [void]$names.Add($p.Name) }
    foreach ($p in $After.PSObject.Properties)  { [void]$names.Add($p.Name) }

    foreach ($name in ($names | Sort-Object)) {
        # Read property values WITHOUT routing through an if-expression:
        # PowerShell's pipeline unrolls single-element arrays returned
        # by an if-expression, which would silently turn @('MusicBrainz')
        # into the bare string 'MusicBrainz' and then "$bIsArr" below
        # would be false. Two-step assignment (init to $null, set
        # via .Value if the property exists) preserves the original
        # shape because the assignment is a simple expression, not a
        # pipeline.
        $bRaw = $null
        $aRaw = $null
        $bProp = $Before.PSObject.Properties[$name]
        $aProp = $After.PSObject.Properties[$name]
        if ($bProp) { $bRaw = $bProp.Value }
        if ($aProp) { $aRaw = $aProp.Value }

        # Normalize "no value" so null <-> '' isn't reported as a change.
        $bIsEmpty = ($null -eq $bRaw) -or ($bRaw -is [string] -and [string]::IsNullOrEmpty($bRaw))
        $aIsEmpty = ($null -eq $aRaw) -or ($aRaw -is [string] -and [string]::IsNullOrEmpty($aRaw))
        if ($bIsEmpty -and $aIsEmpty) { continue }

        # Arrays: stringify with a stable join so order changes are detected.
        $bIsArr = $bRaw -is [System.Collections.IEnumerable] -and -not ($bRaw -is [string])
        $aIsArr = $aRaw -is [System.Collections.IEnumerable] -and -not ($aRaw -is [string])
        if ($bIsArr -or $aIsArr) {
            $bStr = if ($bIsArr) { '[' + (@($bRaw) -join ', ') + ']' } elseif ($bIsEmpty) { '<unset>' } else { [string]$bRaw }
            $aStr = if ($aIsArr) { '[' + (@($aRaw) -join ', ') + ']' } elseif ($aIsEmpty) { '<unset>' } else { [string]$aRaw }
            if ($bStr -ne $aStr) { $changes.Add("${name}: $bStr -> $aStr") }
            continue
        }

        # Scalars (string / int / bool). Compare via -ne after string cast.
        $bStr = if ($bIsEmpty) { '<unset>' } else { [string]$bRaw }
        $aStr = if ($aIsEmpty) { '<unset>' } else { [string]$aRaw }
        if ($bStr -ne $aStr) {
            $changes.Add("${name}: $bStr -> $aStr")
        }
    }

    return [string[]]@($changes)
}


function Show-RipperConfigDialog {
<#
.SYNOPSIS
    Open the Phase 6.6.B WPF config editor.

.PARAMETER Config
    The starting config object. If omitted, a fresh
    `New-RipperConfigObject -LibraryRoot ''` is used (intended for
    the first-run path).

.PARAMETER FirstRun
    Tightens the OK-enable predicate (see
    Test-RipperConfigEditorComplete) and changes the title bar.

.PARAMETER ConfigPath
    Override the on-disk save destination. Tests use this.

.OUTPUTS
    The saved config object on OK, or $null on Cancel.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [pscustomobject]$Config,
        [switch]$FirstRun,
        [string]$ConfigPath
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null

    if (-not $Config) {
        $Config = New-RipperConfigObject -LibraryRoot ' '
        $Config.LibraryRoot = ''
    }

    # Working copy so Cancel really cancels. Start from a fresh
    # default so any field added after the on-disk file was last
    # written gets a sane value (older configs predate WG /
    # RetryPendingSyncOnStartup / etc -- under StrictMode 3 a missing
    # property read throws). Then overlay every field that *is*
    # present in $Config so the user's choices win.
    # NB: New-RipperConfigObject's -LibraryRoot is [Mandatory] and
    # rejects '', so we seed with a single space then blank it.
    $cfg = New-RipperConfigObject -LibraryRoot ' '
    $cfg.LibraryRoot = ''
    foreach ($p in $Config.PSObject.Properties) {
        if ($cfg.PSObject.Properties[$p.Name]) {
            $cfg.($p.Name) = $p.Value
        } else {
            Add-Member -InputObject $cfg -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
        }
    }

    $availMeta = @(Get-RipperAvailableMetadataProviders)
    $availArt  = @(Get-RipperAvailableCoverArtProviders)
    $availSync = @(Get-RipperAvailableSyncTargets)

    # Initial ordered states.
    $stateMeta = Get-RipperOrderedCheckboxState -Saved (@($cfg.MetadataProviders))   -Available $availMeta
    $stateArt  = Get-RipperOrderedCheckboxState -Saved (@($cfg.CoverArtProviders))   -Available $availArt
    $stateSync = Get-RipperOrderedCheckboxState -Saved (@($cfg.SyncTargets))         -Available $availSync

    $titleBase = if ($FirstRun) { 'MusicRipper - First-time setup' } else { 'MusicRipper - Settings' }
    $titleEsc  = [System.Security.SecurityElement]::Escape($titleBase)

    # The XAML is intentionally simple: every dynamic widget is named
    # so we can wire it up imperatively below. Per-tab content sits
    # in its own Grid so adding/removing fields later is local.
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$titleEsc"
        Width="780" Height="640"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        MinWidth="640" MinHeight="520">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TabControl Grid.Row="0" x:Name="Tabs">

      <!-- ====================== GENERAL ====================== -->
      <TabItem Header="General">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="14">

            <TextBlock Text="Library root" FontWeight="Bold"/>
            <TextBlock Text="Where ripped albums land. Album folders go in &lt;LibraryRoot&gt;\&lt;Album Artist&gt;\&lt;Album&gt; (Year)\..."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,4"/>
            <Grid Margin="0,0,0,14">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="LibraryRootText" Grid.Column="0" Padding="4"
                       ToolTip="Absolute path to the library root."/>
              <Button  x:Name="LibraryRootBrowse" Grid.Column="1"
                       Content="Browse..." Padding="10,4" Margin="6,0,0,0"
                       ToolTip="Open a folder picker."/>
            </Grid>

            <TextBlock Text="MusicBrainz contact" FontWeight="Bold"/>
            <TextBlock Text="MusicBrainz requires a contact address per their API terms. It is sent only with requests to musicbrainz.org and stays on your machine in config.json. An email address or a URL (e.g., your GitHub profile) both work."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,4"/>
            <TextBox x:Name="ContactText" Padding="4" Margin="0,0,0,14"
                     ToolTip="Email (you@example.com) or URL (https://github.com/yourname)."/>

            <CheckBox x:Name="EjectCheck" Content="Eject the disc after each rip"
                      Margin="0,0,0,8"
                      ToolTip="Default on. The confirm dialog also exposes a per-rip override."/>

            <CheckBox x:Name="ContinuousCheck" Content="Continuous mode (keep running between discs)"
                      Margin="0,0,0,8"
                      ToolTip="Default on. After each disc a between-discs dialog offers Rip Next / Quit."/>

            <CheckBox x:Name="RetryPendingCheck" Content="Retry pending syncs at startup"
                      Margin="0,0,0,14"
                      ToolTip="Default on. Albums whose previous sync didn't finish (e.g. NAS offline) get retried before the first rip."/>

            <Separator Margin="0,4,0,12"/>

            <TextBlock Text="Optical drive" FontWeight="Bold"/>
            <TextBlock x:Name="DriveInfoText"
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,6"/>
            <Button x:Name="RegisterDriveButton" Content="Register drive..."
                    Padding="10,4" HorizontalAlignment="Left"
                    ToolTip="Detect optical drives and look up the AccurateRip read offset."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ====================== METADATA ====================== -->
      <TabItem Header="Metadata">
        <Grid Margin="14">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <StackPanel Grid.Row="0">
            <TextBlock Text="Disc-id metadata providers (in priority order)" FontWeight="Bold"/>
            <TextBlock Text="Tried top-to-bottom for each disc. When two or more match, an extra synthesized 'Merged (...)' candidate is added (earlier providers win on conflict). Drag with the up/down buttons to reorder."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,8"/>
          </StackPanel>

          <Border Grid.Row="1" BorderBrush="#ccc" BorderThickness="1" Padding="6">
            <ItemsControl x:Name="MetaList"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- ====================== COVER ART ====================== -->
      <TabItem Header="Cover art">
        <Grid Margin="14">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <StackPanel Grid.Row="0">
            <TextBlock Text="Cover-art providers (in priority order)" FontWeight="Bold"/>
            <TextBlock Text="First non-empty bytes win. CoverArtArchive needs an MB ReleaseMbid and only fires for MB-derived candidates; iTunesSearch and Deezer fall back to artist+album text search."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,8"/>
          </StackPanel>

          <Border Grid.Row="1" BorderBrush="#ccc" BorderThickness="1" Padding="6">
            <ItemsControl x:Name="ArtList"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- ====================== SYNC ====================== -->
      <TabItem Header="Sync">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="14">

            <TextBlock Text="Sync targets (in invocation order)" FontWeight="Bold"/>
            <TextBlock Text="Each sync target is invoked per album after a successful Library move. 'Stub' is a built-in marker target used for testing. Per-target results land in &lt;LibraryRoot&gt;\.musicripper\sync-state.json."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,8"/>
            <Border BorderBrush="#ccc" BorderThickness="1" Padding="6" Margin="0,0,0,14">
              <ItemsControl x:Name="SyncList"/>
            </Border>

            <TextBlock Text="OneDrive sync target root" FontWeight="Bold"/>
            <TextBlock Text="Required when 'OneDrive' is enabled. Pick a folder inside your OneDrive that albums should be mirrored into."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,4"/>
            <Grid Margin="0,0,0,12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="OneDriveText" Grid.Column="0" Padding="4"
                       ToolTip="Absolute path to a folder inside your OneDrive."/>
              <Button  x:Name="OneDriveBrowse" Grid.Column="1"
                       Content="Browse..." Padding="10,4" Margin="6,0,0,0"/>
            </Grid>

            <TextBlock Text="Synology / NAS UNC path" FontWeight="Bold"/>
            <TextBlock Text="Required when 'SynologyNAS' is enabled. e.g. \\nas\music. Any UNC server works -- the name is historical."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,4"/>
            <TextBox x:Name="SynUncText" Padding="4" Margin="0,0,0,8"
                     ToolTip="UNC path of the share, e.g. \\nas\music."/>

            <CheckBox x:Name="SynRqCheck" Content="Mirror _ReviewQueue/ to the NAS too (reserved -- not yet wired up)"
                      Margin="0,0,0,8" IsEnabled="False"
                      ToolTip="Reserved for a future opt-in; currently unused by the SynologyNAS target."/>

            <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
              <TextBlock x:Name="CredStatusText" VerticalAlignment="Center"
                         Margin="0,0,10,0" FontWeight="Bold"/>
              <Button x:Name="CredSetButton"   Content="Set..."   Padding="10,4" Margin="0,0,6,0"
                      ToolTip="Prompt for a username + password and store it via DPAPI (per-Windows-user, machine-bound)."/>
              <Button x:Name="CredClearButton" Content="Clear"    Padding="10,4"
                      ToolTip="Delete the stored credential so syncs use ambient session credentials."/>
            </StackPanel>

            <TextBlock Text="Local retention after successful sync" FontWeight="Bold"/>
            <TextBlock Text="What to do with the local album folder after every configured sync target reports OK. No-op when no sync targets are configured or any target failed."
                       Foreground="#666" TextWrapping="Wrap" Margin="0,2,0,4"/>
            <ComboBox x:Name="RetentionCombo" Margin="0,0,0,8" Width="320" HorizontalAlignment="Left">
              <ComboBoxItem Content="Keep"                     Tag="Keep"
                            ToolTip="Never touch local files (default)."/>
              <ComboBoxItem Content="Move to _Sent\ when synced" Tag="MoveToSentAfterAllSynced"
                            ToolTip="Move folder to &lt;LibraryRoot&gt;\_Sent\ preserving the artist subdir."/>
              <ComboBoxItem Content="Recycle when synced"      Tag="RecycleAfterAllSynced"
                            ToolTip="Send folder to the Windows Recycle Bin (recoverable)."/>
            </ComboBox>

          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ====================== WIREGUARD ====================== -->
      <TabItem Header="WireGuard">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="14">

            <TextBlock Text="Tunnel" FontWeight="Bold"/>
            <TextBlock TextWrapping="Wrap" Foreground="#666" Margin="0,2,0,4">
              Pick a WireGuard <Bold>.conf</Bold> file. Install registers it as a Windows service
              and grants this user start/stop control (one UAC prompt). Once installed, MusicRipper
              brings the tunnel up only for the duration of each NAS sync.
            </TextBlock>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox  x:Name="WgConfText"   Grid.Column="0" Padding="4"
                        ToolTip="Absolute path to a WireGuard .conf file."/>
              <Button   x:Name="WgConfBrowse" Grid.Column="1"
                        Content="Browse..." Padding="10,4" Margin="6,0,0,0"/>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <Button x:Name="WgInstallBtn" Content="Install / register tunnel..."
                      Padding="10,4" Margin="0,0,8,0"
                      ToolTip="Spawn an elevated helper to register the .conf as a service and grant control. One UAC prompt."/>
              <TextBlock x:Name="WgStatusText" VerticalAlignment="Center"
                         TextWrapping="Wrap" Foreground="#666"/>
            </StackPanel>
            <!-- The underlying schema field is still WireGuardTunnelName.
                 We expose the .conf path in the UI but the bare tunnel stem is what
                 gets persisted. This textbox is kept (read-only-ish) so power users
                 can see what got resolved. -->
            <TextBlock Text="Resolved tunnel name (saved to config)" FontWeight="Bold" Margin="0,4,0,0"/>
            <TextBox x:Name="WgTunnelText" Padding="4" Margin="0,2,0,12"
                     ToolTip="Bare tunnel name (.conf filename without extension). Auto-filled when you pick a .conf; you can also type it directly if the tunnel was installed elsewhere."/>

            <CheckBox x:Name="WgAutoCheck" Content="Auto-toggle tunnel around NAS syncs"
                      Margin="0,0,0,8"
                      ToolTip="Master switch. When off, MusicRipper never starts/stops the tunnel (e.g. always-on VPN)."/>

            <CheckBox x:Name="WgKeepAliveCheck" Content="Keep tunnel up between discs (whole session)"
                      Margin="0,0,0,8"
                      ToolTip="When off (default), the tunnel comes up only for the duration of each individual sync. When on, the first sync pins it for the rest of the session and it's torn down at exit."/>

            <CheckBox x:Name="WgPreferDirectCheck" Content="Prefer direct (LAN) connection — only use tunnel when NAS is unreachable"
                      Margin="0,0,0,8"
                      ToolTip="When on (default), MusicRipper probes the NAS share on TCP/445 (~2s timeout) before each sync. If the share answers directly (you're on the home LAN), the tunnel stays down. If the probe fails (timeout, DNS, refused), MusicRipper falls back to bringing the tunnel up. Turn off to always use the tunnel when WireGuardAutoToggle is on."/>

          </StackPanel>
        </ScrollViewer>
      </TabItem>

    </TabControl>

    <!-- ====================== FOOTER ====================== -->
    <Grid Grid.Row="1" Margin="0,10,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="ValidationText" Grid.Column="0"
                 Foreground="#a00" VerticalAlignment="Center"
                 TextWrapping="Wrap" Margin="0,0,10,0"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="CancelButton" Content="Cancel" Width="110" Height="32" Margin="0,0,8,0"
                ToolTip="Discard changes and close."/>
        <Button x:Name="OkButton"     Content="Save"   Width="130" Height="32"
                IsDefault="True" Background="#0a7" Foreground="White" FontWeight="Bold"
                ToolTip="Save to %LOCALAPPDATA%\MusicRipper\config.json. Restart MusicRipper to apply."/>
      </StackPanel>
    </Grid>

  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    Set-RipperWindowIcon $window

    # Topmost-then-clear (Phase 5.11 lesson: pwsh host is minimised).
    # WindowState=Normal in Loaded is a defensive belt against WPF
    # inheriting SW_SHOWMINIMIZED from a parent process that just
    # launched minimised -- bit the F-6 standalone Settings shortcut
    # entry point where the WPF comes up <100 ms after pwsh starts.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.WindowState = [System.Windows.WindowState]::Normal
        $this.Activate() | Out-Null
        $this.Topmost = $false
    }.GetNewClosure())

    # Dispatcher unhandled-exception sink.
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\config-dialog-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex  = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            if ($ex.InnerException) {
                $msg += "`n-- inner: $($ex.InnerException.GetType().FullName): $($ex.InnerException.Message)"
            }
            try {
                $dir = Split-Path -Parent $sidecar
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            } catch {}
        } catch {}
        $e.Handled = $true
    })

    # ---- find named widgets ---------------------------------------
    $libText      = $window.FindName('LibraryRootText')
    $libBrowse    = $window.FindName('LibraryRootBrowse')
    $contactText  = $window.FindName('ContactText')
    $ejectCheck   = $window.FindName('EjectCheck')
    $contCheck    = $window.FindName('ContinuousCheck')
    $retryCheck   = $window.FindName('RetryPendingCheck')
    $driveInfo    = $window.FindName('DriveInfoText')
    $regDriveBtn  = $window.FindName('RegisterDriveButton')

    $metaList     = $window.FindName('MetaList')
    $artList      = $window.FindName('ArtList')
    $syncList     = $window.FindName('SyncList')

    $oneDriveText  = $window.FindName('OneDriveText')
    $oneDriveBrowse= $window.FindName('OneDriveBrowse')
    $synUncText    = $window.FindName('SynUncText')
    $synRqCheck    = $window.FindName('SynRqCheck')
    $credStatus    = $window.FindName('CredStatusText')
    $credSet       = $window.FindName('CredSetButton')
    $credClear     = $window.FindName('CredClearButton')
    $retentionCb   = $window.FindName('RetentionCombo')

    $wgTunnelText  = $window.FindName('WgTunnelText')
    $wgConfText    = $window.FindName('WgConfText')
    $wgConfBrowse  = $window.FindName('WgConfBrowse')
    $wgInstallBtn  = $window.FindName('WgInstallBtn')
    $wgStatusText  = $window.FindName('WgStatusText')
    $wgAutoCheck   = $window.FindName('WgAutoCheck')
    $wgKeepCheck   = $window.FindName('WgKeepAliveCheck')
    $wgPreferDirectCheck = $window.FindName('WgPreferDirectCheck')

    $valText       = $window.FindName('ValidationText')
    $okBtn         = $window.FindName('OkButton')
    $cancelBtn     = $window.FindName('CancelButton')

    # ---- pre-edit snapshot (Phase 6.4.4) --------------------------
    # Clone the config BEFORE any UI seeding mutates it, so the Save
    # handler can diff the post-edit state against this baseline and
    # log only the fields that actually changed. Round-trip through
    # JSON gives us a deep, decoupled copy without dragging in a
    # System.Management.Automation.PSObject reference graph.
    $cfgBefore = $cfg | ConvertTo-Json -Depth 10 | ConvertFrom-Json

    # ---- seed values from $cfg ------------------------------------
    $libText.Text       = if ($cfg.LibraryRoot)            { [string]$cfg.LibraryRoot } else { '' }
    $contactText.Text   = if ($cfg.PSObject.Properties['contactAddress'] -and $cfg.contactAddress) { [string]$cfg.contactAddress } else { '' }
    $ejectCheck.IsChecked  = [bool]$cfg.EjectAfterRip
    $contCheck.IsChecked   = [bool]$cfg.ContinuousMode
    $retryCheck.IsChecked  = [bool]$cfg.RetryPendingSyncOnStartup
    $oneDriveText.Text  = if ($cfg.OneDriveSyncTargetRoot) { [string]$cfg.OneDriveSyncTargetRoot } else { '' }
    $synUncText.Text    = if ($cfg.SynologyUnc)            { [string]$cfg.SynologyUnc } else { '' }
    $synRqCheck.IsChecked  = [bool]$cfg.SynologySyncReviewQueue
    $wgTunnelText.Text  = if ($cfg.WireGuardTunnelName)    { [string]$cfg.WireGuardTunnelName } else { '' }
    $wgAutoCheck.IsChecked = [bool]$cfg.WireGuardAutoToggle
    $wgKeepCheck.IsChecked = [bool]$cfg.WireGuardKeepAliveBetweenDiscs
    # Forward-compat: older configs may not have PreferDirectNasConnection;
    # treat missing as the default (true).
    $wgPreferDirectCheck.IsChecked = if ($cfg.PSObject.Properties['PreferDirectNasConnection']) { [bool]$cfg.PreferDirectNasConnection } else { $true }

    foreach ($it in $retentionCb.Items) {
        if ([string]$it.Tag -eq [string]$cfg.LocalRetention) {
            $retentionCb.SelectedItem = $it
            break
        }
    }
    if (-not $retentionCb.SelectedItem) { $retentionCb.SelectedIndex = 0 }

    $driveLetter = if ($cfg.PSObject.Properties['DriveLetter']) { $cfg.DriveLetter } else { $null }
    $driveOffset = if ($cfg.PSObject.Properties['DriveOffset']) { $cfg.DriveOffset } else { $null }
    $driveInfo.Text = if ($driveLetter) {
        "Drive: $driveLetter   |   AccurateRip offset: $(if ($null -ne $driveOffset) { $driveOffset } else { '(unknown)' })"
    } else {
        "Drive: (not registered yet)"
    }

    # Source of truth is the file on disk -- in first-run mode the
    # cfg defaults to HasSynologyCredential=$false even if a
    # credentials.clixml is left over from a previous install.
    $credPath = Join-Path (Get-RipperConfigRoot) 'credentials.clixml'
    $credOnDisk = Test-Path -LiteralPath $credPath
    if ($credOnDisk -ne [bool]$cfg.HasSynologyCredential) {
        $cfg.HasSynologyCredential = $credOnDisk
    }
    $credStatus.Text = if ($credOnDisk) { "Credential: stored (DPAPI)" } else { "Credential: none stored" }

    # ---- ordered checkbox-list rendering --------------------------
    # Reference wrappers so closures can reassign the array.
    $metaRef = [pscustomobject]@{ Value = $stateMeta }
    $artRef  = [pscustomobject]@{ Value = $stateArt  }
    $syncRef = [pscustomobject]@{ Value = $stateSync }

    Invoke-RipperConfigCheckboxRebuild -ItemsControl $metaList -StateRef $metaRef
    Invoke-RipperConfigCheckboxRebuild -ItemsControl $artList  -StateRef $artRef
    Invoke-RipperConfigCheckboxRebuild -ItemsControl $syncList -StateRef $syncRef

    # ---- Browse buttons -------------------------------------------
    $libBrowse.Add_Click({
        $picked = Show-RipperFolderPicker -Description 'Pick the music library root' -SeedPath $libText.Text
        if ($picked) { $libText.Text = $picked }
    }.GetNewClosure())

    $oneDriveBrowse.Add_Click({
        $seed = if ($oneDriveText.Text -and $oneDriveText.Text.Trim()) {
            $oneDriveText.Text
        } else {
            Get-RipperOneDriveRoot
        }
        $picked = Show-RipperFolderPicker -Description 'Pick a folder inside OneDrive to mirror albums into' -SeedPath $seed
        if ($picked) { $oneDriveText.Text = $picked }
    }.GetNewClosure())

    # ---- Register-drive button ------------------------------------
    # Resolve repo root the same way Start-Ripper does (this file
    # lives in src/ui, so two parents up).
    $regRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $regDriveBtn.Add_Click({
        $curDrive  = if ($cfg.PSObject.Properties['DriveLetter'])  { $cfg.DriveLetter } else { $null }
        $curOffset = if ($cfg.PSObject.Properties['DriveOffset'])  { $cfg.DriveOffset } else { $null }
        $picked = Show-RipperRegisterDriveDialog `
                    -CurrentDrive  $curDrive `
                    -CurrentOffset $curOffset `
                    -RepoRoot      $regRepoRoot `
                    -Owner         $window
        if ($picked) {
            $cfg.DriveLetter = $picked.Drive
            $cfg.DriveOffset = $picked.Offset
            $driveInfo.Text  = "Drive: $($picked.Drive)   |   AccurateRip offset: $($picked.Offset)   (saved on Save)"
            # Phase 6.4.4: log the staged change. The actual persist
            # happens in the Save handler below; this just records
            # what the user picked while the dialog was open.
            Write-RipperLog INFO 'Show-RipperConfigDialog' "Drive registration staged: drive=$($picked.Drive), offset=$($picked.Offset). (Will persist on Save.)"
        }
    }.GetNewClosure())

    # ---- WireGuard tunnel section ---------------------------------
    # Refresh the WgStatusText line based on the bare tunnel name
    # currently in $wgTunnelText. Calls into the Wireguard module
    # which returns 'NotInstalled' / 'Stopped' / 'Running' / etc.
    $refreshWgStatus = {
        $name = $wgTunnelText.Text.Trim()
        if (-not $name) {
            $wgStatusText.Text       = 'No tunnel configured.'
            $wgStatusText.Foreground = '#888'
            return
        }
        try {
            $state = Test-RipperVpnTunnel -Name $name -Detailed
            switch ($state) {
                'NotInstalled' {
                    $wgStatusText.Text       = "Tunnel '$name': NOT installed -- click Install to register it."
                    $wgStatusText.Foreground = '#a60'
                }
                default {
                    $wgStatusText.Text       = "Tunnel '$name': $state."
                    $wgStatusText.Foreground = '#070'
                }
            }
        } catch {
            $wgStatusText.Text       = "Tunnel '$name': status check failed -- $($_.Exception.Message)"
            $wgStatusText.Foreground = '#a00'
        }
    }.GetNewClosure()

    $wgConfBrowse.Add_Click({
        $picked = Show-RipperFilePicker `
                    -Description 'Pick a WireGuard .conf file' `
                    -SeedPath    $wgConfText.Text `
                    -FileFilter  'WireGuard config (*.conf)|*.conf|All files (*.*)|*.*'
        if ($picked) {
            $wgConfText.Text   = $picked
            $wgTunnelText.Text = [System.IO.Path]::GetFileNameWithoutExtension($picked)
            & $refreshWgStatus
        }
    }.GetNewClosure())

    # Re-check status whenever the tunnel name field loses focus
    # (covers manual edits + the Browse-derived auto-fill).
    $wgTunnelText.Add_LostFocus({ & $refreshWgStatus }.GetNewClosure())

    $wgInstallBtn.Add_Click({
        $confPath = $wgConfText.Text.Trim()
        if (-not $confPath) {
            [System.Windows.MessageBox]::Show(
                "Pick a .conf file first using the Browse... button.",
                'MusicRipper', 'OK', 'Information') | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $confPath)) {
            [System.Windows.MessageBox]::Show(
                "The .conf file does not exist:`n`n  $confPath",
                'MusicRipper', 'OK', 'Warning') | Out-Null
            return
        }
        $wgInstallBtn.IsEnabled  = $false
        $wgConfBrowse.IsEnabled  = $false
        $wgStatusText.Text       = 'Launching elevated helper (one UAC prompt)...'
        $wgStatusText.Foreground = '#666'
        try {
            # Synchronous -- the helper script blocks on Read-Host
            # at the end, so the user sees success/failure before
            # this returns.
            $stem = Invoke-RipperVpnTunnelElevatedInstall `
                        -ConfPath $confPath `
                        -RepoRoot $regRepoRoot
            $wgTunnelText.Text       = $stem
            $wgStatusText.Text       = "Tunnel '$stem' installed."
            $wgStatusText.Foreground = '#070'
            & $refreshWgStatus
        } catch {
            [System.Windows.MessageBox]::Show(
                "WireGuard install failed:`n`n  $($_.Exception.Message)",
                'MusicRipper', 'OK', 'Error') | Out-Null
            $wgStatusText.Text       = "Install failed -- see message box."
            $wgStatusText.Foreground = '#a00'
        } finally {
            $wgInstallBtn.IsEnabled = $true
            $wgConfBrowse.IsEnabled = $true
        }
    }.GetNewClosure())

    # Initial status line.
    & $refreshWgStatus

    # ---- Credential buttons ---------------------------------------
    # `$refreshOk` is defined further down -- closures wired here can't
    # see it (locals captured by .GetNewClosure() are snapshotted at
    # define time, not click time). Hashtable-wrapper trick: declare
    # an empty box now, fill it in once $refreshOk exists, deref via
    # $refreshBox.Run inside the closure.
    $refreshBox = @{ Run = $null }
    $credSet.Add_Click({
        try {
            $c = Show-RipperCredentialDialog `
                    -Title   'MusicRipper - NAS credential' `
                    -Message 'Enter the username + password used to mount the NAS share.' `
                    -Owner   $window
            if ($c) {
                Save-RipperCredential -Credential $c
                $cfg.HasSynologyCredential = $true
                $credStatus.Text = "Credential: stored (DPAPI)"
                # Re-evaluate Save eligibility -- the cross-field rule
                # for SynologyNAS now depends on this flag.
                if ($refreshBox.Run) { & $refreshBox.Run }
            }
        } catch {
            [System.Windows.MessageBox]::Show("Failed to save credential: $($_.Exception.Message)", 'MusicRipper', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())

    $credClear.Add_Click({
        try {
            $credPath = Join-Path (Get-RipperConfigRoot) 'credentials.clixml'
            if (Test-Path -LiteralPath $credPath) {
                Remove-Item -LiteralPath $credPath -Force
            }
            $cfg.HasSynologyCredential = $false
            $credStatus.Text = "Credential: none stored"
            # Re-evaluate Save eligibility -- clearing the credential
            # while SynologyNAS is still selected as a sync target now
            # disables Save until the user either re-saves or unchecks
            # the target.
            if ($refreshBox.Run) { & $refreshBox.Run }
        } catch {
            [System.Windows.MessageBox]::Show("Failed to clear credential: $($_.Exception.Message)", 'MusicRipper', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())

    # ---- Validation / OK enable -----------------------------------
    $applyToCfg = {
        # Mutate $cfg in-place from current widget values. Used both
        # by the live OK-enable check and by the final Save.
        $cfg.LibraryRoot                  = $libText.Text.Trim()
        $cfg.contactAddress               = $contactText.Text.Trim()
        $cfg.EjectAfterRip                = [bool]$ejectCheck.IsChecked
        $cfg.ContinuousMode               = [bool]$contCheck.IsChecked
        $cfg.RetryPendingSyncOnStartup    = [bool]$retryCheck.IsChecked
        $cfg.OneDriveSyncTargetRoot       = $(if ($oneDriveText.Text.Trim()) { $oneDriveText.Text.Trim() } else { $null })
        $cfg.SynologyUnc                  = $(if ($synUncText.Text.Trim())  { $synUncText.Text.Trim() }  else { $null })
        $cfg.SynologySyncReviewQueue      = [bool]$synRqCheck.IsChecked
        $cfg.WireGuardTunnelName          = $(if ($wgTunnelText.Text.Trim()) { $wgTunnelText.Text.Trim() } else { $null })
        $cfg.WireGuardAutoToggle          = [bool]$wgAutoCheck.IsChecked
        $cfg.WireGuardKeepAliveBetweenDiscs = [bool]$wgKeepCheck.IsChecked
        $cfg.PreferDirectNasConnection    = [bool]$wgPreferDirectCheck.IsChecked

        $sel = $retentionCb.SelectedItem
        if ($sel) { $cfg.LocalRetention = [string]$sel.Tag }

        $cfg.MetadataProviders = [string[]]@($metaRef.Value | Where-Object Checked | ForEach-Object Name)
        $cfg.CoverArtProviders = [string[]]@($artRef.Value  | Where-Object Checked | ForEach-Object Name)
        $cfg.SyncTargets       = [string[]]@($syncRef.Value | Where-Object Checked | ForEach-Object Name)
    }

    $refreshOk = {
        & $applyToCfg
        $ok = Test-RipperConfigEditorComplete -Config $cfg -FirstRun:$FirstRun
        $okBtn.IsEnabled = $ok
        if ($ok) {
            $valText.Text = ''
        } elseif ($FirstRun) {
            $missing = New-Object System.Collections.Generic.List[string]
            if (-not $cfg.LibraryRoot)                                        { $missing.Add('Library root') }
            $contactVal = if ($cfg.PSObject.Properties['contactAddress']) { [string]$cfg.contactAddress } else { '' }
            if ([string]::IsNullOrWhiteSpace($contactVal))                    { $missing.Add('MusicBrainz contact (email or URL)') }
            if (-not $cfg.SyncTargets -or @($cfg.SyncTargets).Count -eq 0)    { $missing.Add('at least one sync target') }
            if (@($cfg.SyncTargets) -contains 'OneDrive' -and
                (-not $cfg.OneDriveSyncTargetRoot -or
                 ([string]$cfg.OneDriveSyncTargetRoot).Trim().Length -eq 0))  { $missing.Add('OneDrive folder (required by the OneDrive sync target)') }
            if (@($cfg.SyncTargets) -contains 'SynologyNAS' -and
                (-not $cfg.SynologyUnc -or
                 ([string]$cfg.SynologyUnc).Trim().Length -eq 0))             { $missing.Add('Synology UNC path (required by the SynologyNAS sync target)') }
            if (@($cfg.SyncTargets) -contains 'SynologyNAS' -and
                $cfg.SynologyUnc -and
                ([string]$cfg.SynologyUnc).Trim().Length -gt 0 -and
                -not [bool]$cfg.HasSynologyCredential)                        { $missing.Add("Synology credential (click 'Set...' next to the UNC path)") }
            $valText.Text = "Required: " + ($missing -join '; ')
        } else {
            $bits = New-Object System.Collections.Generic.List[string]
            if (-not $cfg.LibraryRoot) { $bits.Add('Library root is required.') }
            $contactVal2 = if ($cfg.PSObject.Properties['contactAddress']) { [string]$cfg.contactAddress } else { '' }
            if ([string]::IsNullOrWhiteSpace($contactVal2)) {
                $bits.Add('MusicBrainz contact (email or URL) is required -- needed on every metadata call.')
            }
            if (@($cfg.SyncTargets) -contains 'OneDrive' -and
                (-not $cfg.OneDriveSyncTargetRoot -or
                 ([string]$cfg.OneDriveSyncTargetRoot).Trim().Length -eq 0)) {
                $bits.Add('OneDrive sync target is enabled -- pick a OneDrive folder.')
            }
            if (@($cfg.SyncTargets) -contains 'SynologyNAS' -and
                (-not $cfg.SynologyUnc -or
                 ([string]$cfg.SynologyUnc).Trim().Length -eq 0)) {
                $bits.Add('SynologyNAS sync target is enabled -- enter the NAS UNC path.')
            }
            if (@($cfg.SyncTargets) -contains 'SynologyNAS' -and
                $cfg.SynologyUnc -and
                ([string]$cfg.SynologyUnc).Trim().Length -gt 0 -and
                -not [bool]$cfg.HasSynologyCredential) {
                $bits.Add("SynologyNAS sync target is enabled -- click 'Set...' under 'NAS credential' to save your NAS username/password.")
            }
            $valText.Text = ($bits -join ' ')
        }
    }

    # Now that $refreshOk is defined, hand it to the early-wired
    # credential-button closures via the hashtable wrapper declared
    # above (they couldn't capture $refreshOk directly because their
    # .GetNewClosure() ran before the variable existed).
    $refreshBox.Run = $refreshOk

    # Wire change events so OK enables/disables live.
    foreach ($tb in @($libText, $contactText, $oneDriveText, $synUncText, $wgTunnelText)) {
        $tb.Add_TextChanged({ & $refreshOk }.GetNewClosure())
    }
    foreach ($cb in @($ejectCheck, $contCheck, $retryCheck, $synRqCheck, $wgAutoCheck, $wgKeepCheck, $wgPreferDirectCheck)) {
        $cb.Add_Checked(  { & $refreshOk }.GetNewClosure())
        $cb.Add_Unchecked({ & $refreshOk }.GetNewClosure())
    }
    $retentionCb.Add_SelectionChanged({ & $refreshOk }.GetNewClosure())
    # Sync-list checkbox toggles also update the predicate; the
    # individual cb.Add_Checked closures already mutate $stateSync,
    # but they need to also call $refreshOk to propagate. Cheapest
    # path: re-render hooks the new cbs via $rebuildList, but we want
    # the OK to refresh too -- so do it after each click via
    # PreviewMouseUp on the items panel.
    $syncList.AddHandler(
        [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
        [System.Windows.RoutedEventHandler]{ & $refreshOk })
    $syncList.AddHandler(
        [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
        [System.Windows.RoutedEventHandler]{ & $refreshOk })

    & $refreshOk

    # ---- OK / Cancel ----------------------------------------------
    # Use a captured hashtable rather than $script:* -- per the
    # repeated WPF closure gotcha, $script:* writes from inside
    # GetNewClosure() handlers in a dot-sourced function don't
    # reliably round-trip back to the function-level read. Locals
    # captured by the closure (like $resultBox here) do.
    $resultBox = @{ Value = $null }
    $okBtn.Add_Click({
        & $applyToCfg
        if (-not (Test-RipperConfigEditorComplete -Config $cfg -FirstRun:$FirstRun)) {
            return
        }
        try {
            if ($ConfigPath) {
                Save-RipperConfig -Config $cfg -Path $ConfigPath
            } else {
                Save-RipperConfig -Config $cfg
            }
            # Phase 6.4.4: log per-field changes vs the pre-edit
            # snapshot so a support diagnostic can see exactly what
            # changed in this Save (and we don't accidentally hide
            # a misconfiguration behind a chatty UI).
            try {
                $changes = Get-RipperConfigChanges -Before $cfgBefore -After $cfg
                if ($changes.Count -eq 0) {
                    Write-RipperLog INFO 'Show-RipperConfigDialog' 'Config saved (no field changes vs pre-edit snapshot).'
                } else {
                    Write-RipperLog INFO 'Show-RipperConfigDialog' "Config saved with $($changes.Count) change(s):"
                    foreach ($line in $changes) {
                        Write-RipperLog INFO 'Show-RipperConfigDialog' "  - $line"
                    }
                }
            } catch {
                # Diff is best-effort; never let a logging hiccup
                # rollback a successful save.
                Write-RipperLog WARN 'Show-RipperConfigDialog' "Config diff log failed (save itself succeeded): $($_.Exception.Message)"
            }
            $resultBox.Value = $cfg
            # F-6: nudge the user that this is a save-and-restart
            # contract. Suppressed in -FirstRun because Start-Ripper
            # immediately enters the rip flow with the just-saved
            # config -- there is no "next launch" to wait for.
            if (-not $FirstRun) {
                [System.Windows.MessageBox]::Show(
                    "Settings saved.`n`nNew settings will apply the next time MusicRipper runs.",
                    'MusicRipper - Settings', 'OK', 'Information') | Out-Null
            }
            $window.DialogResult = $true
            $window.Close()
        } catch {
            [System.Windows.MessageBox]::Show("Failed to save config: $($_.Exception.Message)", 'MusicRipper', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())

    $cancelBtn.Add_Click({
        $resultBox.Value = $null
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    [void]$window.ShowDialog()
    return $resultBox.Value
}
