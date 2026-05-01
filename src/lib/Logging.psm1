<#
.SYNOPSIS
    Logging module: structured rolling logs for MusicRipper.

.DESCRIPTION
    Pipeline position:
        Used by every script that does work (setup, ripper, post-processors).
        A run starts a session log under
            %LOCALAPPDATA%\MusicRipper\logs\<yyyyMMdd-HHmmss>-<context>.log
        and Write-RipperLog appends timestamped, level-tagged lines to it.

    Why a custom module instead of PSFramework / Logging gallery module:
        - Zero external runtime dependency (one of the project's hard rules).
        - We need exactly one file per rip, named after the album, so the
          REVIEW.txt can point at it. A general-purpose logger doesn't give
          that for free.

.NOTES
    Format is plain text, one line per event:
        2026-04-20T13:45:21.123Z  INFO   Get-DiscId  Starting TOC read on D:
    so it greps cleanly. Not JSON because the primary consumer is a human
    reading the file in Notepad while debugging a bad rip.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Active session state. $null until Start-RipperLog is called.
$script:LogPath    = $null
$script:LogContext = $null

function Start-RipperLog {
<#
.SYNOPSIS
    Begin a new log session and return the resulting log file path.

.DESCRIPTION
    Creates %LOCALAPPDATA%\MusicRipper\logs\ if needed, then opens
    a new file named <yyyyMMdd-HHmmss>-<Context>.log. Subsequent
    Write-RipperLog calls append to this file until Stop-RipperLog
    or the next Start-RipperLog.

.PARAMETER Context
    Short slug used in the filename (e.g. 'setup', 'rip-darkside-of-the-moon').
    Sanitized to a safe filename fragment.

.PARAMETER LogRoot
    Optional override; defaults to %LOCALAPPDATA%\MusicRipper\logs.

.EXAMPLE
    PS> $log = Start-RipperLog -Context 'setup'
    PS> Write-RipperLog INFO 'Install-Dependencies' 'Starting winget install.'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Context,

        [string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'MusicRipper\logs')
    )

    if (-not (Test-Path -LiteralPath $LogRoot)) {
        New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
    }

    # Strip everything but ASCII word chars and dashes so the slug is filename-safe.
    $slug = ($Context -replace '[^\w\-]+', '_').Trim('_')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:LogPath    = Join-Path $LogRoot "$stamp-$slug.log"
    $script:LogContext = $Context

    "=== MusicRipper log session: $Context  started $(Get-Date -Format o) ===" |
        Set-Content -LiteralPath $script:LogPath -Encoding UTF8

    $script:LogPath
}

function Write-RipperLog {
<#
.SYNOPSIS
    Append a structured line to the active log session.

.DESCRIPTION
    Format: ISO-8601 UTC timestamp, level (INFO/WARN/ERROR/DEBUG), source, message.
    Also mirrors the line to the host stream at the matching severity so the
    user sees progress in real time.

.PARAMETER Level
    One of INFO, WARN, ERROR, DEBUG.

.PARAMETER Source
    Short identifier for the calling script/function (e.g. 'Invoke-Rip').

.PARAMETER Message
    Free-form message text.

.EXAMPLE
    PS> Write-RipperLog INFO 'Invoke-Rip' "Starting rip of disc id $id"
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $line = "{0}  {1,-5}  {2,-22}  {3}" -f $stamp, $Level, $Source, $Message

    # Tolerate "log not started" so utility code (e.g. config loaders) can call
    # us without forcing every caller to manage session lifecycle.
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }

    switch ($Level) {
        'ERROR' { Write-Error   $line -ErrorAction Continue }
        'WARN'  { Write-Warning $line }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host    $line }
    }
}

function Stop-RipperLog {
<#
.SYNOPSIS
    Close the active log session (writes a footer and clears state).

.EXAMPLE
    PS> Stop-RipperLog
#>
    [CmdletBinding()]
    param()
    if ($script:LogPath) {
        # Test-Path because tests (and rare prod cases like a folder being
        # moved out from under us) may have removed the file already; we
        # still want to clear the in-memory state without throwing.
        if (Test-Path -LiteralPath $script:LogPath) {
            "=== Session ended $(Get-Date -Format o) ===" |
                Add-Content -LiteralPath $script:LogPath -Encoding UTF8
        }
        $script:LogPath    = $null
        $script:LogContext = $null
    }
}

function Get-RipperLogPath {
<#
.SYNOPSIS
    Return the path of the current active log session, or $null if none.
.EXAMPLE
    PS> Get-RipperLogPath
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:LogPath
}

function Set-RipperLogPath {
<#
.SYNOPSIS
    Adopt an existing log file as the active session log for the
    current runspace.

.DESCRIPTION
    The Logging module keeps `$script:LogPath` per-runspace
    (PowerShell module state is per-runspace by design). Background
    runspaces created by Show-RipProgress / Show-PendingSyncProgress
    re-import the module on their own and start out with
    `$script:LogPath = $null`, which silently drops every
    `Write-RipperLog` call to the file (it still hits the host
    stream) and makes `Copy-RipperLog` a no-op.

    This function lets a worker runspace adopt the parent runspace's
    active log file by absolute path, so subsequent `Write-RipperLog`
    appends to the same file the parent is using and `Copy-RipperLog`
    snapshots the right thing.

    Best-effort: if `Path` doesn't exist or is unwritable, writes a
    warning and leaves `$script:LogPath` unchanged. Never throws --
    callers in worker runspaces shouldn't have to wrap this in
    try/catch just to keep going.

    The companion `Stop-RipperLog` will write the "Session ended"
    footer when called from this runspace -- but the parent runspace
    is the canonical owner of the lifecycle. Don't call
    `Stop-RipperLog` from a worker that adopted the parent's log;
    let the parent close it.

.PARAMETER Path
    Absolute path to an existing log file (typically the value
    returned by `Get-RipperLogPath` in the parent runspace).

.PARAMETER Context
    Optional human-readable context tag (e.g. 'rip-disc-3-worker'),
    surfaced via `Get-RipperLogPath` callers in this runspace if
    they need it. Defaults to '<adopted>'.

.EXAMPLE
    PS> # main runspace
    PS> $logPath = Get-RipperLogPath
    PS> # ... pass $logPath into the worker via SessionStateProxy.SetVariable ...
    PS> # worker runspace (after dot-sourcing whatever imports Logging):
    PS> Set-RipperLogPath -Path $logPath
#>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Context = '<adopted>'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning "Set-RipperLogPath: log file not found: $Path"
        return
    }
    $script:LogPath    = $Path
    $script:LogContext = $Context
}

function Copy-RipperLog {
<#
.SYNOPSIS
    Snapshot the active session log into an album/destination folder.

.DESCRIPTION
    Copies the current `$script:LogPath` content to
    `<Destination>\<FileName>` so the per-album folder carries a copy
    of the run's structured log. The session log under %LOCALAPPDATA%
    keeps growing; this is just a point-in-time snapshot.

    Best-effort: if no session is active, the source file is missing,
    or the destination is unwritable, this writes a WARN line and
    returns `$null` instead of throwing. Logs follow rips, but a
    failed log copy must NEVER block the move-to-library step that
    just spent 10+ minutes producing the audio.

.PARAMETER Destination
    Target folder. Must already exist.

.PARAMETER FileName
    Leaf name to write inside `Destination`. Defaults to
    `ripper-session.log` so it doesn't collide with the CUETools-style
    `<Album>.log` rip log that Invoke-Rip already places in the folder.

.EXAMPLE
    PS> Copy-RipperLog -Destination 'C:\Library\Artist\Album (2024)'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Destination,

        [string]$FileName = 'ripper-session.log'
    )

    if (-not $script:LogPath) {
        Write-Warning "Copy-RipperLog: no active session log to copy."
        return $null
    }
    if (-not (Test-Path -LiteralPath $script:LogPath)) {
        Write-Warning "Copy-RipperLog: source log not found: $script:LogPath"
        return $null
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        Write-Warning "Copy-RipperLog: destination folder not found: $Destination"
        return $null
    }

    $target = Join-Path $Destination $FileName
    try {
        Copy-Item -LiteralPath $script:LogPath -Destination $target -Force
        return $target
    } catch {
        Write-Warning "Copy-RipperLog: copy failed: $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function Start-RipperLog, Write-RipperLog, Stop-RipperLog, Get-RipperLogPath, Set-RipperLogPath, Copy-RipperLog
