<#
.SYNOPSIS
    Phase 6.2: built-in OneDrive sync target. Mirrors one album folder
    into the user's OneDrive via robocopy.

.DESCRIPTION
    Copies a single album from the local library into a configured
    subfolder of OneDrive. The actual upload to Microsoft's servers
    is handled by the OneDrive client running in the user's session
    (we just put files into the synced folder; the client does the
    rest in the background). Documented per-album semantics:

      <Source>      = <album folder under cfg.LibraryRoot>
      <Destination> = <cfg.OneDriveSyncTargetRoot>\<Artist>\<Album>

    `cfg.OneDriveSyncTargetRoot` is an absolute path -- typically a
    folder _inside_ a OneDrive root such as
    `C:\Users\<You>\OneDrive\<...>\MusicRipper`. We do NOT require the
    target to be inside OneDrive; if you point at any other folder the
    target still works (which makes it useful as a generic local mirror,
    and means tests can exercise it against `$env:TEMP`).

    Pre-flight checks before any copy runs:
      1. OneDrive client must be installed for the current user. We
         detect this via HKCU\Software\Microsoft\OneDrive\UserFolder
         (set by the client at first sign-in). Missing key -> Failed
         with a Diagnostic that says exactly what to do.
      2. The configured target root must exist. We do NOT create it on
         the fly -- creating folders inside OneDrive can confuse the
         client, and a missing target usually means "config is stale"
         rather than "make a new folder, please". Failed with a
         Diagnostic.

    Both pre-flight failures fail fast (Status='Failed') so the rip
    pipeline records the problem and `Sync-PendingAlbums.ps1` can
    retry once the user fixes the config.

.NOTES
    Why robocopy instead of Copy-Item:
    - Robocopy ships with every Windows SKU (incl. Home) since Vista.
    - Restartable on partial copies (`/Z` available; we don't enable
      it by default because it's slow on small files; the OneDrive
      destination is a local NTFS path so partial-copy recovery isn't
      our problem).
    - Sane retry semantics. Powershell's Copy-Item retries forever on
      a network blip; robocopy gives us bounded `/R:n /W:s`.
    - Rich exit codes (0..7 = OK, >=8 = real failure) so we can
      distinguish "nothing to do" from "files copied" from "destination
      gone".

    Switches we use, with rationale:
      /E              -- copy subdirectories including empty ones
      /COPY:DAT       -- Data + Attributes + Timestamps. We deliberately
                         skip Security (NTFS ACLs) -- OneDrive's sync
                         engine ignores them and including them slows
                         the copy + spams the OneDrive activity log.
      /R:2 /W:5       -- 2 retries, 5s wait. Robocopy's defaults are
                         a million retries with 30s waits; that's fine
                         for an unattended overnight sync but ruinous
                         in the foreground rip pipeline.
      /NP /NFL /NDL   -- no progress %, no per-file list, no per-dir
                         list. We only need the trailing summary block.
      /NJH            -- suppress the job header
      /BYTES          -- byte counts in the summary so we can parse
                         BytesCopied without rescanning the source.

    Per-album, never `/MIR`. The framework is already invoked once per
    album by `Invoke-RipperSync`. Mirroring at the library root would
    risk purging anything inside the OneDrive folder we didn't put
    there.
#>

Set-StrictMode -Version 3.0


function Get-RipperOneDriveUserFolder {
<#
.SYNOPSIS
    Resolve the personal OneDrive root for the current user via the
    registry, or `$null` if the OneDrive client has never run / signed
    in.

.DESCRIPTION
    The OneDrive client writes its sync root to
    `HKCU\Software\Microsoft\OneDrive\UserFolder` (the legacy single-
    account location, present on every modern install) at first sign
    in. Per-account roots also live under `Accounts\Personal\UserFolder`.
    We try the canonical path first and fall back to the per-account
    one. Returns `$null` if neither resolves to an existing folder --
    the caller treats that as "OneDrive client not installed".

    Also accepts the `$env:OneDrive` environment variable as a final
    fallback; the client sets it for processes launched after sign-in,
    which covers the unusual case where the user wiped HKCU but is
    still signed in.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        'HKCU:\Software\Microsoft\OneDrive\UserFolder',
        'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal\UserFolder'
    )
    foreach ($key in $candidates) {
        try {
            if (Test-Path -LiteralPath $key) {
                $val = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
                # The default value is exposed as `(default)` by
                # Get-ItemProperty when the value name is empty; some
                # OneDrive installs use a named value instead.
                if (-not $val -and (Get-Item -LiteralPath $key).Property) {
                    $first = (Get-Item -LiteralPath $key).Property | Select-Object -First 1
                    if ($first) { $val = (Get-ItemProperty -LiteralPath $key -Name $first).$first }
                }
                if ($val -and (Test-Path -LiteralPath $val -PathType Container)) {
                    return [string]$val
                }
            }
        } catch {
            # Tolerate any unreadable key; fall through to the next.
        }
    }
    if ($env:OneDrive -and (Test-Path -LiteralPath $env:OneDrive -PathType Container)) {
        return [string]$env:OneDrive
    }
    return $null
}


function Get-RipperOneDriveStatusFromExitCode {
<#
.SYNOPSIS
    Map a robocopy exit code to a sync-target Status + Diagnostic pair.

.DESCRIPTION
    Robocopy bit-flag exit codes:
      0  No files copied, no failures, no mismatches -- nothing to do.
      1  Files copied successfully.
      2  Extra files / directories detected.
      3  (1 + 2) copied + extras.
      4  Mismatched files / directories detected.
      5  (4 + 1) copied + mismatches.
      6  (4 + 2)
      7  (4 + 2 + 1)
      >=8 At least one real failure (8) and/or fatal error (16).

    Per Microsoft's docs we treat 0..7 as success (the rip is on
    OneDrive), >=8 as failure.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [int]$ExitCode)

    if ($ExitCode -lt 0) {
        return @{ Status='Failed'; Diagnostic="robocopy did not run (exit code $ExitCode)" }
    }
    if ($ExitCode -ge 8) {
        $hint = if ($ExitCode -band 16) {
            'fatal error (destination unreachable / out of disk?)'
        } elseif ($ExitCode -band 8) {
            'one or more files failed to copy after retries'
        } else {
            'unknown failure'
        }
        return @{ Status='Failed'; Diagnostic="robocopy exit $ExitCode -- $hint" }
    }
    return @{ Status='OK'; Diagnostic=$null }
}


function Get-RipperOneDriveBytesCopied {
<#
.SYNOPSIS
    Parse a robocopy `/BYTES` summary block for total bytes copied.

.DESCRIPTION
    Looks for the "Bytes :" summary line and pulls the second integer
    (the "Copied" column). Returns 0 on parse failure -- BytesCopied
    is reported only as a UI hint, never authoritative.
#>
    [CmdletBinding()]
    [OutputType([int64])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()] [AllowEmptyCollection()] [AllowEmptyString()]
        [string[]]$Output
    )
    if (-not $Output) { return 0L }
    foreach ($line in $Output) {
        # Robocopy with /BYTES emits e.g.
        #   Bytes :    324_521_000    324_521_000    0    0    0    0
        # column order: Total | Copied | Skipped | Mismatch | FAILED | Extras
        if ($line -match '^\s*Bytes\s*:\s*\S+\s+(\S+)') {
            $copied = $Matches[1] -replace '[^\d]', ''
            if ($copied) { return [int64]$copied }
        }
    }
    return 0L
}


function Invoke-RipperSyncToOneDrive {
<#
.SYNOPSIS
    Sync one album folder to the configured OneDrive subfolder via
    robocopy. Conforms to the Phase 6.1 sync-target contract.

.DESCRIPTION
    See file header for the destination layout, pre-flight checks,
    and robocopy switch rationale.

    Reads:
      $Config.OneDriveSyncTargetRoot   (required)
      $Config.LibraryRoot              (required, supplied as -LibraryRoot)

    Writes:
      Files into <OneDriveSyncTargetRoot>\<rel album key>\

    Status mapping:
      OK     -- robocopy exit 0..7
      Failed -- pre-flight failed, robocopy exit >=8, or robocopy did
                not run at all. Diagnostic always set.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$AlbumPath,
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [object]$Config
    )

    # Pre-flight 1: OneDrive client installed?
    $oneDrive = Get-RipperOneDriveUserFolder
    if (-not $oneDrive) {
        return @{
            Target='OneDrive'; Status='Failed'; BytesCopied=0
            Diagnostic="OneDrive client is not installed for this user (no HKCU\Software\Microsoft\OneDrive\UserFolder, no `$env:OneDrive). Install OneDrive and sign in, then retry with src/tools/Sync-PendingAlbums.ps1."
        }
    }

    # Pre-flight 2: configured target exists?
    $rootProp = $Config.PSObject.Properties['OneDriveSyncTargetRoot']
    $root = if ($rootProp) { [string]$rootProp.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($root)) {
        return @{
            Target='OneDrive'; Status='Failed'; BytesCopied=0
            Diagnostic="cfg.OneDriveSyncTargetRoot is not set. Run setup/New-RipperConfig.ps1 to pick a OneDrive subfolder, then retry."
        }
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @{
            Target='OneDrive'; Status='Failed'; BytesCopied=0
            Diagnostic="OneDriveSyncTargetRoot '$root' does not exist on disk. Re-run setup/New-RipperConfig.ps1 (or create the folder) and retry."
        }
    }

    # Compose destination using the same rel-key the rest of the
    # framework uses. We deliberately preserve Artist/Album subdir
    # structure so the OneDrive view matches the local library 1:1.
    $rel  = ConvertTo-RipperLibraryRelativeKey -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
    $dest = Join-Path $root ($rel -replace '/','\')
    $destParent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destParent)) {
        try {
            New-Item -ItemType Directory -Path $destParent -Force -ErrorAction Stop | Out-Null
        } catch {
            return @{
                Target='OneDrive'; Status='Failed'; BytesCopied=0
                Diagnostic="Could not create destination parent '$destParent': $($_.Exception.Message)"
            }
        }
    }

    # Build robocopy invocation. Each switch is documented at the top
    # of the file. We capture stdout for the BytesCopied parse.
    $rcArgs = @(
        $AlbumPath, $dest,
        '/E',
        '/COPY:DAT',
        '/R:2', '/W:5',
        '/NP', '/NFL', '/NDL', '/NJH',
        '/BYTES'
    )
    Write-RipperLog INFO 'OneDriveSync' "robocopy $($rcArgs -join ' ')"

    $output = $null
    $exit   = -1
    try {
        $output = & robocopy @rcArgs 2>&1
        $exit   = $LASTEXITCODE
    } catch {
        return @{
            Target='OneDrive'; Status='Failed'; BytesCopied=0
            Diagnostic="robocopy could not be invoked: $($_.Exception.Message)"
        }
    }

    $statusInfo = Get-RipperOneDriveStatusFromExitCode -ExitCode $exit
    $bytes      = Get-RipperOneDriveBytesCopied        -Output  ([string[]]$output)

    if ($statusInfo.Status -eq 'Failed') {
        # Surface the last few lines of robocopy output so the operator
        # has something to read in sync-state.json without grepping the
        # log. Truncated to keep the JSON sane.
        $tail = ($output | Select-Object -Last 6) -join ' / '
        Write-RipperLog WARN 'OneDriveSync' "Failed for '$rel': $($statusInfo.Diagnostic). Tail: $tail"
        return @{
            Target='OneDrive'; Status='Failed'; BytesCopied=$bytes
            Diagnostic="$($statusInfo.Diagnostic). Tail: $tail"
        }
    }

    Write-RipperLog INFO 'OneDriveSync' "OK for '$rel' (exit $exit, bytes=$bytes, dest='$dest')."
    return @{
        Target='OneDrive'; Status='OK'; BytesCopied=$bytes
        Diagnostic=$null
    }
}
