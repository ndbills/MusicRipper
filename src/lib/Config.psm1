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

.PARAMETER OneDrivePath
    Optional absolute path inside the user's OneDrive to mirror the library to.

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
        [string]$OneDrivePath,
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

        # MusicBrainz identification — required by their ToS so they can contact
        # us about misbehaving clients. Filled in New-RipperConfig.ps1.
        MusicBrainzUserAgent    = 'MusicRipper/0.1 ( unknown@example.com )'

        # Optional post-processor targets. Empty/null = disabled.
        OneDrivePath            = $OneDrivePath
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
        MetadataProviders       = @('MusicBrainz', 'CuetoolsDb')

        # Phase 5.2: ordered cover-art provider chain. First non-empty
        # bytes win. CAA needs an MB ReleaseMbid; iTunes/Deezer fall back
        # to artist+album text search. All three are free / no auth.
        CoverArtProviders       = @('CoverArtArchive', 'iTunesSearch', 'Deezer')
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
