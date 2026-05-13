<#
.SYNOPSIS
    Common helpers shared across MusicRipper scripts.

.DESCRIPTION
    Pipeline position:
        Imported by setup scripts and core scripts. Holds small pure-logic
        utilities that don't deserve their own module — currently just
        Windows-path sanitization and a "find the repo root" helper.

.NOTES
    Anything that grows beyond ~5 functions or grows external deps should be
    extracted to its own module (Config / Logging style).
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Phase 8.3 / D-032 amendment: single source of truth for the
# MusicRipper version string is the `VERSION` file at the repo root
# (sibling to Install-MusicRipper.ps1 + Update-MusicRipper.ps1). The
# auto-updater compares this value against the latest GitHub Release
# tag; cutting a release is now "edit VERSION + commit + gh release
# create vX.Y" with no risk of code/tag mismatch within the commit.
#
# We read it ONCE at module load into $script:RipperVersion. Get-
# RipperVersion returns that cached value -- the file is not re-read
# per call (the running app's reported version is fixed for its
# lifetime, and the auto-updater spawns a fresh helper that re-reads
# anyway).
#
# Fallback: if VERSION is missing or unreadable (dev clone with the
# file deleted, malformed install, etc.) we use '0.0-unknown' which
# Compare-RipperVersion will treat as "always update available" via
# the unparseable-input string-compare path -- safe by construction.

function Read-RipperVersionFromFile {
<#
.SYNOPSIS
    Read a single-line SemVer string from a VERSION file. Returns
    '0.0-unknown' on any failure (missing file, empty, multi-line,
    unreadable).

.DESCRIPTION
    Defensive against:
      - File missing entirely (dev clone with VERSION removed).
      - File empty / whitespace-only (forgot to type the number).
      - Trailing newlines / Windows CRLF line endings (handled by
        .Trim()).
      - Multi-line file (ignore everything past the first non-empty
        line; engineer might have added a comment under the version).

    The fallback '0.0-unknown' is intentionally a SemVer-unparseable
    string so Compare-RipperVersion treats it as "always update
    available" (string-compare path). That's the safer default than
    a numeric like '0.0' which would compare cleanly.

.PARAMETER Path
    Absolute path to the VERSION file.

.OUTPUTS
    [string] the trimmed version string, or '0.0-unknown' on failure.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '0.0-unknown' }
    try {
        $raw = Get-Content -LiteralPath $Path -ErrorAction Stop
        # Get-Content returns string[] for multi-line files, [string]
        # for single-line. Normalize to first non-empty trimmed line.
        $first = @($raw | ForEach-Object { ([string]$_).Trim() } |
                          Where-Object { $_ -ne '' }) | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($first)) { return '0.0-unknown' }
        return $first
    } catch {
        return '0.0-unknown'
    }
}

# Resolve the VERSION file at the repo root. $PSScriptRoot here is
# 'src\lib'; two parents up is the install root.
$script:RipperVersionFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'VERSION'
$script:RipperVersion     = Read-RipperVersionFromFile -Path $script:RipperVersionFile

function Get-RipperVersion {
<#
.SYNOPSIS
    Return the current MusicRipper version string (e.g. '0.1').

.DESCRIPTION
    Sourced from the `VERSION` file at the repo root, read once at
    module load. Used by the metadata providers to compose User-
    Agent headers of the form `MusicRipper/<version> ( <contactAddress> )`,
    AND by Update-MusicRipper.ps1's `Compare-RipperVersion` to decide
    whether to offer an update.

    Cutting a release: edit `VERSION` (single line, e.g. `0.2`),
    commit, push, then `gh release create v0.2 --title "..." --notes "..."`.
    The VERSION-in-code and the git-tag now share a single source
    of truth (the file) and are bumped in the same commit. See
    docs/SETUP.md "Cutting a release".

.EXAMPLE
    PS> Get-RipperVersion
    0.1
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:RipperVersion
}

function ConvertTo-SafeWindowsPathSegment {
<#
.SYNOPSIS
    Sanitize a string for safe use as a Windows file or folder name.

.DESCRIPTION
    Why this exists: MusicBrainz returns titles like
    "Symphony No. 5: III. Allegro / Live at Carnegie Hall (2007)" — the colon
    and slash are illegal on NTFS, and a trailing dot or space causes silent
    failures in the Win32 path APIs. We need a deterministic, lossless-as-
    possible mapping so two runs of the same album produce the same folder
    name (idempotent re-rip).

    Rules applied (in order):
        1. Replace each Windows-illegal char  < > : " / \ | ? *  with a single space.
        2. Replace any control char (U+0000-U+001F) with a single space.
        3. Collapse runs of whitespace to one space.
        4. Trim leading/trailing whitespace.
        5. Strip trailing dots (Windows trims them and breaks idempotency).
        6. If the result is empty or a reserved DOS device name (CON, PRN, AUX,
           NUL, COM1-9, LPT1-9), return '_unknown_' so we never produce an
           unmountable path.

.PARAMETER Name
    The raw string to sanitize.

.EXAMPLE
    PS> ConvertTo-SafeWindowsPathSegment 'AC/DC: Live'
    AC DC  Live

.EXAMPLE
    PS> ConvertTo-SafeWindowsPathSegment 'CON'
    _unknown_

.NOTES
    See: https://learn.microsoft.com/windows/win32/fileio/naming-a-file
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Name
    )
    process {
        if ($null -eq $Name) { return '_unknown_' }

        # Steps 1+2: illegal chars and controls -> space.
        $sb = [System.Text.StringBuilder]::new($Name.Length)
        foreach ($ch in $Name.ToCharArray()) {
            if ('<>:"/\|?*'.Contains($ch) -or [int]$ch -lt 32) {
                [void]$sb.Append(' ')
            } else {
                [void]$sb.Append($ch)
            }
        }
        $s = $sb.ToString()

        # Step 3: collapse whitespace runs.
        $s = ($s -replace '\s+', ' ').Trim()

        # Step 5: strip trailing dots (Windows silently drops them).
        $s = $s.TrimEnd('.', ' ')

        # Step 6: empty or reserved device name -> safe fallback.
        $reserved = @(
            'CON','PRN','AUX','NUL',
            'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
            'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9'
        )
        if ([string]::IsNullOrWhiteSpace($s) -or $reserved -contains $s.ToUpperInvariant()) {
            return '_unknown_'
        }
        $s
    }
}

function Get-RipperRepoRoot {
<#
.SYNOPSIS
    Return the absolute path to the MusicRipper repo root.

.DESCRIPTION
    Walks up from this module file (src/lib/Common.psm1) two levels.
    Used by setup scripts that need to find sibling files
    (e.g. config/config.template.json, data/driveoffsets.cached.json).

.EXAMPLE
    PS> Get-RipperRepoRoot
    C:\bin\MusicRipper
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Get-CueToolsPath {
<#
.SYNOPSIS
    Locate the directory holding the installed CUETools binaries + DLLs.

.DESCRIPTION
    Why this is non-trivial: winget installs CUETools as a *portable*
    package (no Program Files entry, no PATH change), so we have to scan
    %LOCALAPPDATA%\Microsoft\WinGet\Packages\gchudov.CUETools_* for the
    versioned subfolder (e.g. CUETools_2.2.6\). For users who installed
    via the legacy MSI we also check Program Files.

    Returned path is the folder containing CUETools.exe, the .NET DLLs
    used for disc-id reading (CUETools.CDImage.dll, CUETools.Ripper.dll,
    plugins\CUETools.Ripper.SCSI.dll), and the CLI rippers.

.EXAMPLE
    PS> Get-CueToolsPath
    C:\Users\alice\AppData\Local\Microsoft\WinGet\Packages\gchudov.CUETools_Microsoft.Winget.Source_8wekyb3d8bbwe\CUETools_2.2.6

.NOTES
    Throws if CUETools cannot be found anywhere known. Run
    setup/Install-Dependencies.ps1 to (re-)install via winget.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # 1. winget portable install — newest versioned subfolder wins so a future
    #    `winget upgrade` is picked up automatically.
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetRoot) {
        $pkgDirs = Get-ChildItem -LiteralPath $wingetRoot -Directory `
                       -Filter 'gchudov.CUETools*' -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgDirs) {
            # Inside each package dir is exactly one CUETools_<version>\ folder.
            $versioned = Get-ChildItem -LiteralPath $pkg.FullName -Directory `
                            -Filter 'CUETools_*' -ErrorAction SilentlyContinue |
                        Sort-Object Name -Descending |
                        Select-Object -First 1
            if ($versioned -and (Test-Path -LiteralPath (Join-Path $versioned.FullName 'CUETools.exe'))) {
                return $versioned.FullName
            }
        }
    }

    # 2. Legacy MSI install paths (rare today but cheap to check).
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles        'CUE Tools'),
        (Join-Path ${env:ProgramFiles(x86)} 'CUE Tools')
    )) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'CUETools.exe'))) {
            return $candidate
        }
    }

    throw "CUETools not found. Run setup/Install-Dependencies.ps1 to install it."
}

function Get-MetaflacPath {
<#
.SYNOPSIS
    Locate the `metaflac.exe` binary from the Xiph FLAC reference tools.

.DESCRIPTION
    Phase 5 uses metaflac for three things the CUETools .NET DLLs do not
    expose: writing the full Vorbis tag set onto an existing FLAC file,
    embedding cover art as a PICTURE block, and computing ReplayGain
    (`metaflac --add-replay-gain`). See docs/DECISIONS.md D-009.

    The Xiph FLAC tools install location varies by winget package version
    and Windows. We check, in order:

      1. `metaflac.exe` already on PATH (covers MSI installs, manual
         installs, CI runners).
      2. winget portable layout under
         %LOCALAPPDATA%\Microsoft\WinGet\Packages\Xiph.FLAC_*\.
      3. winget linked-symlink under %LOCALAPPDATA%\Microsoft\WinGet\Links.
      4. Standard install directories under Program Files.

.EXAMPLE
    PS> Get-MetaflacPath
    C:\Users\alice\AppData\Local\Microsoft\WinGet\Links\metaflac.exe

.NOTES
    Throws if metaflac cannot be found. Run setup/Install-Dependencies.ps1
    to install the Xiph.FLAC winget package.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # 1. PATH.
    $cmd = Get-Command metaflac.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. winget portable package — recurse the package dir for metaflac.exe.
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetRoot) {
        $pkgDirs = Get-ChildItem -LiteralPath $wingetRoot -Directory `
                       -Filter 'Xiph.FLAC*' -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgDirs) {
            $hit = Get-ChildItem -LiteralPath $pkg.FullName -Recurse -File `
                       -Filter 'metaflac.exe' -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }

    # 3. winget Links symlink dir.
    $linkPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\metaflac.exe'
    if (Test-Path -LiteralPath $linkPath) { return $linkPath }

    # 4. Program Files (in case Xiph.FLAC is ever shipped as a non-portable installer).
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles        'FLAC\metaflac.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'FLAC\metaflac.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    throw "metaflac.exe not found. Run setup/Install-Dependencies.ps1 to install Xiph.FLAC."
}

function Test-RipperDependencies {
<#
.SYNOPSIS
    Probe the third-party tools MusicRipper needs at runtime.

.DESCRIPTION
    Phase 5 wires post-rip stages (tag, ReplayGain, library move, review
    artifacts) that fail mid-flight if `metaflac.exe` or the CUETools .NET
    DLLs aren't installed. We don't want to discover that AFTER an 11
    minute rip, so Start-Ripper calls this BEFORE any disc work and
    offers to run setup/Install-Dependencies.ps1 if anything is missing.

    Probes (idempotent, side-effect-free):
      - CUETools (`Get-CueToolsPath`).
      - Xiph.FLAC's `metaflac.exe` (`Get-MetaflacPath`).

    `flac.exe` is intentionally NOT a hard requirement — it's only used
    by `New-RipperReviewImage` for the optional `_image\<Album>.flac`
    inspection file, and that step degrades gracefully (logs a warning,
    skips the image, returns `$null`).

.OUTPUTS
    Hashtable with:
      Ok      [bool]    — true when nothing is missing.
      Missing [array]   — one PSCustomObject per missing dep, with:
                          Name      (human-readable)
                          WingetId  (for the install prompt)
                          Reason    (the failed-probe error message)

.EXAMPLE
    PS> $deps = Test-RipperDependencies
    PS> if (-not $deps.Ok) { $deps.Missing | Format-Table }
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $missing = @()

    try { Get-CueToolsPath | Out-Null } catch {
        $missing += [pscustomobject]@{
            Name     = 'CUETools'
            WingetId = 'gchudov.CUETools'
            Reason   = $_.Exception.Message
        }
    }

    try { Get-MetaflacPath | Out-Null } catch {
        $missing += [pscustomobject]@{
            Name     = 'Xiph.FLAC (metaflac.exe)'
            WingetId = 'Xiph.FLAC'
            Reason   = $_.Exception.Message
        }
    }

    return @{
        Ok      = ($missing.Count -eq 0)
        Missing = @($missing)
    }
}

function Get-RipperAssetPath {
<#
.SYNOPSIS
    Resolve a path under <repo>\assets\.

.DESCRIPTION
    Convenience over `Join-Path (Get-RipperRepoRoot) 'assets\<name>'`
    that also returns $null when the asset is missing instead of
    throwing -- callers (esp. WPF dialogs setting an icon) can then
    no-op gracefully when the assets folder hasn't been deployed yet.

.PARAMETER Name
    File name (or relative path) under <repo>\assets\, e.g.
    'musicripper.ico' or 'musicripper.png'.

.EXAMPLE
    PS> Get-RipperAssetPath musicripper.ico
    C:\bin\MusicRipper\assets\musicripper.ico
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name
    )
    $path = Join-Path (Get-RipperRepoRoot) (Join-Path 'assets' $Name)
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Set-RipperWindowIcon {
<#
.SYNOPSIS
    Apply the MusicRipper app icon to a WPF Window.

.DESCRIPTION
    Loads a per-size PNG (assets\musicripper-{Size}.png) into a frozen
    BitmapImage and assigns it to `$Window.Icon`. The per-size PNG is
    rendered tightly cropped by setup\Build-Icon.ps1 so the disc fills
    the frame at the requested pixel dimensions -- this looks better
    in the WPF title bar / taskbar than letting WPF pick a frame from
    the multi-resolution .ico (which carries the same bitmap data but
    is sized for shortcut / Explorer use).

    If the requested per-size PNG is missing, falls back to the
    multi-resolution musicripper.ico (Set-RipperWindowIcon -Size 0
    forces the .ico path).

    Designed to be called immediately after `XamlReader.Load` in every
    Show-* dialog. Failures are swallowed (logged at WARN if Logging
    is loaded) so a missing/corrupt asset can never prevent a dialog
    from opening -- the user just sees the default WPF window icon.

    Called from the parent runspace where Common is already imported
    by Start-Ripper. Worker runspaces (RipProgress, PendingSync,
    RegisterDrive) re-Import Common inside their AddScript blocks so
    this function is available there too.

.PARAMETER Window
    The WPF [System.Windows.Window] instance to decorate.

.PARAMETER Size
    Pixel size of the per-size PNG to load. Default 24 (looks well in
    the WPF title bar without being upscaled by the Alt-Tab overlay).
    Pass 0 to force the multi-resolution .ico path.

.EXAMPLE
    PS> $window = [Windows.Markup.XamlReader]::Load($reader)
    PS> Set-RipperWindowIcon $window
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Window,
        [int] $Size = 24
    )
    try {
        # Prefer per-size PNG; fall back to multi-res .ico.
        if ($Size -gt 0) {
            $pngPath = Get-RipperAssetPath ('musicripper-{0}.png' -f $Size)
            if ($pngPath) {
                $img = [System.Windows.Media.Imaging.BitmapImage]::new()
                $img.BeginInit()
                $img.UriSource   = [Uri]::new($pngPath)
                $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $img.EndInit()
                if ($img.CanFreeze) { $img.Freeze() }
                $Window.Icon = $img
                return
            }
        }

        $iconPath = Get-RipperAssetPath 'musicripper.ico'
        if (-not $iconPath) { return }

        # BitmapFrame.Create with the file URI lets WPF pick the best
        # embedded frame per surface (chrome vs Alt-Tab vs taskbar).
        # Freeze so the same instance is safe to share across dialogs
        # and across UI-thread/worker-thread boundaries.
        $uri = [Uri]::new($iconPath)
        $img = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $uri,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        if ($img.CanFreeze) { $img.Freeze() }
        $Window.Icon = $img
    } catch {
        # Never let icon problems sink a dialog. Log if Logging is up.
        if (Get-Command Write-RipperLog -ErrorAction SilentlyContinue) {
            Write-RipperLog -Level WARN -Message "Set-RipperWindowIcon failed: $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function ConvertTo-SafeWindowsPathSegment, Get-RipperRepoRoot, Get-CueToolsPath, Get-MetaflacPath, Test-RipperDependencies, Get-RipperAssetPath, Set-RipperWindowIcon, Get-RipperVersion, Read-RipperVersionFromFile
