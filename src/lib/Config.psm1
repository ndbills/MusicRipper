<#
.SYNOPSIS
    Config module: load/save/validate the per-machine MusicRipper config file.

.DESCRIPTION
    Pipeline position:
        Loaded by every entry point (setup scripts, Start-Ripper, post-processors)
        before they touch disk. Owns the canonical on-disk shape of `config.json`.

    Storage location:
        $env:LOCALAPPDATA\MusicRipper\config.json   (per-machine, never committed)

    Why this lives in a module instead of inline `Get-Content | ConvertFrom-Json`:
        - Centralises the schema so a future field addition is one place, not ten.
        - Wraps DPAPI credential round-tripping (Synology share user/password) so
          callers never see plaintext.
        - Makes validation testable in Pester without touching the real disk.

.NOTES
    Dependencies: PowerShell 7+, .NET DPAPI (via Export-Clixml/Import-Clixml).
    Secrets policy: any field whose value is a PSCredential is persisted to a
    sibling `credentials.clixml` next to config.json using DPAPI; the JSON only
    stores a reference flag, never the cleartext.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Canonical on-disk paths. Kept here so tests can override $script:ConfigRoot.
$script:ConfigRoot       = Join-Path $env:LOCALAPPDATA 'MusicRipper'
$script:ConfigPath       = Join-Path $script:ConfigRoot 'config.json'
$script:CredentialsPath  = Join-Path $script:ConfigRoot 'credentials.clixml'

function Get-RipperConfigPath {
<#
.SYNOPSIS
    Returns the absolute path to the active config.json.

.DESCRIPTION
    Single source of truth for where the per-machine config lives. Setup scripts,
    Start-Ripper, and tests all call this rather than building the path inline.

.EXAMPLE
    PS> Get-RipperConfigPath
    C:\Users\alice\AppData\Local\MusicRipper\config.json

.NOTES
    Pure function; safe to call before the directory exists.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:ConfigPath
}

function Get-RipperConfigRoot {
<#
.SYNOPSIS
    Returns the directory that holds config.json, credentials.clixml, and logs/.
.EXAMPLE
    PS> Get-RipperConfigRoot
    C:\Users\alice\AppData\Local\MusicRipper
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:ConfigRoot
}

function New-RipperConfigObject {
<#
.SYNOPSIS
    Build a fresh, fully-populated config object with sensible defaults.

.DESCRIPTION
    Used by `New-RipperConfig.ps1` (setup) to seed the file, and by tests to
    get a known-shape object without reading disk. Every field is documented
    inline below so future-you can scan the schema in one place.

.EXAMPLE
    PS> $cfg = New-RipperConfigObject -LibraryRoot 'D:\Music'
    PS> $cfg.LibraryRoot
    D:\Music

.PARAMETER LibraryRoot
    Absolute path to the library root (the folder that will contain
    `<Album Artist>\<Album> (Year)\...`). Required.

.PARAMETER DriveLetter
    Optical drive letter (e.g. 'D:'). Optional at construction; filled by
    Register-Drive.ps1.

.PARAMETER DriveOffset
    AccurateRip read offset in samples for the chosen drive. Optional at
    construction; filled by Register-Drive.ps1.

.PARAMETER OneDriveSyncTargetRoot
    Optional absolute path to the folder inside the user's OneDrive
    (or any local folder) where ripped albums should be mirrored to
    by the Phase 6.2 OneDrive sync target. Empty/null disables the
    target even if 'OneDrive' is listed in `SyncTargets`.

.PARAMETER SynologyUnc
    Optional UNC path (e.g. \\nas\music) for SMB sync.

.PARAMETER SynologySyncReviewQueue
    If $true, post-processor mirrors `_ReviewQueue/` to the NAS too. Default $false
    so review-only scratch work doesn't leak to the family library.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$LibraryRoot,

        [string]$DriveLetter,
        [int]$DriveOffset,
        [string]$OneDriveSyncTargetRoot,
        [string]$SynologyUnc,
        [bool]$SynologySyncReviewQueue = $false
    )

    [pscustomobject]@{
        # Schema version — bump when fields change shape so loaders can migrate.
        SchemaVersion           = 1

        # Top-level library root. All ripped albums land beneath this.
        LibraryRoot             = $LibraryRoot

        # Drive selection + AccurateRip offset (filled by Register-Drive.ps1).
        DriveLetter             = $DriveLetter
        DriveOffset             = $DriveOffset

        # MusicBrainz contact address -- email or URL. Required by the
        # MusicBrainz API terms of service so they can reach out about
        # misbehaving clients (e.g. a stuck retry loop hammering their
        # endpoint). Sent ONLY in the User-Agent header on requests to
        # musicbrainz.org / db.cuetools.net / gnudb.org and never
        # leaves the machine otherwise. Empty by default; first-run
        # WPF dialog (or setup/New-RipperConfig.ps1) prompts for it.
        # Either an email (you@example.com) or a URL (e.g. your GitHub
        # profile) is acceptable per MusicBrainz policy.
        contactAddress          = ''

        # Optional post-processor targets. Empty/null = disabled.
        OneDriveSyncTargetRoot  = $OneDriveSyncTargetRoot
        SynologyUnc             = $SynologyUnc
        SynologySyncReviewQueue = $SynologySyncReviewQueue

        # True iff a PSCredential is on disk in credentials.clixml (DPAPI).
        # Flag only — never store the cleartext or even the username here.
        HasSynologyCredential   = $false

        # Phase 5.2: ordered metadata-provider chain. MusicBrainz is the
        # canonical curated source; CTDB carries community-submitted
        # metadata for releases MB has never indexed. The orchestrator
        # synthesizes a "Merged (MB + CTDB)" candidate when both return
        # matches (MB wins on conflict, CTDB fills nulls).
        MetadataProviders       = @('MusicBrainz', 'CuetoolsDb', 'GnuDb')

        # Phase 5.2: ordered cover-art provider chain. First non-empty
        # bytes win. CAA needs an MB ReleaseMbid; iTunes/Deezer fall back
        # to artist+album text search. All three are free / no auth.
        CoverArtProviders       = @('iTunesSearch', 'CoverArtArchive', 'Deezer')

        # Phase 5.4: eject the optical drive after the rip / review /
        # cancel flow finishes. Default true preserves the existing
        # parent-friendly batch behaviour. Set false when you're
        # iterating on metadata or testing -- the dialog also exposes a
        # per-rip checkbox seeded from this value.
        EjectAfterRip           = $true

        # Phase 5.7: keep the application running between discs so the
        # parent can rip an entire stack without re-launching (and re-
        # answering the UAC prompt). After each rip a between-discs
        # dialog offers "Rip Next" / "Quit"; if a disc arrives via WMI
        # while the dialog is open it auto-selects "Rip Next". Logs
        # rotate per disc (each iteration calls Start-RipperLog again).
        # Set false to restore the one-disc-per-launch flow.
        ContinuousMode          = $true

        # Phase 6.1: ordered list of sync-target names invoked per album
        # after a successful Library move. Names map to functions named
        # 'Invoke-RipperSyncTo<Name>' loaded from src/sync/. Default empty
        # = no sync. Built-in: 'Stub' (writes a marker for testing).
        # Real targets land in 6.2 (OneDrive) and 6.3 (SynologyNAS).
        # Per-target results are persisted in
        # <LibraryRoot>\.musicripper\sync-state.json. Unknown names log
        # WARN at runtime and are reported as Failed; they don't crash.
        # Cast to [string[]] so an empty default still serialises as a
        # JSON array (a bare @() on a NoteProperty unrolls to $null on
        # property access, which trips downstream type checks).
        SyncTargets             = [string[]]@()

        # Phase 6.1: what to do with the local album folder after every
        # configured sync target has reported OK.
        #   'Keep'                       : never touch local files (default).
        #   'MoveToSentAfterAllSynced'   : move folder to <LibraryRoot>\_Sent\
        #                                  preserving the artist subdir.
        #   'RecycleAfterAllSynced'      : send folder to the Recycle Bin
        #                                  (recoverable, not hard-delete).
        # No-op when SyncTargets is empty or any target failed.
        LocalRetention          = 'Keep'

        # Phase 6.5: at startup -- BEFORE any disc-rip -- show a WPF
        # dialog that retries albums whose previous sync didn't finish
        # (e.g. NAS was offline, OneDrive was unreachable). The dialog
        # has its own Cancel button so a single launch can still skip
        # the retry without flipping this flag. Set false to disable
        # the auto-retry entirely; you can still run the equivalent
        # via src/tools/Sync-PendingAlbums.ps1.
        RetryPendingSyncOnStartup = $true

        # v0.2.0: at startup -- AFTER config-load, BEFORE the drive
        # prompt -- silently query the GitHub Releases API (5s
        # timeout). If a newer release is available, pop a small WPF
        # prompt with the release notes + 'Update now' / 'Not now' /
        # 'View on GitHub' buttons. Up-to-date / network-error /
        # first-run-with-no-config-yet all skip silently (no dialog
        # flash). 'Update now' launches the standalone
        # Update-MusicRipper updater (same script as the Start Menu
        # 'Update' shortcut) and exits MusicRipper cleanly so the
        # parent re-launches into the new version. Default true. Set
        # false to disable the auto-prompt -- you can still trigger
        # it manually via the Update shortcut any time.
        CheckForUpdatesOnLaunch   = $true

        # Phase 6.4: WireGuard auto-toggle. When the NAS share lives on
        # the other side of a WireGuard VPN (typical home-lab setup
        # where the parent rips at a friend's house and the family NAS
        # is at home), MusicRipper can bring the tunnel up before each
        # NAS sync and tear it down on application exit.
        #
        # `WireGuardTunnelName` is the bare tunnel name -- typically
        # the .conf filename without extension. Empty/null = no VPN
        # management; the share must already be reachable. Setup
        # (setup/New-RipperConfig.ps1) prompts for a .conf path,
        # installs it as a Windows service via wireguard.exe
        # /installtunnelservice, and grants the current user
        # SERVICE_START / SERVICE_STOP via `sc.exe sdset` so every
        # subsequent rip is UAC-free. See D-026 for the full design.
        #
        # `WireGuardAutoToggle` is the master switch -- false means
        # MusicRipper never starts/stops the tunnel itself even if
        # WireGuardTunnelName is set, useful for users who run their
        # own always-on VPN.
        #
        # `WireGuardKeepAliveBetweenDiscs` (Phase 6.4.1): when false
        # (default), the tunnel is held up only for the duration of a
        # single sync (one robocopy invocation), so a 30-disc rip
        # session bounces the tunnel 30 times. When true, the first
        # sync's acquire keeps the tunnel up for the rest of the
        # session and it's torn down on exit -- saves ~2-3s of
        # re-handshake per disc at the cost of holding the VPN open
        # the whole time.
        #
        # `PreferDirectNasConnection` (Phase 6.4.2): when true (default)
        # AND the WireGuard auto-toggle is otherwise eligible to fire,
        # the SynologyNAS sync target probes the configured share's
        # server on TCP/445 (~2s timeout) before deciding to acquire
        # the tunnel. If the NAS answers directly (i.e. the parent is
        # on the home LAN), the tunnel is NOT brought up and robocopy
        # uses the LAN path. If the probe times out or DNS fails, we
        # fall back to the existing WireGuard acquire path. Set false
        # to force the tunnel always (e.g. you don't trust the LAN
        # path or the LAN exposes the share over a slower link).
        WireGuardTunnelName             = $null
        WireGuardAutoToggle             = $true
        WireGuardKeepAliveBetweenDiscs  = $false
        PreferDirectNasConnection       = $true
    }
}

function Save-RipperConfig {
<#
.SYNOPSIS
    Persist a config object to %LOCALAPPDATA%\MusicRipper\config.json.

.DESCRIPTION
    Creates the parent directory if missing. Writes JSON with 2-space indent so
    a human can hand-edit. Does NOT write credentials — see Save-RipperCredential.

.PARAMETER Config
    The config object (typically from New-RipperConfigObject or a loaded file).

.PARAMETER Path
    Optional override for the destination path. Tests use this to redirect.

.EXAMPLE
    PS> $cfg | Save-RipperConfig
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Config,

        [string]$Path = (Get-RipperConfigPath)
    )
    process {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Import-RipperConfig {
<#
.SYNOPSIS
    Load and validate the on-disk config.

.DESCRIPTION
    Reads the JSON, asserts SchemaVersion, fills in any missing optional fields
    with defaults so callers can dot-access without null-checking every property.

.PARAMETER Path
    Optional override; defaults to %LOCALAPPDATA%\MusicRipper\config.json.

.EXAMPLE
    PS> $cfg = Import-RipperConfig
    PS> $cfg.LibraryRoot

.NOTES
    Throws if the file is missing — callers (setup scripts) should test first
    or catch and prompt the user to run `New-RipperConfig.ps1`.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path = (Get-RipperConfigPath)
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "MusicRipper config not found at '$Path'. Run setup\New-RipperConfig.ps1 first."
    }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-RipperConfig -Config $raw
    $raw
}

function Assert-RipperConfig {
<#
.SYNOPSIS
    Validate a config object against the v1 schema; throws on failure.

.DESCRIPTION
    Pure function — kept separate so Pester can drive it with hand-built objects
    instead of touching disk. Checks: SchemaVersion=1, LibraryRoot non-empty.

.PARAMETER Config
    The candidate config object.

.EXAMPLE
    PS> Assert-RipperConfig -Config $cfg
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )
    if ($Config.SchemaVersion -ne 1) {
        throw "Unsupported config SchemaVersion '$($Config.SchemaVersion)'; expected 1."
    }
    if ([string]::IsNullOrWhiteSpace($Config.LibraryRoot)) {
        throw "Config field 'LibraryRoot' is required."
    }
}

function Save-RipperCredential {
<#
.SYNOPSIS
    Persist a PSCredential via DPAPI next to config.json.

.DESCRIPTION
    Why DPAPI / Export-Clixml: PowerShell's serializer wraps SecureString with
    the current Windows user's DPAPI key, so the file is unreadable by other
    users on the same machine and unportable to other machines — exactly what
    we want for "Synology share password on Mom's laptop."
    See: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-clixml

.PARAMETER Credential
    The credential to persist (e.g. for the SMB share).

.PARAMETER Path
    Optional override; defaults to credentials.clixml in the config root.

.EXAMPLE
    PS> Get-Credential | Save-RipperCredential
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscredential]$Credential,

        [string]$Path = $script:CredentialsPath
    )
    process {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $Credential | Export-Clixml -LiteralPath $Path
    }
}

function Import-RipperCredential {
<#
.SYNOPSIS
    Load the DPAPI-protected PSCredential, or $null if none stored.

.PARAMETER Path
    Optional override; defaults to credentials.clixml in the config root.

.EXAMPLE
    PS> $cred = Import-RipperCredential
#>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [string]$Path = $script:CredentialsPath
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Import-Clixml -LiteralPath $Path
}

Export-ModuleMember -Function `
    Get-RipperConfigPath, Get-RipperConfigRoot, `
    New-RipperConfigObject, Save-RipperConfig, Import-RipperConfig, Assert-RipperConfig, `
    Save-RipperCredential, Import-RipperCredential
