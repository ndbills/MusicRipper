<#
.SYNOPSIS
    Phase 7: single self-contained installer for MusicRipper. Copies (or
    keeps) the repo on the local box, chains the setup scripts in order,
    and ends with a "you're ready" prompt.

.DESCRIPTION
    Two modes:
      * Default ("parent" mode): copies the current folder layout into
        $env:LOCALAPPDATA\MusicRipper\ and runs the setup chain from
        there. Designed for a parent's PC -- they ran a single .ps1
        from a USB stick or a downloaded zip and want it to "just
        work."
      * -InPlace: assumes the engineer has cloned the repo and just
        wants the setup chain run against the current location. No
        copy.

    Setup chain (each step is idempotent; failures abort with a clear
    message):
      1. setup\Install-Dependencies.ps1   (winget: PS7, CUETools, Xiph.FLAC,
                                           Picard, WireGuard)
      2. setup\Install-Shortcut.ps1       (Desktop "Rip a CD" shortcut)
      3. Final notice: "open the shortcut to finish first-run config in
         the WPF settings editor (Phase 6.6)."

    What this script intentionally does NOT do:
      * Run the WPF first-run config dialog itself. That's the job of
        Start-Ripper.ps1 the first time the parent clicks the shortcut
        (Phase 6.6.C). Doing it here would force the parent through the
        config flow before the dependencies were even visible on disk,
        and we'd lose the elevated/non-elevated separation.
      * Run setup\Register-Drive.ps1 directly. The drive picker is now
        in the WPF config dialog (Phase 6.6.E); the headless script
        survives only as a fallback.
      * Auto-elevate. The dependencies install needs admin, but we let
        winget itself prompt rather than re-launching ourselves with
        Start-Process -Verb RunAs (which would lose the working
        directory and the user-visible output).

    Exit codes:
        0  success
        1  setup chain aborted (user cancelled / dependency failure)
        2  source copy failed (in default mode)

.PARAMETER InstallRoot
    Where to copy the repo in default mode. Defaults to
    $env:LOCALAPPDATA\MusicRipper. Ignored under -InPlace.

.PARAMETER InPlace
    Skip the copy and run the setup chain against the folder this
    script lives in. Engineer convenience.

.PARAMETER SkipDependencies
    Don't run setup\Install-Dependencies.ps1. Useful when the engineer
    has CUETools / FLAC / Picard already installed and just wants the
    shortcut.

.PARAMETER SkipShortcut
    Don't run setup\Install-Shortcut.ps1. Useful for headless setups.

.PARAMETER Force
    Allow -InstallRoot to overwrite an existing folder by removing it
    first. Without -Force, an existing target throws.

.EXAMPLE
    PS> .\Install-MusicRipper.ps1
    Parent mode: copy this folder to %LOCALAPPDATA%\MusicRipper, install
    deps, place the desktop shortcut. Done.

.EXAMPLE
    PS> .\Install-MusicRipper.ps1 -InPlace
    Engineer mode: just chain the setup scripts against the current
    clone. No copy.

.EXAMPLE
    PS> .\Install-MusicRipper.ps1 -InstallRoot 'D:\Apps\MusicRipper' -Force
    Custom install root, replacing whatever's already there.

.NOTES
    Idempotent. Re-running on a system that already has the install
    will refresh the file copy + re-invoke winget (no-op for
    already-installed packages) + re-create the shortcut.

    See plan.md Phase 7 item 4.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'MusicRipper'),

    [switch] $InPlace,

    [switch] $SkipDependencies,
    [switch] $SkipShortcut,
    [switch] $Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# --- helpers --------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[!!] $Message" -ForegroundColor Red
}

function Invoke-SetupStep {
    <#
    .SYNOPSIS
        Run a setup script in-process, surface failures with a
        descriptive prefix, abort the installer on non-zero $LASTEXITCODE
        OR a thrown exception. Honours $WhatIfPreference -- when
        WhatIf is in effect, prints the planned invocation and skips
        the actual call (so winget doesn't fire and Install-Shortcut
        doesn't drop a real .lnk on the Desktop during a dry-run).
    #>
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $Description,
        [object[]] $ScriptArgs = @()
    )
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Setup script not found: $ScriptPath"
    }
    Write-Step $Description
    if ($WhatIfPreference) {
        Write-Host "What if: would run '$ScriptPath'" -ForegroundColor DarkYellow
        Write-Ok "$Description (skipped under -WhatIf)"
        return
    }
    try {
        & $ScriptPath @ScriptArgs
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Setup script '$ScriptPath' exited with code $LASTEXITCODE."
        }
        Write-Ok $Description
    } catch {
        Write-Fail "$Description failed: $($_.Exception.Message)"
        throw
    }
}


# --- 0. Resolve source root -----------------------------------------------
# This script must live at the repo root next to setup\, src\, etc., so
# $PSScriptRoot is the repo root.
$sourceRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'setup') -PathType Container)) {
    throw "Install-MusicRipper.ps1 must live at the MusicRipper repo root (a 'setup\' folder must be a sibling). Got source root: $sourceRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'src\Start-Ripper.ps1') -PathType Leaf)) {
    throw "src\Start-Ripper.ps1 not found under '$sourceRoot'. Layout looks broken."
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor DarkCyan
Write-Host ' MusicRipper installer' -ForegroundColor DarkCyan
Write-Host '================================================================' -ForegroundColor DarkCyan
Write-Host "Source: $sourceRoot"

# --- 1. Copy (default mode) or stay in place -----------------------------
if ($InPlace) {
    Write-Host 'Mode  : in-place (no copy)'
    $repoRoot = $sourceRoot
} else {
    Write-Host "Target: $InstallRoot"

    if ($PSCmdlet.ShouldProcess($InstallRoot, "Copy MusicRipper from '$sourceRoot'")) {
        try {
            if (Test-Path -LiteralPath $InstallRoot) {
                if ($Force) {
                    Write-Step "Removing existing '$InstallRoot' (-Force)."
                    # Keep user-data subfolders intact (logs, config.json
                    # under %LOCALAPPDATA%\MusicRipper\config.json -- but
                    # that's a separate file, not under InstallRoot, so
                    # we're safe to nuke the install tree).
                    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
                } else {
                    throw "Install root '$InstallRoot' already exists. Pass -Force to replace, or pick a different -InstallRoot."
                }
            }
            Write-Step "Copying repo into '$InstallRoot'."
            New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

            # Robocopy is the right tool here -- handles long paths,
            # preserves attributes, idempotent, supports /XD /XF for
            # excludes. Exclusions: .git/, tests/manual/ (dev-only repros),
            # any local config artifacts we shouldn't propagate.
            # Note: do NOT pre-quote $sourceRoot / $InstallRoot -- PowerShell
            # quotes arg-array elements automatically when splatting and
            # double-quoting embeds literal quotes that robocopy rejects
            # as 'invalid parameter' (rc=16).
            $rcArgs = @(
                $sourceRoot, $InstallRoot, '/E',
                '/COPY:DAT',
                '/XD', '.git', '.vs', '.vscode',
                '/XF', 'pester-result.txt', 'pester-out.txt', 'testResults.xml', 'results.txt',
                '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP'
            )
            & robocopy.exe @rcArgs | Out-Null
            # robocopy: 0 = no copy needed, 1 = files copied, 2 = extra files,
            # 3 = files copied + extras. >=8 = real failure.
            $rc = $LASTEXITCODE
            if ($rc -ge 8) {
                throw "robocopy exited with code $rc. See robocopy docs for failure detail."
            }
            Write-Ok "Copied repo to '$InstallRoot' (robocopy rc=$rc)."
        } catch {
            Write-Fail "Copy failed: $($_.Exception.Message)"
            exit 2
        }
        $repoRoot = $InstallRoot
    } else {
        # WhatIf path -- the copy didn't happen, so the setup chain's
        # Test-Path check would fail against $InstallRoot. Fall back to
        # $sourceRoot so the chain can validate against real files; the
        # invocation itself is then suppressed by Invoke-SetupStep when
        # $WhatIfPreference is set, and the user sees the planned chain
        # without anything actually running.
        $repoRoot = $sourceRoot
    }
}

# --- 2. Run the setup chain ----------------------------------------------
try {
    if (-not $SkipDependencies) {
        Invoke-SetupStep -ScriptPath (Join-Path $repoRoot 'setup\Install-Dependencies.ps1') `
                         -Description 'Installing dependencies via winget (PS7, CUETools, Xiph.FLAC, Picard, WireGuard)'
    } else {
        Write-Step 'Skipping dependency install (-SkipDependencies).'
    }

    if (-not $SkipShortcut) {
        Invoke-SetupStep -ScriptPath (Join-Path $repoRoot 'setup\Install-Shortcut.ps1') `
                         -Description "Creating Desktop shortcut 'Rip a CD'"
        # Also (re)generate the in-repo "Uninstall MusicRipper.lnk" so
        # it points at the install location's actual absolute path.
        # .lnk files store absolute paths, so a committed shortcut
        # would be stale on any machine that cloned to a different
        # path -- regenerate at install time.
        Invoke-SetupStep -ScriptPath (Join-Path $repoRoot 'setup\Install-UninstallShortcut.ps1') `
                         -Description "Creating in-repo 'Uninstall MusicRipper' shortcut"
    } else {
        Write-Step 'Skipping desktop shortcut (-SkipShortcut).'
    }
} catch {
    Write-Host ''
    Write-Fail 'Setup chain aborted. See message(s) above.'
    Write-Host ''
    Write-Host 'You can re-run Install-MusicRipper.ps1 once the issue is resolved.' -ForegroundColor Yellow
    Write-Host 'Pass -SkipDependencies / -SkipShortcut to skip steps that have already succeeded.' -ForegroundColor Yellow
    exit 1
}


# --- 3. You're ready ------------------------------------------------------
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host ' MusicRipper is ready to use.' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Double-click ' -NoNewline
Write-Host '"Rip a CD"' -ForegroundColor White -NoNewline
Write-Host ' on the Desktop.'
Write-Host '  2. The first launch opens the Settings window (library root,'
Write-Host '     drive registration, optional sync targets).'
Write-Host '  3. After Save, insert a CD and click "Rip".'
Write-Host ''
Write-Host "Install location: $repoRoot"
Write-Host "Logs land under : $env:LOCALAPPDATA\MusicRipper\logs\"
Write-Host ''
exit 0
