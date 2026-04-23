<#
.SYNOPSIS
    Metadata provider: GnuDB (the community successor to freedb/CDDB).

.DESCRIPTION
    Pipeline position:
        Plug-in for the metadata-provider chain orchestrated by
        src/core/Get-DiscMetadata.ps1. Invoked as
        Invoke-GnuDbMetadataProvider with a disc-id object; returns
        the uniform provider contract (see Get-MetadataFromMusicBrainz.ps1).

    Why GnuDB:
        GnuDB inherited the original freedb catalog and has continued to
        accept community submissions since 2006. It routinely carries
        regional / community / hand-compiled discs that MB and CTDB
        never saw (the motivating real-world case: an EFY 2006 VA
        Christmas compilation that MB and CTDB both miss but every
        legacy CDDB-aware ripper has).

    Protocol:
        CDDB over HTTP. Two-step:
          1. cddb query <disc-id> <ntrks> <off1..offN> <nsecs>
             Returns 200 (single match), 210 (exact matches list),
             211 (inexact matches list), or 202 (no match).
          2. cddb read <category> <disc-id>
             Returns an xmcd text file we parse for DTITLE / DYEAR /
             DGENRE / TTITLEn.

    Disc-id math (CDDB1 "freedb" ID, 8-hex):
        XXYYYYZZ where
          XX   = (sum over tracks of digit-sum(trackStartSec)) mod 255
          YYYY = (leadout_frame - track1_offset_frame) / 75
          ZZ   = ntrks
        CDDB frame offsets are LBA + 150 (the 2-second lead-in).
        CUETools doesn't expose this id, so we compute it locally from
        DiscIdInfo.Tracks[].StartSector. No extra DLL dependency.

    xmcd parsing:
        Per-line `KEY=VALUE`; TTITLEn may wrap across multiple lines
        (concatenated). DTITLE is "artist / album" -- we split on the
        FIRST " / ". Year comes from DYEAR (may be blank), genre from
        DGENRE. Category we track on the candidate too because the
        dialog's dropdown labels will benefit from it ("rock", "misc"
        etc.).

    Server identification:
        GnuDB requires a real-looking email + a distinct app name in
        the `hello=` query parameter or they rate-limit us into the
        ground. We reuse cfg.MusicBrainzUserAgent to extract the email
        (same "( user@host.com )" format both services expect) and
        identify as `musicripper`.

.NOTES
    GnuDB limits polite usage; we only issue ONE read (for the top
    candidate from the query response) rather than dereferencing the
    whole inexact-match list. The dialog's Re-search button would
    pull additional candidates in a future round if we ever decided
    to support it -- for now the orchestrator's merge covers the gap.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

function Get-GnuDbDiscId {
<#
.SYNOPSIS
    Compute the 8-hex CDDB1 / freedb disc ID for a DiscIdInfo object.

.DESCRIPTION
    Pure function -- no network, no CUETools dependency. Uses
    DiscIdInfo.Tracks[].StartSector and .LengthSectors (both LBA) to
    derive CDDB frame offsets (LBA + 150) and the leadout position.

    Also emits the query parameters GnuDB's cddb-query endpoint wants,
    so callers don't have to re-walk the track array.

.PARAMETER DiscIdInfo
    The disc-id object from Get-RipperDiscId.

.EXAMPLE
    PS> $q = Get-GnuDbDiscId -DiscIdInfo $disc
    PS> $q.DiscId
    9a09340d
    PS> $q.Offsets
    @(150, 15105, 26335, ...)
    PS> $q.Nsecs
    2358

.OUTPUTS
    [pscustomobject] with DiscId (string), Offsets (int[]), Nsecs (int),
    NTracks (int).
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject]$DiscIdInfo
    )

    $audioTracks = @($DiscIdInfo.Tracks | Where-Object { $_.IsAudio })
    if ($audioTracks.Count -eq 0) {
        throw "Get-GnuDbDiscId: DiscIdInfo has no audio tracks."
    }

    # Frame offsets as CDDB sees them: LBA + 150 (the 2-second lead-in).
    $offsets = @($audioTracks | ForEach-Object { [int]([int64]$_.StartSector + 150) })
    $last    = $audioTracks[-1]
    $leadout = [int]([int64]$last.StartSector + [int64]$last.LengthSectors + 150)
    $nsecs   = [int][math]::Floor(($leadout - $offsets[0]) / 75.0)

    # Sum of decimal digits of each track's START SECOND (frame/75).
    $checksum = 0
    foreach ($off in $offsets) {
        $sec = [int][math]::Floor($off / 75.0)
        while ($sec -gt 0) {
            $checksum += ($sec % 10)
            $sec = [int][math]::Floor($sec / 10.0)
        }
    }
    $xx     = $checksum % 255
    $discId = ('{0:x2}{1:x4}{2:x2}' -f $xx, $nsecs, $audioTracks.Count)

    [pscustomobject]@{
        DiscId   = $discId
        Offsets  = $offsets
        Nsecs    = $nsecs
        NTracks  = $audioTracks.Count
    }
}

function ConvertFrom-XmcdEntry {
<#
.SYNOPSIS
    Parse an xmcd-format body (the response from `cddb read`) into a
    normalized candidate.

.DESCRIPTION
    Pure function. Accepts the full xmcd text (with or without the
    leading response code line and trailing '.' terminator). Returns
    $null when the entry is unparseable or has no usable data.

.PARAMETER Text
    The raw xmcd body text.

.PARAMETER Category
    The GnuDB category the entry was read from (e.g. 'rock', 'misc').
    Attached to the candidate as .Genre when DGENRE is empty.

.PARAMETER DiscIdInfo
    Used only to know how many audio tracks the disc has, so a
    short TTITLEn list gets padded out with $null entries.

.NOTES
    xmcd line rules we handle:
      - Lines starting with '#' are comments (frame offsets, disc
        length, revision, processed-by, etc.).
      - KEY=value is the payload. TTITLEn may repeat across multiple
        physical lines to represent long titles; we concatenate.
      - DTITLE = "Artist / Album". Split on FIRST " / " only.
      - Values are raw text (no url-decoding by this point since GnuDB
        sends proto=6 / UTF-8).
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [string]$Category,
        [AllowNull()]
        [pscustomobject]$DiscIdInfo
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # When called from the disc-id chain we know exactly how many audio
    # tracks the disc has and pad missing TTITLEn to that count. From
    # the text-search path there is no disc — discover the track count
    # from the highest TTITLEn in the xmcd body itself (after parsing).
    $audioCount = if ($DiscIdInfo) {
        @($DiscIdInfo.Tracks | Where-Object { $_.IsAudio }).Count
    } else {
        0   # back-filled below once $fields is populated
    }
    $fields     = @{}   # multi-line KEY= values get appended

    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith('#'))          { continue }
        if ($line -eq '.')                  { continue }
        # A leading response code ("210 data 860a8c86 CD database entry...").
        if ($line -match '^\d{3}\s') { continue }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq)
        $val = $line.Substring($eq + 1)

        if ($fields.ContainsKey($key)) {
            $fields[$key] += $val
        } else {
            $fields[$key] = $val
        }
    }

    $dtitle = if ($fields.ContainsKey('DTITLE')) { [string]$fields['DTITLE'] } else { '' }
    $artist = $null; $album = $null
    if ($dtitle) {
        $idx = $dtitle.IndexOf(' / ')
        if ($idx -ge 0) {
            $artist = $dtitle.Substring(0, $idx).Trim()
            $album  = $dtitle.Substring($idx + 3).Trim()
        } else {
            # No separator: treat the whole line as album, artist unknown.
            $album = $dtitle.Trim()
        }
    }

    $year = $null
    if ($fields.ContainsKey('DYEAR') -and $fields['DYEAR']) {
        $ystr = [string]$fields['DYEAR']
        if ($ystr -match '^(\d{4})') { $year = [int]$Matches[1] }
    }

    $genre = $null
    if ($fields.ContainsKey('DGENRE') -and $fields['DGENRE']) {
        $genre = [string]$fields['DGENRE']
    }
    if (-not $genre -and $Category) { $genre = $Category }

    # If we don't already know the audio-track count (text-search call:
    # no DiscIdInfo), derive it from the highest TTITLEn we parsed.
    if ($audioCount -eq 0) {
        $maxIdx = -1
        foreach ($k in $fields.Keys) {
            if ($k -match '^TTITLE(\d+)$') {
                $n = [int]$Matches[1]
                if ($n -gt $maxIdx) { $maxIdx = $n }
            }
        }
        if ($maxIdx -ge 0) { $audioCount = $maxIdx + 1 }
    }

    # Build tracks[] from TTITLE0..TTITLE(n-1). xmcd uses zero-based
    # indices. If GnuDB ships fewer than $audioCount titles, pad with
    # nulls so the merge phase can fill them from another provider.
    $tracks = for ($i = 0; $i -lt $audioCount; $i++) {
        $key = "TTITLE$i"
        $title = if ($fields.ContainsKey($key)) { [string]$fields[$key] } else { $null }
        if ([string]::IsNullOrWhiteSpace($title)) { $title = $null }
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

    # GnuDB-flavored "Various Artists" detection. xmcd convention: the
    # artist half of DTITLE reads "Various" / "Various Artists" / "VA".
    $isCompilation = $false
    if ($artist -and $artist -match '^(?i)(various(\s+artists)?|va)$') {
        $isCompilation = $true
    }

    # Drop candidate entirely if we got nothing useful.
    $hasAny = ($album -and -not [string]::IsNullOrWhiteSpace($album)) -or
              ($artist -and -not [string]::IsNullOrWhiteSpace($artist)) -or
              (@($tracks | Where-Object { $_.Title }).Count -gt 0)
    if (-not $hasAny) { return $null }

    [pscustomobject]@{
        Source           = 'GnuDB'
        AlbumArtist      = $artist
        AlbumArtists     = if ($artist) { @($artist) } else { @() }
        AlbumArtistSort  = $artist
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

function ConvertFrom-GnuDbQueryResponse {
<#
.SYNOPSIS
    Parse the text body returned by `cddb query` into an array of
    (category, discid, dtitle) match records.

.DESCRIPTION
    Response codes we handle:
        200 Found exact match       -> single match on the same line
        210 Found exact matches     -> match list follows
        211 Found inexact matches   -> match list follows
        202 No match found          -> empty list
        Others                      -> throw

    Match lines look like:
        data 9a09348a Pink Floyd / THE WALL (Shine On Box) - CD 1

.PARAMETER Text
    The full HTTP response body.

.EXAMPLE
    PS> $matches = ConvertFrom-GnuDbQueryResponse -Text $body
    PS> $matches[0].Category
    rock
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [string]$Text
    )

    $lines = @($Text -split "`r?`n" | Where-Object { $_ -ne $null })
    if ($lines.Count -eq 0) { return @() }

    $first = $lines[0].Trim()
    if ($first -notmatch '^(\d{3})\s') {
        throw "GnuDB response has no status line: '$first'"
    }
    $code = [int]$Matches[1]

    switch ($code) {
        200 {
            # "200 category discid dtitle"
            if ($first -match '^\d{3}\s+(\S+)\s+(\S+)\s+(.+)$') {
                return @([pscustomobject]@{
                    Category = $Matches[1]
                    DiscId   = $Matches[2]
                    DTitle   = $Matches[3].Trim()
                })
            }
            return @()
        }
        { $_ -in 210,211 } {
            # List follows until a line of just "."
            $out = @()
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $l = $lines[$i].Trim()
                if ($l -eq '.' -or $l -eq '') { break }
                # "category discid dtitle"
                if ($l -match '^(\S+)\s+(\S+)\s+(.+)$') {
                    $out += [pscustomobject]@{
                        Category = $Matches[1]
                        DiscId   = $Matches[2]
                        DTitle   = $Matches[3].Trim()
                    }
                }
            }
            return @($out)
        }
        202 { return @() }
        default {
            throw "GnuDB returned unexpected response code $code in: $first"
        }
    }
}

function Invoke-GnuDbMetadataProvider {
<#
.SYNOPSIS
    Provider entry point: contact GnuDB for the inserted disc and
    return a normalized response.

.DESCRIPTION
    Orchestrator-facing function. Returns the uniform provider contract
    shape. Network failures come back as Status='Offline' with a
    Diagnostic string -- this provider never throws.

.PARAMETER DiscIdInfo
    Disc-id object from Get-RipperDiscId. Uses .Tracks[] to compute the
    CDDB disc-id and the query parameters.

.PARAMETER UserAgent
    Optional. Used to extract an email for GnuDB's hello= contact
    requirement. Caller typically passes cfg.MusicBrainzUserAgent
    (which embeds the user's email in the "( user@host )" suffix).

.PARAMETER BaseUrl
    Optional. Lets tests inject a local fake. Production callers omit
    this and hit the real GnuDB HTTPS endpoint.

.PARAMETER InvokeWebRequest
    Optional. Test seam: a scriptblock with the same shape as
    Invoke-WebRequest (returning an object with a .Content property).
    Production callers omit this and get the real cmdlet.

.PARAMETER MaxCandidates
    How many candidates from the query match-list to dereference via
    `cddb read`. Defaults to 3 to keep traffic polite.

.EXAMPLE
    PS> $r = Invoke-GnuDbMetadataProvider -DiscIdInfo $disc -UserAgent $cfg.MusicBrainzUserAgent
    PS> $r.Status
    Match
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$DiscIdInfo,

        [string]$UserAgent = 'MusicRipper/1.0 ( unknown@example.com )',

        [string]$BaseUrl = 'https://gnudb.gnudb.org/~cddb/cddb.cgi',

        [scriptblock]$InvokeWebRequest,

        [int]$MaxCandidates = 3
    )

    # Build disc-id / query args.
    try {
        $q = Get-GnuDbDiscId -DiscIdInfo $DiscIdInfo
    } catch {
        $msg = "GnuDB disc-id computation failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'Get-DiscMetadata' $msg
        return [pscustomobject]@{
            Source = 'GnuDB'; Status = 'Error'; BestMatch = $null
            Candidates = @(); Diagnostic = $msg
        }
    }

    # Extract email from the MB-shaped UA so we can identify properly
    # to GnuDB. Falls back to a generic placeholder if the UA isn't in
    # the expected "MusicRipper/x.y ( email )" shape.
    $email = 'unknown@example.com'
    if ($UserAgent -match '\(\s*([^)\s]+@[^)\s]+)\s*\)') {
        $email = $Matches[1]
    }
    $emailEsc = $email -replace '@', '+'   # GnuDB hello= uses + for @.
    $helloVal = "$emailEsc+musicripper+0.1"

    # Build the query URL. CDDB "+" means literal space; we use it here
    # intentionally for the command separator, and System.Uri will leave
    # them alone.
    $offsetStr = ($q.Offsets -join '+')
    $queryCmd  = "cddb+query+$($q.DiscId)+$($q.NTracks)+$offsetStr+$($q.Nsecs)"
    $queryUrl  = "$BaseUrl`?cmd=$queryCmd&hello=$helloVal&proto=6"

    Write-RipperLog INFO 'Get-DiscMetadata' "GnuDB provider: querying $($q.DiscId) ($($q.NTracks) tracks, $($q.Nsecs)s)."

    $webCall = if ($InvokeWebRequest) { $InvokeWebRequest } else {
        {
            param($Url)
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
        }
    }

    try {
        $resp = & $webCall $queryUrl
        $queryBody = [string]$resp.Content
    } catch {
        $msg = "GnuDB query failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'Get-DiscMetadata' $msg
        return [pscustomobject]@{
            Source = 'GnuDB'; Status = 'Offline'; BestMatch = $null
            Candidates = @(); Diagnostic = $msg
        }
    }

    $matchRecords = @()
    try {
        $matchRecords = ConvertFrom-GnuDbQueryResponse -Text $queryBody
    } catch {
        $msg = "GnuDB query parse failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'Get-DiscMetadata' $msg
        return [pscustomobject]@{
            Source = 'GnuDB'; Status = 'Error'; BestMatch = $null
            Candidates = @(); Diagnostic = $msg
        }
    }

    if (@($matchRecords).Count -eq 0) {
        Write-RipperLog INFO 'Get-DiscMetadata' "GnuDB returned no matches for disc-id $($q.DiscId)."
        return [pscustomobject]@{
            Source = 'GnuDB'; Status = 'NoMatch'; BestMatch = $null
            Candidates = @(); Diagnostic = $null
        }
    }

    # Deref up to $MaxCandidates; each one is a separate HTTP GET.
    $readCount = [math]::Min([int]$MaxCandidates, @($matchRecords).Count)
    Write-RipperLog INFO 'Get-DiscMetadata' "GnuDB returned $(@($matchRecords).Count) match(es); reading top $readCount."

    $candidates = @()
    for ($i = 0; $i -lt $readCount; $i++) {
        $m = $matchRecords[$i]
        $readCmd = "cddb+read+$($m.Category)+$($m.DiscId)"
        $readUrl = "$BaseUrl`?cmd=$readCmd&hello=$helloVal&proto=6"
        try {
            $rResp = & $webCall $readUrl
            $cand  = ConvertFrom-XmcdEntry -Text ([string]$rResp.Content) -Category $m.Category -DiscIdInfo $DiscIdInfo
            if ($cand) { $candidates += $cand }
        } catch {
            Write-RipperLog WARN 'Get-DiscMetadata' "GnuDB read failed for $($m.Category)/$($m.DiscId): $($_.Exception.Message)"
        }
    }

    if (@($candidates).Count -eq 0) {
        return [pscustomobject]@{
            Source = 'GnuDB'; Status = 'NoMatch'; BestMatch = $null
            Candidates = @(); Diagnostic = 'GnuDB matched but all reads returned unparseable entries.'
        }
    }

    $status = if (@($candidates).Count -gt 1) { 'MultiMatch' } else { 'Match' }
    Write-RipperLog INFO 'Get-DiscMetadata' "GnuDB produced $(@($candidates).Count) candidate(s); top: '$($candidates[0].AlbumArtist) - $($candidates[0].Album)'."
    [pscustomobject]@{
        Source     = 'GnuDB'
        Status     = $status
        BestMatch  = $candidates[0]
        Candidates = @($candidates)
        Diagnostic = $null
    }
}

function Invoke-GnuDbTextSearchProvider {
<#
.SYNOPSIS
    Text-search entry point: ask GnuDB for releases matching free-text
    artist/album terms and return the uniform provider contract.

.DESCRIPTION
    Sibling of Invoke-GnuDbMetadataProvider. The disc-id round uses
    `cddb query <disc-id> ...`; this one uses CDDB's `cddb search`
    command, which takes a search type ('artist' | 'title' | 'track' |
    'rest' | 'allfields') and a free-text string.

    We use 'allfields' because it matches across artist, title, and
    track names — useful when the user only remembers part of the album
    name, or when the catalog has the artist baked into the title.

    The response shares the same 200/210/211/202 envelope as
    `cddb query`, so we parse it with the existing
    ConvertFrom-GnuDbQueryResponse. Per top-N hit we then run
    `cddb read <category> <discid>` and parse with ConvertFrom-XmcdEntry
    (which now accepts a null DiscIdInfo and infers the audio-track
    count from the highest TTITLEn it sees).

.PARAMETER Artist
    Free-text artist. Optional but at least one of -Artist or -Album
    must be non-empty.

.PARAMETER Album
    Free-text album/title.

.PARAMETER Year
    Accepted for interface parity with the other providers; CDDB has
    no year filter so it's only used to log the request.

.PARAMETER Limit
    Cap on how many search hits to consider before deref'ing.

.PARAMETER DetailLimit
    Cap on how many `cddb read` round-trips to issue. CDDB is rate
    sensitive so 5 is a reasonable ceiling.

.PARAMETER UserAgent
    The MusicBrainz-shaped UA. Used only to extract the contact email
    GnuDB needs in `hello=`.

.PARAMETER BaseUrl
    Override for tests. Production callers omit and get the real
    https://gnudb.gnudb.org/~cddb/cddb.cgi endpoint.

.PARAMETER InvokeWebRequest
    Test seam matching Invoke-WebRequest's shape (returns an object
    with a .Content property). Production callers omit it.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Artist,
        [string]$Album,
        [int]$Year,
        [int]$Limit       = 10,
        [int]$DetailLimit = 5,
        [string]$UserAgent = 'MusicRipper/1.0 ( unknown@example.com )',
        [string]$BaseUrl   = 'https://gnudb.gnudb.org/~cddb/cddb.cgi',
        [scriptblock]$InvokeWebRequest
    )

    if ([string]::IsNullOrWhiteSpace($Artist) -and [string]::IsNullOrWhiteSpace($Album)) {
        return [pscustomobject]@{
            Source     = 'GnuDB'
            Status     = 'NoMatch'
            BestMatch  = $null
            Candidates = @()
            Diagnostic = 'GnuDB text search needs at least an artist or album.'
        }
    }

    # Build hello= the same way the disc-id provider does.
    $email = 'unknown@example.com'
    if ($UserAgent -match '\(\s*([^)\s]+@[^)\s]+)\s*\)') { $email = $Matches[1] }
    $emailEsc = $email -replace '@', '+'
    $helloVal = "$emailEsc+musicripper+0.1"

    # Combine artist + album (and year, if given) into one query string.
    # CDDB tokens are space-separated; URL-encode the whole thing.
    $termParts = @()
    if (-not [string]::IsNullOrWhiteSpace($Artist)) { $termParts += $Artist }
    if (-not [string]::IsNullOrWhiteSpace($Album))  { $termParts += $Album  }
    $term = ($termParts -join ' ').Trim()
    $encodedTerm = [System.Uri]::EscapeDataString($term)
    $searchCmd = "cddb+search+allfields+$encodedTerm"
    $searchUrl = "$BaseUrl`?cmd=$searchCmd&hello=$helloVal&proto=6"

    Write-RipperLog INFO 'Search-DiscMetadataByText' "GnuDB text search: term='$term' year=$Year"

    $webCall = if ($InvokeWebRequest) { $InvokeWebRequest } else {
        { param($Url) Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 }
    }

    try {
        $resp = & $webCall $searchUrl
        $body = [string]$resp.Content
    } catch {
        $msg = "GnuDB text search failed: $($_.Exception.Message)"
        Write-RipperLog WARN 'Search-DiscMetadataByText' $msg
        return [pscustomobject]@{
            Source     = 'GnuDB'
            Status     = 'Offline'
            BestMatch  = $null
            Candidates = @()
            Diagnostic = $msg
        }
    }

    $hits = @()
    try {
        $hits = ConvertFrom-GnuDbQueryResponse -Text $body
    } catch {
        # GnuDB sometimes responds to `cddb search` with a 4xx-class
        # CDDB code (e.g. 403 "Please mail info@gnudb.org" rate-limit
        # / identification gripe). Treat that as a soft Offline so the
        # other providers' results still surface; a hard Error spooks
        # the user with red ink even though it's recoverable.
        $first = ($body -split "`r?`n", 2)[0].Trim()
        $isSoft = $first -match '^4\d{2}\s' -or $first -match '^5\d{2}\s'
        $msg = if ($isSoft) {
            "GnuDB declined the text-search request: $first"
        } else {
            "GnuDB text search parse failed: $($_.Exception.Message)"
        }
        Write-RipperLog WARN 'Search-DiscMetadataByText' $msg
        return [pscustomobject]@{
            Source     = 'GnuDB'
            Status     = if ($isSoft) { 'Offline' } else { 'Error' }
            BestMatch  = $null
            Candidates = @()
            Diagnostic = $msg
        }
    }

    if (@($hits).Count -eq 0) {
        return [pscustomobject]@{
            Source     = 'GnuDB'
            Status     = 'NoMatch'
            BestMatch  = $null
            Candidates = @()
            Diagnostic = $null
        }
    }

    $hits = @($hits | Select-Object -First $Limit)
    $readCount = [math]::Min([int]$DetailLimit, @($hits).Count)
    Write-RipperLog INFO 'Search-DiscMetadataByText' "GnuDB returned $(@($hits).Count) hit(s); reading top $readCount."

    $candidates = @()
    for ($i = 0; $i -lt $readCount; $i++) {
        $h = $hits[$i]
        $readCmd = "cddb+read+$($h.Category)+$($h.DiscId)"
        $readUrl = "$BaseUrl`?cmd=$readCmd&hello=$helloVal&proto=6"
        try {
            $rResp = & $webCall $readUrl
            $cand  = ConvertFrom-XmcdEntry -Text ([string]$rResp.Content) -Category $h.Category -DiscIdInfo $null
            if ($cand) { $candidates += $cand }
        } catch {
            Write-RipperLog WARN 'Search-DiscMetadataByText' "GnuDB text-search read failed for $($h.Category)/$($h.DiscId): $($_.Exception.Message)"
        }
    }

    if (@($candidates).Count -eq 0) {
        return [pscustomobject]@{
            Source     = 'GnuDB'
            Status     = 'NoMatch'
            BestMatch  = $null
            Candidates = @()
            Diagnostic = 'GnuDB matched but all reads returned unparseable entries.'
        }
    }

    $status = if (@($candidates).Count -gt 1) { 'MultiMatch' } else { 'Match' }
    [pscustomobject]@{
        Source     = 'GnuDB'
        Status     = $status
        BestMatch  = $candidates[0]
        Candidates = @($candidates)
        Diagnostic = $null
    }
}
