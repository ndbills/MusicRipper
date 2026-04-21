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

Export-ModuleMember -Function ConvertTo-SafeWindowsPathSegment, Get-RipperRepoRoot, Get-CueToolsPath
