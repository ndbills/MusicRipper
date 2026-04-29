<#
.SYNOPSIS
    Phase 6.3: built-in Synology NAS (SMB) sync target. Mirrors one
    album folder onto a UNC share via robocopy, optionally
    authenticating via a stored DPAPI credential.

.DESCRIPTION
    Copies a single album from the local library onto a configured SMB
    share -- typically a Synology DSM "music" share, but any UNC path
    that accepts robocopy will work (which makes this useful for plain
    Windows file servers and means tests can exercise it against a
    plain local folder pretending to be the share).

    Per-album destination layout (matches OneDrive target so the two
    mirror trees are 1:1 with the local library):

      <Source>      = <album folder under cfg.LibraryRoot>
      <Destination> = <cfg.SynologyUnc>\<Artist>\<Album>

    `cfg.SynologyUnc` is a UNC path (`\\nas\music`) -- typically the
    root of a DSM Shared Folder. We do NOT require the path to be a
    UNC at runtime; if you point it at any local folder the target
    still works (but no SMB mount is established -- pre-flight notes
    that and skips the New-SmbMapping step).

    Authentication (D-024):

      If `cfg.HasSynologyCredential = $true`, a DPAPI-protected
      PSCredential lives at `<config root>\credentials.clixml`. We
      decrypt it with Import-RipperCredential, mount the share into
      the current logon session via `New-SmbMapping`, run robocopy,
      then unmount via `Remove-SmbMapping` in `finally`.

      If no credential is stored we skip the mapping step entirely
      and rely on the user's ambient session credentials -- which is
      the normal case for a domain-joined PC or a workgroup machine
      where the user has already typed the share's password into
      Explorer with "Remember credentials" ticked.

      `cmdkey /add` was considered and rejected -- see D-024 -- because
      it leaves the credential in Credential Manager if the rip is
      killed mid-pipeline. `New-SmbMapping`'s mapping is scoped to the
      current logon session and cleared automatically when PowerShell
      exits.

    Pre-flight checks before any copy runs:
      1. The configured UNC path must be reachable. We Test-Path the
         root *after* mounting (so a private SMB share with stored
         creds passes). Failure -> Status='Failed' with a Diagnostic
         that names the path and tells the user what to check.
      2. If a credential is required (`HasSynologyCredential=$true`)
         but `Import-RipperCredential` returns `$null`, we fail fast
         with a "credentials.clixml missing or unreadable" diagnostic.

    Both pre-flight failures fail fast so the rip pipeline records
    them and `Sync-PendingAlbums.ps1` can retry once the user fixes
    the config / re-saves the credential.

.NOTES
    Why robocopy: same rationale as Sync-ToOneDrive.ps1 -- ships with
    every Windows SKU, restartable, sane retry semantics, rich exit
    codes. We re-use the OneDrive target's exit-code mapper and bytes
    parser via a small shared helper module footprint (the helpers in
    Sync-ToOneDrive.ps1 are pure functions; we dot-source them through
    the framework).

    Switches we use match Sync-ToOneDrive.ps1 with two changes for SMB:
      /Z              -- Restartable mode. Slow on small files BUT a NAS
                         link drop mid-album is far more likely than a
                         local OneDrive write failing, and resume saves
                         a full re-copy on transient blips. Worth the
                         per-file overhead.
      /R:5 /W:10      -- 5 retries / 10s wait (vs OneDrive's 2/5).
                         A flaky home WiFi link rebounds in 30s; a
                         OneDrive folder is local so retries should be
                         fast. Both bounded so the foreground rip
                         pipeline never hangs forever.

    Per-album, never `/MIR`. Same reasoning as OneDrive -- mirroring at
    the share root would risk purging the rest of the family library.
#>

Set-StrictMode -Version 3.0


function Test-RipperUncPath {
<#
.SYNOPSIS
    Return $true iff the supplied path looks like a UNC (\\server\share).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string]$Path)
    return $Path.StartsWith('\\') -or $Path.StartsWith('//')
}


function Get-RipperSynologyShareRoot {
<#
.SYNOPSIS
    Extract the `\\server\share` root from a deeper UNC path. Returns
    the path unchanged if it has no extra subdirs, or `$null` for a
    non-UNC input.

.DESCRIPTION
    `New-SmbMapping` maps a share, not a subfolder under a share. So
    if the user configures `\\nas\music\backups\rips` we still need to
    mount `\\nas\music`. Walks the first two backslash-delimited
    segments after the leading `\\`.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-RipperUncPath -Path $Path)) { return $null }
    # Normalise both \\ and // forms to backslash for the split.
    $norm = $Path.Replace('/', '\').TrimStart('\')
    $parts = $norm.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -lt 2) { return $null }
    return ('\\' + $parts[0] + '\' + $parts[1])
}


function Invoke-RipperSyncToSynologyNAS {
<#
.SYNOPSIS
    Sync one album folder to the configured Synology NAS share via
    robocopy. Conforms to the Phase 6.1 sync-target contract.

.DESCRIPTION
    See file header for the destination layout, authentication model,
    pre-flight checks, and robocopy switch rationale.

    Reads:
      $Config.SynologyUnc                (required)
      $Config.HasSynologyCredential      (optional; default false)
      $Config.LibraryRoot                (required, supplied as -LibraryRoot)
      `<config root>\credentials.clixml` (when HasSynologyCredential)

    Writes:
      Files into <SynologyUnc>\<rel album key>\

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

    # Pre-flight 1: SynologyUnc set?
    $uncProp = $Config.PSObject.Properties['SynologyUnc']
    $unc     = if ($uncProp) { [string]$uncProp.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($unc)) {
        $diag = "cfg.SynologyUnc is not set. Run setup/New-RipperConfig.ps1 to configure your NAS share, then retry."
        Write-RipperLog WARN 'SynologyNAS' "Pre-flight failed: $diag"
        return @{
            Target='SynologyNAS'; Status='Failed'; BytesCopied=0
            Diagnostic=$diag
        }
    }

    # Pre-flight 2: stored credential available if requested?
    $needsCred = $false
    if ($Config.PSObject.Properties['HasSynologyCredential']) {
        $needsCred = [bool]$Config.HasSynologyCredential
    }
    $cred = $null
    if ($needsCred) {
        $credErr = $null
        try {
            $cred = Import-RipperCredential
        } catch {
            $cred    = $null
            $credErr = $_.Exception.Message
        }
        if (-not $cred) {
            # Distinguish "file genuinely missing" from "could not load
            # it" -- the latter is almost always a CommandNotFoundException
            # because a caller forgot to Import-Module Config.psd1 in
            # their runspace, and reporting "missing or unreadable"
            # sends them on a wild-goose chase looking for a file that's
            # right there.
            if ($credErr) {
                $diag = "HasSynologyCredential=true but Import-RipperCredential failed: $credErr. (If this says 'not recognized as the name of a cmdlet', the caller forgot to Import-Module src/lib/Config.psd1 in this runspace.)"
            } else {
                $diag = "HasSynologyCredential=true but credentials.clixml is missing or unreadable. Re-run setup/New-RipperConfig.ps1 to re-save the NAS credential."
            }
            Write-RipperLog WARN 'SynologyNAS' "Pre-flight failed: $diag"
            return @{
                Target='SynologyNAS'; Status='Failed'; BytesCopied=0
                Diagnostic=$diag
            }
        }
    }

    # Optional SMB mount. We mount the share root (not the subfolder
    # under it -- New-SmbMapping is share-scoped) for the duration of
    # the copy and unmount in finally. If $unc is a local path (used
    # by tests + the "I just want a USB-disk mirror" use case), we
    # skip mounting entirely.
    $mountedRoot = $null
    $isUnc       = Test-RipperUncPath -Path $unc
    if ($isUnc -and $cred) {
        $shareRoot = Get-RipperSynologyShareRoot -Path $unc
        if (-not $shareRoot) {
            $diag = "SynologyUnc '$unc' does not parse as a \\server\share path."
            Write-RipperLog WARN 'SynologyNAS' "Pre-flight failed: $diag"
            return @{
                Target='SynologyNAS'; Status='Failed'; BytesCopied=0
                Diagnostic=$diag
            }
        }
        try {
            # New-SmbMapping is scoped to the current logon session and
            # gets torn down when PowerShell exits even if our finally
            # block doesn't run. -RemotePath = share root only.
            New-SmbMapping `
                -RemotePath $shareRoot `
                -UserName   $cred.UserName `
                -Password   $cred.GetNetworkCredential().Password `
                -ErrorAction Stop | Out-Null
            $mountedRoot = $shareRoot
            Write-RipperLog INFO 'SynologyNAS' "Mounted '$shareRoot' as '$($cred.UserName)' for sync."
        } catch {
            $diag = "Failed to mount '$shareRoot' as '$($cred.UserName)': $($_.Exception.Message)"
            Write-RipperLog WARN 'SynologyNAS' $diag
            return @{
                Target='SynologyNAS'; Status='Failed'; BytesCopied=0
                Diagnostic=$diag
            }
        }
    }

    try {
        # Pre-flight 3 (post-mount): the configured root is reachable?
        # Test-Path on a UNC is a real round-trip to the server, which
        # is what we want -- it surfaces "NAS off" / "wrong password"
        # before robocopy spends 30s timing out.
        if (-not (Test-Path -LiteralPath $unc)) {
            $diag = "SynologyUnc '$unc' is not reachable. Check the NAS is on, the share exists, and the configured credentials are correct."
            Write-RipperLog WARN 'SynologyNAS' "Pre-flight failed: $diag"
            return @{
                Target='SynologyNAS'; Status='Failed'; BytesCopied=0
                Diagnostic=$diag
            }
        }

        # Compose destination using the same rel-key the rest of the
        # framework uses, matching the OneDrive layout 1:1.
        $rel  = ConvertTo-RipperLibraryRelativeKey -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
        $dest = Join-Path $unc ($rel -replace '/','\')
        $destParent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destParent)) {
            try {
                New-Item -ItemType Directory -Path $destParent -Force -ErrorAction Stop | Out-Null
            } catch {
                $diag = "Could not create destination parent '$destParent': $($_.Exception.Message)"
                Write-RipperLog WARN 'SynologyNAS' $diag
                return @{
                    Target='SynologyNAS'; Status='Failed'; BytesCopied=0
                    Diagnostic=$diag
                }
            }
        }

        # Build robocopy invocation. /Z (restartable) + bumped retries
        # are the two SMB-friendly differences from the OneDrive target.
        $rcArgs = @(
            $AlbumPath, $dest,
            '/E',
            '/COPY:DAT',
            '/Z',
            '/R:5', '/W:10',
            '/NP', '/NFL', '/NDL', '/NJH',
            '/BYTES'
        )
        Write-RipperLog INFO 'SynologyNAS' "robocopy $($rcArgs -join ' ')"

        $output = $null
        $exit   = -1
        try {
            $output = & robocopy @rcArgs 2>&1
            $exit   = $LASTEXITCODE
        } catch {
            $diag = "robocopy could not be invoked: $($_.Exception.Message)"
            Write-RipperLog WARN 'SynologyNAS' $diag
            return @{
                Target='SynologyNAS'; Status='Failed'; BytesCopied=0
                Diagnostic=$diag
            }
        }

        # Re-use the pure helpers from Sync-ToOneDrive.ps1 -- both
        # targets see the same robocopy output shape, so there's no
        # reason to duplicate the parsers.
        $statusInfo = Get-RipperOneDriveStatusFromExitCode -ExitCode $exit
        $bytes      = Get-RipperOneDriveBytesCopied        -Output  ([string[]]$output)

        if ($statusInfo.Status -eq 'Failed') {
            $tail = ($output | Select-Object -Last 6) -join ' / '
            Write-RipperLog WARN 'SynologyNAS' "Failed for '$rel': $($statusInfo.Diagnostic). Tail: $tail"
            return @{
                Target='SynologyNAS'; Status='Failed'; BytesCopied=$bytes
                Diagnostic="$($statusInfo.Diagnostic). Tail: $tail"
            }
        }

        Write-RipperLog INFO 'SynologyNAS' "OK for '$rel' (exit $exit, bytes=$bytes, dest='$dest')."
        return @{
            Target='SynologyNAS'; Status='OK'; BytesCopied=$bytes
            Diagnostic=$null
        }
    } finally {
        if ($mountedRoot) {
            try {
                Remove-SmbMapping -RemotePath $mountedRoot -Force -ErrorAction Stop
                Write-RipperLog INFO 'SynologyNAS' "Unmounted '$mountedRoot'."
            } catch {
                Write-RipperLog WARN 'SynologyNAS' "Failed to unmount '$mountedRoot': $($_.Exception.Message). It will be cleared when PowerShell exits."
            }
        }
    }
}
