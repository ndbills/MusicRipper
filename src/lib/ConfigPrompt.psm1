<#
.SYNOPSIS
    Shared prompt helpers used by setup/New-RipperConfig.ps1 (and the
    Phase 6.6.B WPF config editor) so every "ask the user for a path"
    interaction looks and behaves identically.

.DESCRIPTION
    The core function is `Read-RipperPathPrompt`. It implements the
    convention:
        [<current>] (Enter = keep, 'pick' = browse, '-' to clear)
    or, when no current value is set:
        [(not set)] (Enter = browse, '-' to skip)

    i.e. on a NEW field the default action of pressing Enter is to
    open a folder/file picker -- so a parent doing first-run setup
    is never expected to type a path. On an EXISTING field, Enter
    keeps the current value (matches the rest of the script's idiom).

    `Show-RipperFolderPicker` and `Show-RipperFilePicker` are thin
    wrappers around the Windows Forms FolderBrowserDialog /
    OpenFileDialog. They are factored out so the WPF editor can call
    them directly without going through Read-Host.

.NOTES
    Keep this module dependency-light: it must be importable from a
    bare pwsh -NoProfile setup invocation. No Logging dependency.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Show-RipperFolderPicker {
<#
.SYNOPSIS
    Open a Windows Forms FolderBrowserDialog and return the selected
    folder path, or $null if the user cancelled.

.PARAMETER Description
    Title-bar / description text. Shown in the dialog's title because
    UseDescriptionForTitle is set.

.PARAMETER SeedPath
    Folder to start in. Falls back to %USERPROFILE% when missing/blank
    or when the path doesn't exist on disk.

.PARAMETER ShowNewFolderButton
    Default $true. Set $false to forbid creating a new folder from
    inside the picker (useful when the field semantically must point
    at an existing directory).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Description,
        [string]$SeedPath,
        [bool]$ShowNewFolderButton = $true
    )
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description            = $Description
    $dlg.UseDescriptionForTitle = $true
    $dlg.ShowNewFolderButton    = $ShowNewFolderButton
    $seed = if ($SeedPath -and (Test-Path -LiteralPath $SeedPath)) {
        $SeedPath
    } else {
        [Environment]::GetFolderPath('UserProfile')
    }
    $dlg.SelectedPath = $seed
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    }
    return $null
}

function Show-RipperFilePicker {
<#
.SYNOPSIS
    Open a Windows Forms OpenFileDialog and return the selected file
    path, or $null if the user cancelled.

.PARAMETER Description
    Title-bar text.

.PARAMETER SeedPath
    File or folder to start at. If a file, opens the parent. Falls
    back to %USERPROFILE%.

.PARAMETER FileFilter
    Standard OpenFileDialog filter string, e.g.
    'WireGuard config (*.conf)|*.conf|All files (*.*)|*.*'.
    Defaults to all-files.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Description,
        [string]$SeedPath,
        [string]$FileFilter = 'All files (*.*)|*.*'
    )
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = $Description
    $dlg.Filter = $FileFilter
    $dlg.CheckFileExists = $true
    if ($SeedPath) {
        $seedDir = if (Test-Path -LiteralPath $SeedPath -PathType Leaf) {
            Split-Path -Parent $SeedPath
        } elseif (Test-Path -LiteralPath $SeedPath -PathType Container) {
            $SeedPath
        } else {
            [Environment]::GetFolderPath('UserProfile')
        }
        $dlg.InitialDirectory = $seedDir
    } else {
        $dlg.InitialDirectory = [Environment]::GetFolderPath('UserProfile')
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.FileName
    }
    return $null
}

function Read-RipperPathPrompt {
<#
.SYNOPSIS
    One source of truth for "ask the user for a folder or file" CLI
    prompts in setup/New-RipperConfig.ps1.

.DESCRIPTION
    Behavior:
        - With a current value:
              "<Label> [<current>] (Enter = keep, 'pick' = browse, '-' to clear)"
            Enter        -> keep current
            'pick'       -> open picker, seeded at current
            '-'          -> clear (returns $null) IF -AllowClear; otherwise ignored
            anything else-> use as typed path; warn (but accept) if Test-Path fails
        - With no current value:
              "<Label> [(not set)] (Enter = browse, '-' to skip)"
            Enter or 'pick' -> open picker, seeded at -SeedRoot or %USERPROFILE%
            '-'             -> returns $null IF -AllowClear; otherwise re-prompts
            anything else   -> use as typed path; warn if Test-Path fails

    Returning $null means "no value". Returning a non-empty string
    means "use this path".

.PARAMETER Label
    Human-readable field label, e.g. 'Library root path'.

.PARAMETER Current
    The current value (from existing config), or $null/'' if unset.

.PARAMETER Type
    'Folder' or 'File'. Picks the dialog kind.

.PARAMETER FileFilter
    Optional. Forwarded to Show-RipperFilePicker when -Type File.

.PARAMETER SeedRoot
    Optional. Folder to seed the picker at when no current value.
    Useful for OneDrive (HKCU UserFolder) etc.

.PARAMETER AllowClear
    Default $true. Set $false for required fields (LibraryRoot)
    so '-' is rejected.

.PARAMETER MustExist
    Default $false. When $true, a typed path that does not pass
    Test-Path is rejected (re-prompt). When $false, we WARN but
    accept (matches existing OneDrive behavior -- the sync target
    will fail-fast at runtime with a clearer message).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Label,
        [string]$Current,
        [Parameter(Mandatory)] [ValidateSet('Folder','File')] [string]$Type,
        [string]$FileFilter,
        [string]$SeedRoot,
        [bool]$AllowClear = $true,
        [bool]$MustExist  = $false
    )

    $hasCurrent = -not [string]::IsNullOrWhiteSpace($Current)

    while ($true) {
        $shown = if ($hasCurrent) {
            $clearHint = if ($AllowClear) { ", '-' to clear" } else { '' }
            "$Label [$Current] (Enter = keep, 'pick' = browse$clearHint)"
        } else {
            $clearHint = if ($AllowClear) { ", '-' to skip" } else { '' }
            "$Label [(not set)] (Enter = browse$clearHint)"
        }
        $raw = Read-Host $shown
        $ans = if ($null -eq $raw) { '' } else { $raw.Trim().Trim('"').Trim("'") }

        # Clear / skip
        if ($ans -eq '-') {
            if ($AllowClear) { return $null }
            Write-Host "  '$Label' is required and cannot be cleared." -ForegroundColor Yellow
            continue
        }

        # Enter on existing value -> keep
        if ([string]::IsNullOrEmpty($ans) -and $hasCurrent) { return $Current }

        # Enter on empty value, or explicit 'pick' -> open picker
        if ([string]::IsNullOrEmpty($ans) -or $ans.ToLowerInvariant() -eq 'pick') {
            $seed = if ($hasCurrent) { $Current } else { $SeedRoot }
            $picked = if ($Type -eq 'Folder') {
                Show-RipperFolderPicker -Description "Select $Label" -SeedPath $seed
            } else {
                $filter = if ($PSBoundParameters.ContainsKey('FileFilter')) { $FileFilter } else { 'All files (*.*)|*.*' }
                Show-RipperFilePicker -Description "Select $Label" -SeedPath $seed -FileFilter $filter
            }
            if ($null -ne $picked) {
                Write-Host "  $Label -> $picked" -ForegroundColor Green
                return $picked
            }
            # User cancelled the picker.
            if ($hasCurrent) {
                Write-Host "  $Label kept as: $Current" -ForegroundColor DarkGray
                return $Current
            }
            if ($AllowClear) {
                Write-Host "  $Label left unset." -ForegroundColor DarkGray
                return $null
            }
            # Required + no current + cancelled -> re-prompt.
            Write-Host "  '$Label' is required. Please pick a $Type or type a path." -ForegroundColor Yellow
            continue
        }

        # User typed a path.
        if ($MustExist -and -not (Test-Path -LiteralPath $ans)) {
            Write-Host "  Path '$ans' does not exist on disk. Please try again." -ForegroundColor Yellow
            continue
        }
        if (-not $MustExist -and -not (Test-Path -LiteralPath $ans)) {
            Write-Warning "  $Label '$ans' does not exist on disk yet. Saving anyway."
        }
        return $ans
    }
}

function Write-RipperConfigSection {
<#
.SYNOPSIS
    Print a one-line section banner (and a blank-line separator) to
    visually group related prompts in setup/New-RipperConfig.ps1.

.PARAMETER Title
    Section title, e.g. 'Library', 'Sync targets', 'WireGuard'.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===') -ForegroundColor Cyan
}

Export-ModuleMember -Function `
    Read-RipperPathPrompt, `
    Show-RipperFolderPicker, `
    Show-RipperFilePicker, `
    Write-RipperConfigSection
