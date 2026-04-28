<#
.SYNOPSIS
    Phase 6.1: durable per-album sync-state index.

.DESCRIPTION
    Sibling of Get-LibraryDiscIndex.ps1 (D-018). Where discids.json
    answers "have I ripped this disc before?", sync-state.json answers
    "has this album been pushed to every configured sync target?".

    Path:
        <LibraryRoot>\.musicripper\sync-state.json

    Shape (object map keyed by album-folder path RELATIVE to LibraryRoot
    using forward slashes -- chosen so the same key works on Windows
    today and lets the file be inspected on a NAS / OneDrive view):

        {
          "Mannheim Steamroller/Christmas (1984)": {
            "DiscId":      "Wk6...",
            "FirstSeenAt": "2026-04-26T14:00:00Z",
            "Targets": {
              "OneDrive":    { "Status": "OK",      "SyncedAt": "2026-04-26T14:02:11Z", "BytesCopied": 123456, "Diagnostic": null },
              "SynologyNAS": { "Status": "Pending", "SyncedAt": null,                   "BytesCopied": 0,      "Diagnostic": "VPN tunnel down" }
            },
            "RetentionApplied": null
          }
        }

    `RetentionApplied`, when non-null, is a record of the LocalRetention
    action taken once every configured target reported OK:

        { "Action": "MoveToSentAfterAllSynced", "AppliedAt": "2026-04-26T14:05:00Z",
          "NewPath": "D:\\Music\\_Sent\\Mannheim Steamroller\\Christmas (1984)" }

    The file is *advisory* (same rules as discids.json):
      - Read errors / corruption degrade to "no record found".
      - Writes are atomic via temp + Move-Item.
      - Write failures are logged WARN; callers in the rip pipeline
        must swallow the exception so a flaky NAS write does not undo
        a successful sync.

.NOTES
    Per-target Status values:
      'OK'      - target accepted the album; SyncedAt + BytesCopied set.
      'Failed'  - target threw / refused; Diagnostic explains.
      'Skipped' - target opted out (e.g. config said "skip review queue").
      'Pending' - never attempted yet (set by Set-RipperLibrarySyncTargetStatus
                  when seeding a brand-new entry whose target failed before
                  this album was first synced).
#>

Set-StrictMode -Version 3.0

function Get-RipperLibrarySyncStatePath {
<#
.SYNOPSIS
    Path to the sync-state.json file under a library root.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$LibraryRoot)
    Join-Path (Join-Path $LibraryRoot '.musicripper') 'sync-state.json'
}


function ConvertTo-RipperLibraryRelativeKey {
<#
.SYNOPSIS
    Normalize an absolute album folder path to a forward-slash key
    relative to LibraryRoot (e.g. "Mannheim Steamroller/Christmas (1984)").

.DESCRIPTION
    Throws if AlbumPath isn't underneath LibraryRoot. Case is preserved
    on disk; comparisons are case-insensitive (NTFS default).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$AlbumPath
    )
    $libFull = [System.IO.Path]::GetFullPath($LibraryRoot).TrimEnd('\','/')
    $albFull = [System.IO.Path]::GetFullPath($AlbumPath).TrimEnd('\','/')
    if (-not $albFull.StartsWith($libFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "AlbumPath '$AlbumPath' is not under LibraryRoot '$LibraryRoot'."
    }
    $rel = $albFull.Substring($libFull.Length).TrimStart('\','/')
    $rel -replace '\\','/'
}


function Get-RipperLibrarySyncState {
<#
.SYNOPSIS
    Read the entire sync-state index for a library root.

.DESCRIPTION
    Returns a hashtable keyed by album relative key. Missing file or
    corrupt JSON returns an empty hashtable (logged WARN); never throws.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string]$LibraryRoot)

    $path = Get-RipperLibrarySyncStatePath -LibraryRoot $LibraryRoot
    $out  = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $out }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $out }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-RipperLog WARN 'SyncState' "Sync-state unreadable at ${path}: $($_.Exception.Message). Treating as empty."
        return $out
    }

    foreach ($prop in $obj.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
    $out
}


function Get-RipperLibrarySyncStateEntry {
<#
.SYNOPSIS
    Look up one album's sync-state record. Returns $null if absent.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$AlbumPath
    )
    $key = ConvertTo-RipperLibraryRelativeKey -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
    $idx = Get-RipperLibrarySyncState -LibraryRoot $LibraryRoot
    if (-not $idx.ContainsKey($key)) { return $null }
    $idx[$key]
}


function Save-RipperLibrarySyncState {
<#
.SYNOPSIS
    Atomically write the sync-state index to disk. Internal helper.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [hashtable]$Index
    )
    $path = Get-RipperLibrarySyncStatePath -LibraryRoot $LibraryRoot
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $payload = [ordered]@{}
    foreach ($k in ($Index.Keys | Sort-Object)) { $payload[$k] = $Index[$k] }
    $json = ($payload | ConvertTo-Json -Depth 8)

    $tmp = "$path.tmp"
    try {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        Write-RipperLog WARN 'SyncState' "Failed to write sync-state at ${path}: $($_.Exception.Message)."
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}


function Set-RipperLibrarySyncTargetResult {
<#
.SYNOPSIS
    Record the outcome of one target's sync attempt for one album.

.DESCRIPTION
    Read-modify-write. Creates the album entry on first call (seeding
    DiscId + FirstSeenAt) and merges the target result into its
    `Targets` map. Existing target results for the same target name
    are overwritten with the latest run's outcome.

    `Result` must be a hashtable / pscustomobject with at least:
        Target, Status, BytesCopied, Diagnostic
    (the Phase 6.1 sync-target contract).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$AlbumPath,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [object]$Result
    )

    $key = ConvertTo-RipperLibraryRelativeKey -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
    $idx = Get-RipperLibrarySyncState -LibraryRoot $LibraryRoot

    if ($idx.ContainsKey($key)) {
        $entry = $idx[$key]
    } else {
        $entry = [pscustomobject]@{
            DiscId           = $DiscId
            FirstSeenAt      = [DateTime]::UtcNow.ToString('o')
            Targets          = [pscustomobject]@{}
            RetentionApplied = $null
        }
    }

    $name = [string]$Result.Target
    $status = [string]$Result.Status
    $bytes = 0L
    $diag  = $null
    if ($Result -is [System.Collections.IDictionary]) {
        if ($Result.Contains('BytesCopied')) { $bytes = [int64]$Result['BytesCopied'] }
        if ($Result.Contains('Diagnostic'))  { $diag  = $Result['Diagnostic']  }
    } else {
        if ($Result.PSObject.Properties['BytesCopied']) { $bytes = [int64]$Result.BytesCopied }
        if ($Result.PSObject.Properties['Diagnostic'])  { $diag  = $Result.Diagnostic }
    }
    $syncedAt = if ($status -eq 'OK') { [DateTime]::UtcNow.ToString('o') } else { $null }

    $tEntry = [pscustomobject]@{
        Status      = $status
        SyncedAt    = $syncedAt
        BytesCopied = $bytes
        Diagnostic  = $diag
    }

    # Targets is a pscustomobject (so the JSON shape is an object map);
    # add or replace the named NoteProperty.
    if ($entry.Targets.PSObject.Properties[$name]) {
        $entry.Targets.PSObject.Properties.Remove($name)
    }
    $entry.Targets | Add-Member -NotePropertyName $name -NotePropertyValue $tEntry

    $idx[$key] = $entry
    Save-RipperLibrarySyncState -LibraryRoot $LibraryRoot -Index $idx
}


function Set-RipperLibraryRetentionApplied {
<#
.SYNOPSIS
    Record that retention ran on this album, including no-op outcomes.

.DESCRIPTION
    Every retention decision -- whether the album was moved, recycled,
    or intentionally left alone -- writes a stamped record so an
    operator inspecting sync-state.json can tell at a glance "yes, the
    pipeline considered this album and chose action X". A null
    RetentionApplied therefore means "retention has not run yet for
    this album", which is a meaningful diagnostic.

    Action values:
      - 'Keep'                       : LocalRetention=Keep, all targets OK.
      - 'KeepTargetsNotOk'           : retention requested but at least
                                       one configured target failed; the
                                       album stays put pending retry.
      - 'MoveToSentAfterAllSynced'   : album moved to <LibraryRoot>\_Sent\.
      - 'RecycleAfterAllSynced'      : album sent to the Recycle Bin.

    A 'KeepNoTargets' Action is intentionally NOT defined: when no
    sync targets are configured, no sync-state entry exists for the
    album in the first place, so there is nothing to annotate. The
    caller (Invoke-RipperLibraryRetention) skips the record write in
    that case.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$AlbumPath,
        [Parameter(Mandatory)]
        [ValidateSet('Keep','KeepTargetsNotOk','MoveToSentAfterAllSynced','RecycleAfterAllSynced')]
        [string]$Action,
        [string]$Reason,
        [string]$NewPath
    )
    $key = ConvertTo-RipperLibraryRelativeKey -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
    $idx = Get-RipperLibrarySyncState -LibraryRoot $LibraryRoot
    if (-not $idx.ContainsKey($key)) {
        Write-RipperLog WARN 'SyncState' "Retention applied to '$AlbumPath' but no sync-state entry exists; creating one."
        $idx[$key] = [pscustomobject]@{
            DiscId           = ''
            FirstSeenAt      = [DateTime]::UtcNow.ToString('o')
            Targets          = [pscustomobject]@{}
            RetentionApplied = $null
        }
    }
    $idx[$key].RetentionApplied = [pscustomobject]@{
        Action    = $Action
        Reason    = if ($PSBoundParameters.ContainsKey('Reason')) { $Reason } else { $null }
        AppliedAt = [DateTime]::UtcNow.ToString('o')
        NewPath   = if ($PSBoundParameters.ContainsKey('NewPath')) { $NewPath } else { $null }
    }
    Save-RipperLibrarySyncState -LibraryRoot $LibraryRoot -Index $idx
}


function Test-RipperLibraryAllTargetsOk {
<#
.SYNOPSIS
    True iff every target name in $RequiredTargets has Status='OK' on
    the album's sync-state entry. Returns false (with no error) when
    the entry is missing or any target is non-OK.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$AlbumPath,
        [Parameter(Mandatory)] [string[]]$RequiredTargets
    )
    if ($RequiredTargets.Count -eq 0) { return $false }
    $entry = Get-RipperLibrarySyncStateEntry -LibraryRoot $LibraryRoot -AlbumPath $AlbumPath
    if (-not $entry) { return $false }
    foreach ($name in $RequiredTargets) {
        if (-not $entry.Targets.PSObject.Properties[$name]) { return $false }
        if ([string]$entry.Targets.$name.Status -ne 'OK') { return $false }
    }
    $true
}
