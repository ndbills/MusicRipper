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
        "=== Session ended $(Get-Date -Format o) ===" |
            Add-Content -LiteralPath $script:LogPath -Encoding UTF8
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

Export-ModuleMember -Function Start-RipperLog, Write-RipperLog, Stop-RipperLog, Get-RipperLogPath
