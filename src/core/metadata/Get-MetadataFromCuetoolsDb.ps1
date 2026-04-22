<#
.SYNOPSIS
    Metadata provider: CUETools Database (CTDB).

.DESCRIPTION
    Pipeline position:
        Plug-in for the metadata-provider chain orchestrated by
        src/core/Get-DiscMetadata.ps1. The orchestrator calls
        Invoke-CuetoolsDbMetadataProvider with a disc-id object and
        receives a normalized response in the uniform provider contract
        (see Get-MetadataFromMusicBrainz.ps1 .DESCRIPTION).

    Why CTDB:
        MusicBrainz is the canonical store, but it's curated and slow to
        accept submissions. CTDB ships alongside CUETools' AccurateRip-
        style verification database and accepts metadata submissions from
        any CUERipper user. As a result it routinely has metadata for
        community-only / regional / hand-burned releases that MB has
        never heard of (a real example: assorted "Various Artists"
        compilations not in MB but submitted to CTDB by other rippers).

    What CTDB returns:
        Each match is a CTDBResponseMeta with album/artist/year/genre
        and a parallel tracks array of { name, artist }. CTDB does NOT
        carry MBIDs, label/catalog-number, barcode, ASIN, script, or
        cover art — fields outside this small set are emitted as $null
        / empty so the merge logic in the orchestrator can fill them
        from other providers.

    Implementation notes:
        - Reuses the in-memory [CUETools.CDImage.CDImageLayout] from
          Get-DiscId (DiscIdInfo.Toc) so we don't re-open the drive.
        - Loads CUETools assemblies lazily on first call (idempotent).
        - Constructs an AccurateRipVerify just to satisfy CUEToolsDB.Init();
          we don't actually call ContactAccurateRip from the metadata
          phase (verification belongs to the rip phase in Invoke-Rip).
        - ContactDB uses the 6-arg overload with explicit server
          'db.cuetools.net'. The 3-arg overload would also work but the
          6-arg form keeps the call shape parallel to Invoke-Rip.

.NOTES
    The user-agent string sent to CTDB reuses cfg.MusicBrainzUserAgent.
    CTDB is more relaxed about UA format than MB but a contact email is
    still polite.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

$script:CtdbAssembliesLoaded = $false

function Initialize-CtdbAssemblies {
<#
.SYNOPSIS
    Add-Type the CUETools DLLs needed for CTDB lookup. Idempotent.
.NOTES
    Internal helper. Not exported.

    Add-Type is process-idempotent for the same DLL path, so calling
    this after Get-DiscId already loaded the SCSI/CDImage subset is
    cheap. We additionally need CUETools.CTDB.dll and
    CUETools.AccurateRip.dll (the latter for the AccurateRipVerify ctor
    that CUEToolsDB.Init demands).
#>
    [CmdletBinding()]
    param()
    if ($script:CtdbAssembliesLoaded) { return }

    $cueDir = Get-CueToolsPath
    $dlls = @(
        (Join-Path $cueDir 'CUETools.CDImage.dll'),
        (Join-Path $cueDir 'CUETools.AccurateRip.dll'),
        (Join-Path $cueDir 'CUETools.CTDB.dll')
    )
    foreach ($dll in $dlls) {
        if (-not (Test-Path -LiteralPath $dll)) {
            throw "Required CUETools DLL not found: $dll"
        }
        Add-Type -Path $dll
    }
    $script:CtdbAssembliesLoaded = $true
}

function ConvertFrom-CtdbMetadata {
<#
.SYNOPSIS
    Convert a CTDB Metadata enumerable (or any IEnumerable of objects
    that quack like CTDBResponseMeta) into normalized candidate objects.

.DESCRIPTION
    Pure function -- no network, no CUETools dependency in the body. The
    parameter accepts any enumerable so unit tests can hand in PSCustomObjects
    that mimic the CTDBResponseMeta shape:
        { album; artist; year; genre; tracks: [{ name; artist }] }

    Output candidates use the same field names as the MB provider so the
    dialog and tag-writer don't need provider-specific code paths. Fields
    CTDB doesn't carry come back as $null or empty arrays so the merge
    step in the orchestrator can fill them from MB.

.PARAMETER Metadata
    The enumerable of CTDB metadata entries (typically `$ctdb.Metadata`).

.PARAMETER DiscIdInfo
    The disc-id object. Used to derive TrackCount as a fallback when CTDB
    omits the tracks array.

.EXAMPLE
    PS> $cands = ConvertFrom-CtdbMetadata -Metadata $ctdb.Metadata -DiscIdInfo $disc
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Metadata,
        [Parameter(Mandatory)] [pscustomobject]$DiscIdInfo
    )

    if ($null -eq $Metadata) { return @() }

    $audioCount = @($DiscIdInfo.Tracks | Where-Object { $_.IsAudio }).Count

    $out = foreach ($m in $Metadata) {
        if ($null -eq $m) { continue }

        # CTDB tracks: array of { name, artist }. Match by index against
        # the disc's track list; if CTDB ships fewer entries than the disc
        # has audio tracks, the missing ones come out as $null Title so
        # the merge step can fill them.
        $ctdbTracks = @()
        if ($m.PSObject.Properties['tracks'] -and $m.tracks) {
            $ctdbTracks = @($m.tracks)
        }
        $tracks = for ($i = 0; $i -lt $audioCount; $i++) {
            $title  = $null
            $artist = $null
            if ($i -lt $ctdbTracks.Count -and $null -ne $ctdbTracks[$i]) {
                $row = $ctdbTracks[$i]
                if ($row.PSObject.Properties['name']   -and $row.name)   { $title  = [string]$row.name }
                if ($row.PSObject.Properties['artist'] -and $row.artist) { $artist = [string]$row.artist }
            }
            [pscustomobject]@{
                Number           = $i + 1
                Title            = $title
                Artist           = $artist
                Artists          = if ($artist) { @($artist) } else { @() }
                ArtistSort       = $artist
                ArtistMbid       = @()
                RecordingMbid    = $null
                ReleaseTrackMbid = $null
                LengthMs         = 0
            }
        }

        # CTDB year arrives as a string; normalize to int when parseable.
        $year = $null
        if ($m.PSObject.Properties['year'] -and $m.year) {
            $yearStr = [string]$m.year
            if ($yearStr -match '^(\d{4})') { $year = [int]$Matches[1] }
        }

        $albumArtist = if ($m.PSObject.Properties['artist'] -and $m.artist) { [string]$m.artist } else { $null }
        $album       = if ($m.PSObject.Properties['album']  -and $m.album)  { [string]$m.album }  else { $null }
        $genre       = if ($m.PSObject.Properties['genre']  -and $m.genre)  { [string]$m.genre }  else { $null }

        # CTDB-flavored "Various Artists" detection -- string-only, no MBID.
        $isCompilation = $false
        if ($albumArtist -and $albumArtist -match '^(?i)various(\s+artists)?$') {
            $isCompilation = $true
        }

        # Field shape mirrors MB candidate so the orchestrator can merge
        # without per-provider switches. Anything CTDB doesn't carry stays
        # $null / empty.
        [pscustomobject]@{
            Source           = 'CTDB'
            AlbumArtist      = $albumArtist
            AlbumArtists     = if ($albumArtist) { @($albumArtist) } else { @() }
            AlbumArtistSort  = $albumArtist
            AlbumArtistMbid  = @()
            Album            = $album
            Media            = 'CD'
            ReleaseMbid      = $null
            ReleaseGroupMbid = $null
            Year             = $year
            ReleaseDate      = if ($year) { "$year" } else { $null }
            OriginalYear     = $year
            OriginalDate     = if ($year) { "$year" } else { $null }
            Country          = $null
            ReleaseStatus    = $null
            ReleaseType      = $null
            Script           = $null
            Language         = $null
            Asin             = $null
            Barcode          = $null
            LabelName        = $null
            CatalogNumber    = $null
            Genre            = $genre
            TrackCount       = @($tracks).Count
            DiscNumber       = 1
            TotalDiscs       = 1
            IsCompilation    = $isCompilation
            HasCoverArt      = $false
            Tracks           = @($tracks)
        }
    }

    @($out)
}

function Invoke-CuetoolsDbMetadataProvider {
<#
.SYNOPSIS
    Provider entry point: contact CTDB for the inserted disc and return
    a normalized response.

.DESCRIPTION
    Orchestrator-facing function. Returns the uniform provider contract
    shape. Network failures (no internet, server 5xx) come back as
    Status='Offline' with a Diagnostic string -- this provider never
    throws; it lets the orchestrator continue with whatever other
    providers are configured.

.PARAMETER DiscIdInfo
    The disc-id object from Get-RipperDiscId. Must carry a .Toc
    property (the live CDImageLayout). If .Toc is missing (e.g. a
    sidecar-replayed DiscIdInfo) we return Status='Error' with a
    diagnostic, since CTDB needs the raw TOC and we can't reconstruct
    it from disc-id alone.

.PARAMETER UserAgent
    The UA string to identify this client to db.cuetools.net. Defaults
    to a self-describing value when not supplied; production callers
    pass cfg.MusicBrainzUserAgent.

.EXAMPLE
    PS> $resp = Invoke-CuetoolsDbMetadataProvider -DiscIdInfo $disc -UserAgent $cfg.MusicBrainzUserAgent
    PS> $resp.Status
    Match
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$DiscIdInfo,

        [string]$UserAgent = 'MusicRipper/1.0 (+https://github.com/local)'
    )

    if (-not ($DiscIdInfo.PSObject.Properties['Toc']) -or $null -eq $DiscIdInfo.Toc) {
        $msg = 'CTDB provider needs DiscIdInfo.Toc (the live CDImageLayout from Get-RipperDiscId). Skipping.'
        Write-RipperLog WARN 'Get-DiscMetadata' $msg
        return [pscustomobject]@{
            Source = 'CTDB'; Status = 'Error'; BestMatch = $null
            Candidates = @(); Diagnostic = $msg
        }
    }

    try {
        Initialize-CtdbAssemblies
    } catch {
        $msg = "CUETools assemblies unavailable: $($_.Exception.Message)"
        Write-RipperLog WARN 'Get-DiscMetadata' $msg
        return [pscustomobject]@{
            Source = 'CTDB'; Status = 'Error'; BestMatch = $null
            Candidates = @(); Diagnostic = $msg
        }
    }

    $toc      = $DiscIdInfo.Toc
    $proxy    = [System.Net.WebRequest]::GetSystemWebProxy()
    $driveTag = if ($DiscIdInfo.PSObject.Properties['DriveLetter'] -and $DiscIdInfo.DriveLetter) {
                    [string]$DiscIdInfo.DriveLetter
                } else { 'unknown' }

    Write-RipperLog INFO 'Get-DiscMetadata' "CTDB provider: contacting db.cuetools.net for disc TOCID=$($DiscIdInfo.CtdbId)."

    try {
        $ar   = [CUETools.AccurateRip.AccurateRipVerify]::new($toc, $proxy)
        $ctdb = [CUETools.CTDB.CUEToolsDB]::new($toc, $proxy)
        $ctdb.Init($ar) | Out-Null

        # 6-arg overload: server, ua, driveName, fuzzy, metadataSearch, mode.
        # metadataSearch=$true is the bit that asks CTDB to return its
        # Metadata collection (otherwise we just get verification data).
        $ctdb.ContactDB('db.cuetools.net', $UserAgent, $driveTag, $true, $true, 0) | Out-Null
        $dbStatus = [string]$ctdb.DBStatus
        Write-RipperLog INFO 'Get-DiscMetadata' "CTDB DBStatus: '$dbStatus'."
    } catch {
        $msg = "CTDB contact failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'Get-DiscMetadata' $msg
        return [pscustomobject]@{
            Source = 'CTDB'; Status = 'Offline'; BestMatch = $null
            Candidates = @(); Diagnostic = $msg
        }
    }

    $candidates = @()
    try {
        $candidates = ConvertFrom-CtdbMetadata -Metadata $ctdb.Metadata -DiscIdInfo $DiscIdInfo
    } catch {
        $msg = "CTDB metadata parse failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'Get-DiscMetadata' $msg
        return [pscustomobject]@{
            Source = 'CTDB'; Status = 'Error'; BestMatch = $null
            Candidates = @(); Diagnostic = $msg
        }
    }

    if (@($candidates).Count -eq 0) {
        Write-RipperLog INFO 'Get-DiscMetadata' "CTDB returned no metadata for this disc."
        return [pscustomobject]@{
            Source = 'CTDB'; Status = 'NoMatch'; BestMatch = $null
            Candidates = @(); Diagnostic = $null
        }
    }

    $status = if (@($candidates).Count -gt 1) { 'MultiMatch' } else { 'Match' }
    Write-RipperLog INFO 'Get-DiscMetadata' "CTDB returned $(@($candidates).Count) candidate(s); top: '$($candidates[0].AlbumArtist) - $($candidates[0].Album)'."
    [pscustomobject]@{
        Source     = 'CTDB'
        Status     = $status
        BestMatch  = $candidates[0]
        Candidates = @($candidates)
        Diagnostic = $null
    }
}
