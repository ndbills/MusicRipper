<#
.SYNOPSIS
    Phase 8: self-update helpers for MusicRipper. Pure logic + small
    network/filesystem operations that the WPF Show-UpdateDialog
    orchestrates.

.DESCRIPTION
    Why a self-updater (D-032): parents got the install via "Code ->
    Download ZIP" from GitHub, which means there is no `git pull`
    available and no winget package to upgrade. Without a self-
    updater every release would require either (a) the engineer
    physically driving over with a USB stick, or (b) the parent
    being talked through a multi-step zip/extract/copy procedure
    over the phone. This module + the WPF dialog wraps both into
    one clickable shortcut.

    Update strategy ('stage + atomic rename'):
      1. Query the GitHub Releases API for the latest tag. Fall
         back to the `main`-branch zip if no Releases exist yet.
      2. Compare against the local `Get-RipperVersion` (semver).
      3. Download the source zip to %TEMP%\musicripper-update-<guid>\.
      4. Expand-Archive into a sibling folder.
      5. Preserve user-generated files inside the install dir
         (currently just data\driveoffsets.cached.json).
      6. Rename live install to <install>-old-<yyyyMMdd-HHmmss>.
      7. Move extracted top-level folder INTO place at the live
         install path.
      8. Restore preserved files.
      9. Re-run the setup chain (Install-Dependencies +
         Install-Shortcut) so a new release that adds a winget
         package or refreshes shortcut metadata applies cleanly.
     10. Prune old <install>-old-* backups, keeping the most
         recent 2 (so the immediate-prior version is always
         recoverable + one further back as a safety net).

    Why this strategy (vs robocopy-overwrite-in-place): the
    rename gives us an atomic 'old vs new' boundary. If the
    extract/move step fails halfway, the live install dir is
    still missing/renamed, and the apply orchestrator can
    rename the backup back to live -- a known-good rollback
    with no half-state. Robocopy-overwrite would mix the two
    versions on every failure mode and we'd have no recovery.

.NOTES
    Network: anonymous GitHub API + zip download. 60 req/hour
    rate limit on the API; one click per release is well under.
    Public repo so no auth needed.

    All public functions return data + write WARN-level log lines
    on failures. They DO NOT throw -- the WPF orchestrator decides
    how to surface failures to the parent.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Resolve the project's lib root from this file's location so we can
# import siblings without forcing the caller to set up the import
# chain first. Mirrors the pattern in Wireguard.psm1.
#
# NB: NO -Force on these imports. -Force tears down whatever binding
# the caller already had to these modules and rebinds them inside the
# Updater module's scope, which then makes the caller's Start-RipperLog
# / Get-RipperVersion etc. invisible. Plain Import-Module is
# idempotent (no-op when already loaded) which is exactly what we
# want here.
$libRoot = $PSScriptRoot
Import-Module (Join-Path $libRoot 'Logging.psd1')
Import-Module (Join-Path $libRoot 'Common.psd1')

# GitHub repo reference. Constant for now (single-public-repo
# project); if MusicRipper ever gains forks the WPF can pass a
# -Repo override.
$script:RipperGitHubRepo = 'ndbills/MusicRipper'


function Get-RipperInstallRoot {
<#
.SYNOPSIS
    Walk up from a starting path (default = $PSScriptRoot of the
    caller, defaulted to this module's location) until we find a
    directory that looks like a MusicRipper install root.

.DESCRIPTION
    "Looks like a MusicRipper install root" = contains both
    `src\Start-Ripper.ps1` AND `Install-MusicRipper.ps1` at the
    top level. That uniquely identifies the install regardless of
    where on disk it lives (parents have C:\bin\MusicRipper-main\;
    engineer has C:\bin\MusicRipper\; default copy mode lands in
    %LOCALAPPDATA%\MusicRipper\).

.PARAMETER StartPath
    Path to begin the walk from. Defaults to this module's parent
    directory's parent (`...\src\lib\Updater.psm1` -> `...\`).

.OUTPUTS
    [string] absolute install-root path, or $null if none found
    within 5 levels (defensive against runaway walks).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$StartPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

    $cur = $StartPath
    for ($i = 0; $i -lt 5; $i++) {
        if (-not $cur) { return $null }
        $startRipper = Join-Path $cur 'src\Start-Ripper.ps1'
        $installer   = Join-Path $cur 'Install-MusicRipper.ps1'
        if ((Test-Path -LiteralPath $startRipper) -and (Test-Path -LiteralPath $installer)) {
            return $cur
        }
        $parent = Split-Path -Parent $cur
        if ($parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $null
}


function Compare-RipperVersion {
<#
.SYNOPSIS
    Compare a local semver string against a remote (release-tag) semver
    string. Returns 'NewerAvailable', 'UpToDate', or 'LocalAhead'.

.DESCRIPTION
    Tolerates a leading 'v' on either side ('v0.2' == '0.2'). Pads
    missing components to 0 ('0.2' == '0.2.0'). Anything that doesn't
    parse as a 1-3 part dotted integer falls back to a string compare,
    with a WARN log line.

.PARAMETER Local
    The locally-installed version string (typically Get-RipperVersion).

.PARAMETER Remote
    The remote version string (typically a GitHub Release tag).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Local,
        [Parameter(Mandatory)] [string]$Remote
    )

    function Convert-ToVersionTuple([string]$s) {
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        $clean = $s.Trim().TrimStart('v', 'V')
        $parts = $clean.Split('.')
        if ($parts.Count -lt 1 -or $parts.Count -gt 3) { return $null }
        $vals = New-Object 'System.Collections.Generic.List[int]'
        foreach ($p in $parts) {
            $n = 0
            if (-not [int]::TryParse($p, [ref]$n)) { return $null }
            $vals.Add($n)
        }
        while ($vals.Count -lt 3) { $vals.Add(0) }
        return ,$vals.ToArray()
    }

    $lt = Convert-ToVersionTuple $Local
    $rt = Convert-ToVersionTuple $Remote
    if ($null -eq $lt -or $null -eq $rt) {
        Write-RipperLog WARN 'Updater' "Compare-RipperVersion: unparseable input (local='$Local', remote='$Remote'); falling back to string compare."
        if ($Local -eq $Remote) { return 'UpToDate' }
        return 'NewerAvailable'   # safer to suggest update than to silently swallow
    }

    for ($i = 0; $i -lt 3; $i++) {
        if ($rt[$i] -gt $lt[$i]) { return 'NewerAvailable' }
        if ($rt[$i] -lt $lt[$i]) { return 'LocalAhead' }
    }
    return 'UpToDate'
}


function Get-RipperLatestRelease {
<#
.SYNOPSIS
    Return @{ Version; ZipballUrl; Notes; PublishedAt; Source } for
    the latest GitHub Release of MusicRipper. Falls back to the
    main-branch tarball when no Releases exist yet (so day-1 of
    the auto-updater works before the engineer starts cutting
    releases).

.DESCRIPTION
    Source values:
      'Release'  = matched a GitHub Release (Version is the tag,
                   minus a leading 'v').
      'MainBranch' = no Releases yet; ZipballUrl points at
                     https://github.com/<repo>/archive/refs/heads/main.zip
                     and Version is set to a synthetic 'main-<short-sha>'
                     so Compare-RipperVersion always reports
                     NewerAvailable for it (string-compare path).

.PARAMETER Repo
    GitHub 'owner/repo' string. Defaults to ndbills/MusicRipper.

.PARAMETER TimeoutSec
    HTTP timeout for both API + zip-info requests. Default 15s.

.OUTPUTS
    Hashtable on success; $null on network error (WARN log line).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Repo = $script:RipperGitHubRepo,
        [int]$TimeoutSec = 15
    )

    $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $resp = Invoke-RestMethod -Uri $apiUrl -TimeoutSec $TimeoutSec `
                                   -Headers @{ 'User-Agent' = "MusicRipper/$(Get-RipperVersion) (auto-updater)" } `
                                   -ErrorAction Stop
        if (-not $resp.tag_name) {
            throw "GitHub Release response had no tag_name."
        }
        $version = ([string]$resp.tag_name).TrimStart('v', 'V')
        $notes   = if ($resp.PSObject.Properties['body']) { [string]$resp.body } else { '' }
        $pub     = if ($resp.PSObject.Properties['published_at']) { [string]$resp.published_at } else { '' }
        # The 'html_url' field is the github.com page for the release
        # (e.g. https://github.com/<owner>/<repo>/releases/tag/v0.1).
        # Show-UpdateDialog uses it to back a 'View on GitHub' button.
        $htmlUrl = if ($resp.PSObject.Properties['html_url']) { [string]$resp.html_url } else { '' }
        # Prefer the source-zip 'zipball_url'; that's what GitHub
        # generates from the tag (matches what 'Code -> Download ZIP'
        # gives you for that tag).
        $zip     = [string]$resp.zipball_url
        return @{
            Version     = $version
            ZipballUrl  = $zip
            Notes       = $notes
            PublishedAt = $pub
            HtmlUrl     = $htmlUrl
            Source      = 'Release'
        }
    } catch {
        # Two cases collapse here: 404 (no Releases yet) and any
        # other network failure. Distinguish by HTTP status when we
        # can; treat 404 as "fall through to main-branch zip" and
        # everything else as "real network error".
        $is404 = $false
        try {
            if ($_.Exception.Response -and
                ($_.Exception.Response.StatusCode -as [int]) -eq 404) {
                $is404 = $true
            }
        } catch { }

        if (-not $is404) {
            Write-RipperLog WARN 'Updater' "GitHub Releases API failed: $($_.Exception.Message). Falling back to main-branch zip."
        } else {
            Write-RipperLog INFO 'Updater' "No GitHub Releases yet for $Repo; falling back to main-branch zip."
        }

        # Fallback: main-branch zip. We don't know the upstream SHA
        # without a second API call (commits/main); skip it -- the
        # version comparator will treat 'main-latest' as
        # NewerAvailable via the string-compare path so the user
        # always sees the option to update.
        return @{
            Version     = 'main-latest'
            ZipballUrl  = "https://github.com/$Repo/archive/refs/heads/main.zip"
            Notes       = ''
            PublishedAt = ''
            HtmlUrl     = ''
            Source      = 'MainBranch'
        }
    }
}


function Save-RipperUpdateBackup {
<#
.SYNOPSIS
    Rename the live install dir to '<install>-old-<yyyyMMdd-HHmmss>'
    so the apply step can move the new tree into the original
    location. Returns a result hashtable.

.DESCRIPTION
    Returns:
      @{ Success=$true;  BackupPath=<path>; ErrorMessage=$null }
        on successful rename.
      @{ Success=$false; BackupPath=$null; ErrorMessage=<text> }
        on failure. ErrorMessage includes the underlying exception
        text + a short hint about the most likely 'in use' causes
        when the underlying error matches the
        ERROR_SHARING_VIOLATION shape ("because it is in use" /
        "used by another process").

.PARAMETER InstallRoot
    Absolute path to the current MusicRipper install. Will be RENAMED;
    after a successful call the path no longer exists.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string]$InstallRoot)
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        $msg = "install root '$InstallRoot' does not exist."
        Write-RipperLog WARN 'Updater' "Save-RipperUpdateBackup: $msg"
        return @{ Success = $false; BackupPath = $null; ErrorMessage = $msg }
    }
    $stamp  = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $parent = Split-Path -Parent $InstallRoot
    $leaf   = Split-Path -Leaf  $InstallRoot
    $backup = Join-Path $parent ("$leaf-old-$stamp")
    try {
        Rename-Item -LiteralPath $InstallRoot -NewName (Split-Path -Leaf $backup) -ErrorAction Stop
        Write-RipperLog INFO 'Updater' "Renamed live install '$InstallRoot' -> '$backup' (rollback point)."
        return @{ Success = $true; BackupPath = $backup; ErrorMessage = $null }
    } catch {
        $raw = $_.Exception.Message
        Write-RipperLog ERROR 'Updater' "Save-RipperUpdateBackup: rename failed: $raw"
        # Distinguish the 'in use' case (someone is holding a handle on
        # the install dir) from other failures (permissions, missing
        # parent, etc.). The 'in use' case is by far the most common
        # in the field and the one a parent can do something about.
        $hint = ''
        if ($raw -match 'in use|being used by another process|sharing violation') {
            $hint = ' Likely cause: another process is holding the install directory open. ' +
                    'Common culprits: (1) MusicRipper is currently running -- check the system tray ' +
                    'or close any "Rip a CD" windows; (2) a File Explorer window has the install ' +
                    "folder or its parent open -- close those; (3) an antivirus is mid-scan -- wait " +
                    'a minute and retry.'
        } elseif ($raw -match 'denied|UnauthorizedAccess') {
            $hint = " Likely cause: insufficient permissions to rename '$InstallRoot'. " +
                    "Make sure your Windows user owns this folder. (The install path is '$InstallRoot' " +
                    "and the rename targets its parent '$parent'.)"
        }
        $errMsg = "Could not back up live install: $raw.$hint"
        return @{ Success = $false; BackupPath = $null; ErrorMessage = $errMsg }
    }
}


function Invoke-RipperUpdateApply {
<#
.SYNOPSIS
    Apply a downloaded+extracted update tree into the live install
    location, with backup, rollback, and user-file preservation.

.DESCRIPTION
    Given:
      - $InstallRoot: where MusicRipper lives today (will be backed
        up + replaced).
      - $StagingRoot: a directory that contains the extracted GitHub
        zip. Because GitHub zips wrap their content in a top-level
        '<repo>-<sha>' folder, we auto-detect that single child and
        treat it as the 'new install root'.

    Steps:
      1. Validate StagingRoot has exactly one top-level child folder
         that itself looks like an install (Install-MusicRipper.ps1
         + src\Start-Ripper.ps1 present). Refuse otherwise.
      2. Snapshot a known list of user-generated files from
         $InstallRoot (currently just data\driveoffsets.cached.json).
      3. Save-RipperUpdateBackup: rename live -> '-old-<stamp>'.
      4. Move the staging child folder INTO $InstallRoot (a
         filesystem rename when possible; falls back to recursive
         copy when the temp dir lives on a different volume).
      5. Restore the snapshotted user files into the new install.
      6. Return @{ Success = $true; BackupPath = ... }.
      7. On any failure between steps 3-5: try Restore-FromBackup
         (rename '-old-<stamp>' back to InstallRoot). Surface the
         original error AND the rollback outcome.

.PARAMETER InstallRoot
    Live install directory.

.PARAMETER StagingRoot
    Directory containing the extracted update (one top-level child
    folder).

.PARAMETER ProgressCallback
    Optional [scriptblock] called with @{ Phase=string; Detail=string }
    so the WPF can update its status text.

.OUTPUTS
    Hashtable with keys: Success, BackupPath, ErrorMessage.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$InstallRoot,
        [Parameter(Mandatory)] [string]$StagingRoot,
        [scriptblock]$ProgressCallback
    )

    $report = { param($Phase, $Detail)
        if ($ProgressCallback) {
            try { & $ProgressCallback @{ Phase = $Phase; Detail = $Detail } } catch { }
        }
        Write-RipperLog INFO 'Updater' "Apply [$Phase]: $Detail"
    }

    & $report 'Validate' "Inspecting staging root '$StagingRoot'."

    if (-not (Test-Path -LiteralPath $StagingRoot)) {
        return @{ Success = $false; BackupPath = $null; ErrorMessage = "Staging root does not exist: $StagingRoot" }
    }

    $children = @(Get-ChildItem -LiteralPath $StagingRoot -Directory)
    if ($children.Count -ne 1) {
        return @{ Success = $false; BackupPath = $null; ErrorMessage = "Expected exactly one top-level folder inside staging; found $($children.Count). GitHub zip layout may have changed." }
    }
    $newRoot = $children[0].FullName
    if (-not (Test-Path -LiteralPath (Join-Path $newRoot 'Install-MusicRipper.ps1'))) {
        return @{ Success = $false; BackupPath = $null; ErrorMessage = "Staging child '$newRoot' does not look like a MusicRipper install (missing Install-MusicRipper.ps1)." }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $newRoot 'src\Start-Ripper.ps1'))) {
        return @{ Success = $false; BackupPath = $null; ErrorMessage = "Staging child '$newRoot' does not look like a MusicRipper install (missing src\Start-Ripper.ps1)." }
    }

    & $report 'Snapshot' "Snapshotting user-generated files from live install."

    # Files we want to carry forward from the existing install. These
    # are user / runtime artifacts that the GitHub zip won't contain
    # (they were created post-install).
    $preserveRel = @(
        'data\driveoffsets.cached.json'
    )
    $snapshots = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($rel in $preserveRel) {
        $src = Join-Path $InstallRoot $rel
        if (Test-Path -LiteralPath $src) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("musicripper-preserve-" + [guid]::NewGuid().ToString('N'))
            try {
                Copy-Item -LiteralPath $src -Destination $tmp -ErrorAction Stop
                $snapshots.Add(@{ Rel = $rel; Tmp = $tmp })
            } catch {
                Write-RipperLog WARN 'Updater' "Snapshot of '$rel' failed: $($_.Exception.Message). The new install will start without it (regenerable on first launch)."
            }
        }
    }

    & $report 'Backup' "Renaming live install to backup."
    $backupResult = Save-RipperUpdateBackup -InstallRoot $InstallRoot
    if (-not $backupResult.Success) {
        # Propagate the rich error verbatim (it already includes the
        # underlying exception text + the 'in use' / permissions hint).
        # Pre-Phase-8.1 this was the unhelpful generic 'rename failed'.
        return @{ Success = $false; BackupPath = $null; ErrorMessage = $backupResult.ErrorMessage }
    }
    $backup = $backupResult.BackupPath

    & $report 'Move' "Moving new tree into '$InstallRoot'."
    try {
        # Primary: Move-Item handles same-volume (instant rename) and
        # cross-volume (recursive copy + delete) by itself; no need for
        # a manual rename-then-move dance. Same OneDrive-folder-redirected
        # Desktop trips up plain Rename-Item across the OneDrive
        # boundary even when the source + dest look like the same
        # volume; Move-Item handles that case via copy fallback
        # internally.
        try {
            Move-Item -LiteralPath $newRoot -Destination $InstallRoot -ErrorAction Stop
        } catch {
            # Fall back: explicit recursive copy of the staging child's
            # CONTENTS into the install path (not the wrapper folder
            # itself). NB: -Path (NOT -LiteralPath) so the trailing
            # '\*' is treated as a wildcard. -LiteralPath would look
            # for a file or folder literally named '*'. Pre-Phase-8.2
            # this used -LiteralPath and failed every cross-volume
            # update with "Cannot find path '...\*' because it does
            # not exist."
            New-Item -ItemType Directory -Path $InstallRoot -Force -ErrorAction Stop | Out-Null
            Copy-Item -Path (Join-Path $newRoot '*') -Destination $InstallRoot -Recurse -Force -ErrorAction Stop
        }
    } catch {
        $applyErr = $_.Exception.Message
        Write-RipperLog ERROR 'Updater' "Move new tree failed: $applyErr. Attempting rollback."
        # Roll back: rename backup back to InstallRoot.
        try {
            if (Test-Path -LiteralPath $InstallRoot) {
                # Partial new-tree may exist; remove before rolling back.
                Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop
            }
            Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $InstallRoot) -ErrorAction Stop
            Write-RipperLog INFO 'Updater' "Rollback succeeded; live install restored from backup."
            return @{ Success = $false; BackupPath = $null; ErrorMessage = "Update failed during move: $applyErr. Live install was rolled back to the previous version." }
        } catch {
            $rollbackErr = $_.Exception.Message
            Write-RipperLog ERROR 'Updater' "Rollback also failed: $rollbackErr. Live install is at '$backup'."
            return @{ Success = $false; BackupPath = $backup; ErrorMessage = "Update failed during move: $applyErr. Rollback ALSO failed: $rollbackErr. Your previous install is at: $backup" }
        }
    }

    & $report 'Restore' "Restoring $($snapshots.Count) preserved user file(s)."
    foreach ($s in $snapshots) {
        $dst = Join-Path $InstallRoot $s.Rel
        try {
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force -ErrorAction Stop | Out-Null
            }
            Move-Item -LiteralPath $s.Tmp -Destination $dst -Force -ErrorAction Stop
        } catch {
            Write-RipperLog WARN 'Updater' "Restore of '$($s.Rel)' failed: $($_.Exception.Message). It can be regenerated on next launch."
        }
    }

    return @{
        Success      = $true
        BackupPath   = $backup
        ErrorMessage = $null
    }
}


function Remove-RipperOldUpdateBackups {
<#
.SYNOPSIS
    Prune '<install>-old-*' backup directories alongside the live
    install, keeping the most recent N (default 2). Runs after a
    successful update; failures here are non-fatal.

.PARAMETER InstallRoot
    Live install path. Backups are siblings: same parent dir, leaf
    name '<leaf>-old-*'.

.PARAMETER Keep
    Number of newest backups to retain. Default 2 (immediate-prior +
    one further back).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstallRoot,
        [int]$Keep = 2
    )
    $parent = Split-Path -Parent $InstallRoot
    $leaf   = Split-Path -Leaf $InstallRoot
    $pattern = "$leaf-old-*"
    $backups = @(Get-ChildItem -LiteralPath $parent -Directory -Filter $pattern -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending)
    if ($backups.Count -le $Keep) {
        Write-RipperLog INFO 'Updater' "Backup retention: $($backups.Count) backup(s) found, $Keep allowed; nothing to prune."
        return
    }
    $toRemove = $backups | Select-Object -Skip $Keep
    foreach ($b in $toRemove) {
        try {
            Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction Stop
            Write-RipperLog INFO 'Updater' "Pruned old backup: $($b.FullName)"
        } catch {
            Write-RipperLog WARN 'Updater' "Could not prune backup '$($b.FullName)': $($_.Exception.Message)"
        }
    }
}


# =========================================================================
# v0.2.4: Pure-function helpers extracted from the WPF dialogs.
#
# Why: every update-path bug we've shipped (v0.1.1 View-on-GitHub button
# hidden, v0.2.0 startup-prompt notes panel showing "(No release notes
# provided.)" even when notes existed) lived in the data-decision logic
# INSIDE the WPF click handlers / state setters. The dialogs themselves
# are dumb renderers. Extracting the decisions here makes them
# unit-testable in Pester without instantiating a WPF window -- catching
# the next bug of that class at test time instead of at parent's-house
# time.
# =========================================================================

function Get-RipperReleaseIndexUrl {
<#
.SYNOPSIS
    Return the GitHub URL of the Releases index page (NOT a specific
    tag page). Centralized so we don't sprinkle the literal URL across
    the two dialog click handlers + commit messages + docs.

.OUTPUTS
    [string] e.g. 'https://github.com/ndbills/MusicRipper/releases'.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'https://github.com/ndbills/MusicRipper/releases'
}


function Get-RipperAccurateRipDatabaseUrl {
<#
.SYNOPSIS
    Return the AccurateRip drive-offsets database URL (the page that
    lists known drive models + their read offsets). Centralized so the
    'Browse AccurateRip database' button in Show-RegisterDriveDialog
    -- and any future caller -- gets the URL from one place.

.DESCRIPTION
    v0.3.0: parents using USB-to-SATA adapters / docking stations
    often see the drive's REAL model name masked by the adapter's
    chipset name in Windows. When the auto-lookup misses, they can
    click this URL to find their underlying drive's actual model +
    offset, then either type the model into the manual-lookup field
    or type the offset value directly.

    The URL is http (not https) because that's the form the
    AccurateRip site itself uses + matches the existing scraping
    code in Find-RipperAccurateRipEntry.

.OUTPUTS
    [string] 'http://www.accuraterip.com/driveoffsets.htm'.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'http://www.accuraterip.com/driveoffsets.htm'
}


function Test-RipperReleaseHasViewButton {
<#
.SYNOPSIS
    Return $true iff the View-on-GitHub button should be visible for
    the given release info. Encapsulates the hashtable-key-presence
    test that hit the v0.1.1/v0.2.0 visibility bug
    (`$ht.PSObject.Properties['HtmlUrl']` doesn't see hashtable keys
    -- documented in /memories/powershell.md).

.PARAMETER ReleaseInfo
    Hashtable returned by Get-RipperLatestRelease. Anything else
    (null, pscustomobject, garbage) returns $false defensively.

.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [object]$ReleaseInfo
    )
    if (-not $ReleaseInfo) { return $false }
    if (-not ($ReleaseInfo -is [hashtable])) { return $false }
    if (-not $ReleaseInfo.ContainsKey('HtmlUrl')) { return $false }
    return [bool][string]$ReleaseInfo['HtmlUrl']
}


function Get-RipperReleaseNotesText {
<#
.SYNOPSIS
    Return the body text the WPF notes panel should display for the
    given release info. Either the trimmed release-notes body, or a
    parent-friendly fallback string.

.DESCRIPTION
    Encapsulates the "release notes are present and non-empty" decision
    that hit the v0.2.0 startup-prompt "(No release notes provided.)"
    bug. Same hashtable-key-presence rule as
    Test-RipperReleaseHasViewButton.

.PARAMETER ReleaseInfo
    Hashtable returned by Get-RipperLatestRelease. Defensive against
    null / non-hashtable / missing-key / empty / whitespace-only.

.OUTPUTS
    [string] either the trimmed Notes value, or
    '(No release notes provided.)' when notes are absent or blank.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object]$ReleaseInfo
    )
    $fallback = '(No release notes provided.)'
    if (-not $ReleaseInfo)                          { return $fallback }
    if (-not ($ReleaseInfo -is [hashtable]))        { return $fallback }
    if (-not $ReleaseInfo.ContainsKey('Notes'))     { return $fallback }
    $raw = [string]$ReleaseInfo['Notes']
    if ([string]::IsNullOrWhiteSpace($raw))         { return $fallback }
    return $raw.Trim()
}


function Copy-RipperUpdaterBootstrap {
<#
.SYNOPSIS
    Stage the minimum set of files the temp-helper needs to drive the
    update WPF from %TEMP%. Extracted from Update-MusicRipper.ps1's
    bootstrap block so a Pester test can assert the file list without
    spawning a child pwsh process.

.DESCRIPTION
    Mirrors the install layout for just the files the helper imports
    + dot-sources:

        <StagingRoot>\Update-MusicRipper.ps1
        <StagingRoot>\src\lib\{Logging,Common,Updater}.{psd1,psm1}
        <StagingRoot>\src\ui\Show-UpdateDialog.ps1
        <StagingRoot>\VERSION    (best-effort; missing on source = skip)

    Why pure-function: catches "added a new module to the helper's
    dependency graph but forgot to add it to the bootstrap file list"
    bugs at Pester time. The test asserts the returned list matches
    the expected manifest, so a future addition (or accidental
    removal) shows up as a test failure with a clear diff.

.PARAMETER SourceRoot
    Live install directory (where Update-MusicRipper.ps1 lives).

.PARAMETER StagingRoot
    Destination directory; usually a fresh
    %TEMP%\musicripper-updater-<guid>\ folder. Created if absent.

.OUTPUTS
    [string[]] workspace-relative paths of the files actually copied,
    in copy order. The VERSION entry is omitted when the source has
    no VERSION file (older installs predate it).
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string]$SourceRoot,
        [Parameter(Mandatory)] [string]$StagingRoot
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Copy-RipperUpdaterBootstrap: SourceRoot does not exist: '$SourceRoot'."
    }

    # Build (or re-use) the staging skeleton.
    New-Item -ItemType Directory -Path $StagingRoot                           -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $StagingRoot 'src\lib')     -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $StagingRoot 'src\ui')      -Force -ErrorAction Stop | Out-Null

    # The required file manifest. The order doesn't matter at runtime
    # (the helper dot-sources by absolute path) but is preserved for
    # test introspection + logging.
    $manifest = [System.Collections.Generic.List[pscustomobject]]::new()
    $manifest.Add([pscustomobject]@{ Rel = 'Update-MusicRipper.ps1';        Required = $true })
    foreach ($m in @('Logging', 'Common', 'Updater')) {
        foreach ($ext in @('psd1', 'psm1')) {
            $manifest.Add([pscustomobject]@{ Rel = "src\lib\$m.$ext"; Required = $true })
        }
    }
    $manifest.Add([pscustomobject]@{ Rel = 'src\ui\Show-UpdateDialog.ps1';   Required = $true })
    # v0.2.0: VERSION file. Older installs don't have it (the file was
    # added in v0.2.0); missing = skip, not error.
    $manifest.Add([pscustomobject]@{ Rel = 'VERSION';                       Required = $false })

    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $manifest) {
        $src = Join-Path $SourceRoot  $entry.Rel
        $dst = Join-Path $StagingRoot $entry.Rel
        if (-not (Test-Path -LiteralPath $src)) {
            if ($entry.Required) {
                throw "Copy-RipperUpdaterBootstrap: required source file missing: '$src'."
            }
            continue
        }
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        $copied.Add($entry.Rel)
    }

    # Comma-prefix prevents PowerShell from unrolling a single-element
    # array to a bare string on return.
    return ,$copied.ToArray()
}


Export-ModuleMember -Function `
    Get-RipperLatestRelease, `
    Compare-RipperVersion, `
    Get-RipperInstallRoot, `
    Save-RipperUpdateBackup, `
    Invoke-RipperUpdateApply, `
    Remove-RipperOldUpdateBackups, `
    Get-RipperReleaseIndexUrl, `
    Get-RipperAccurateRipDatabaseUrl, `
    Test-RipperReleaseHasViewButton, `
    Get-RipperReleaseNotesText, `
    Copy-RipperUpdaterBootstrap
