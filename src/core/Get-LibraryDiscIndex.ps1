<#
.SYNOPSIS
    Phase 5.8: durable cross-session record of which discs (by
    MusicBrainz DiscId) have already been ripped into the library.

.DESCRIPTION
    The session-scoped `$script:RipperSession.RippedDiscs` hashtable
    only catches re-inserts within a single Start-Ripper run. To catch
    "I ripped this disc last weekend" the ripper consults a JSON index
    on disk:

        <LibraryRoot>\.musicripper\discids.json

    Shape (object map keyed by DiscId):

        {
          "<DiscId>": {
            "Path":     "E:\\digitize\\MusicRipper\\Foo Fighters\\Wasting Light (2011)",
            "Label":    "Foo Fighters - Wasting Light (2011)",
            "RippedAt": "2026-04-23T14:32:11Z",
            "Source":   "library"
          },
          ...
        }

    The index is *advisory*: read errors and corrupt JSON degrade to
    "no record found" rather than blocking a rip. A rebuild tool
    (`src/tools/Build-LibraryDiscIndex.ps1`) can reconstruct it from
    `MUSICBRAINZ_DISCID` tags in existing FLACs.

    Only Library moves are indexed. ReviewQueue items become indexable
    only after they're approved and moved into the real library.

.NOTES
    All functions are pure-ish:
      - Path is resolved via Join-Path off `$LibraryRoot`.
      - Get returns the live hashtable (callers may mutate, but the
        canonical write path is `Add-RipperLibraryDiscIndexEntry`).
      - Add reads, mutates, writes atomically (temp + Move-Item).
#>

function Get-RipperLibraryDiscIndexPath {
<#
.SYNOPSIS
    Path to the discids.json index file under a library root.

.PARAMETER LibraryRoot
    Absolute path to the music library root.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot
    )
    Join-Path (Join-Path $LibraryRoot '.musicripper') 'discids.json'
}


function Get-RipperLibraryDiscIndex {
<#
.SYNOPSIS
    Read the discid index for a library root.

.DESCRIPTION
    Returns a hashtable keyed by DiscId. Each value is a pscustomobject
    with Path / Label / RippedAt / Source fields. Returns an empty
    hashtable when the index is missing or unreadable; corruption is
    logged at WARN level but never throws.

.PARAMETER LibraryRoot
    Absolute path to the music library root.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot
    )

    $path = Get-RipperLibraryDiscIndexPath -LibraryRoot $LibraryRoot
    $out  = @{}

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $out }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $out }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-RipperLog WARN 'LibraryIndex' "Index unreadable at ${path}: $($_.Exception.Message). Treating as empty."
        return $out
    }

    foreach ($prop in $obj.PSObject.Properties) {
        $out[$prop.Name] = $prop.Value
    }
    $out
}


function Find-RipperLibraryDiscIndexEntry {
<#
.SYNOPSIS
    Look up one DiscId in the library index.

.DESCRIPTION
    Returns the entry pscustomobject when present and either:
      - the recorded Path still exists on disk (the normal
        'library'/'sent' case), OR
      - the entry's Source is 'recycled' (the local copy was
        intentionally disposed of by Phase 6.1 LocalRetention; the
        path is expected to be gone but the record is still meant to
        trip duplicate-disc detection).
    Otherwise (path missing for a non-recycled entry) returns $null,
    so stale 'I deleted that folder by hand' index rows quietly
    self-heal on next re-insert.

.PARAMETER LibraryRoot
    Absolute path to the music library root.

.PARAMETER DiscId
    MusicBrainz disc id to look up.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$DiscId
    )

    $idx = Get-RipperLibraryDiscIndex -LibraryRoot $LibraryRoot
    if (-not $idx.ContainsKey($DiscId)) { return $null }

    $entry = $idx[$DiscId]
    if (-not $entry.PSObject.Properties['Path'] -or -not $entry.Path) { return $null }

    # 'recycled' entries are kept for duplicate-disc detection AFTER
    # the local copy has been disposed of (D-022 LocalRetention =
    # RecycleAfterAllSynced). The on-disk path is expected to be
    # missing -- skip the existence check.
    $source = if ($entry.PSObject.Properties['Source']) { [string]$entry.Source } else { 'library' }
    if ($source -eq 'recycled') { return $entry }

    if (-not (Test-Path -LiteralPath $entry.Path)) {
        Write-RipperLog INFO 'LibraryIndex' "Stale index entry for DiscId ${DiscId}: '$($entry.Path)' no longer exists."
        return $null
    }
    $entry
}


function Add-RipperLibraryDiscIndexEntry {
<#
.SYNOPSIS
    Insert or update one entry in the discid index.

.DESCRIPTION
    Read-modify-write with an atomic rename. Creates `.musicripper\`
    dir if needed. RippedAt defaults to UTC now.

    Failures are logged at WARN and re-raised only when -ErrorAction
    Stop is specified. Callers in the rip pipeline should swallow
    exceptions so a flaky NAS write never derails a finished rip.

.PARAMETER LibraryRoot
    Absolute path to the music library root.

.PARAMETER DiscId
    MusicBrainz disc id (key).

.PARAMETER Path
    Absolute path to the album folder that holds this disc's rip.

.PARAMETER Label
    Friendly "Artist - Album (Year)" string for the duplicate-disc
    dialog. Optional but strongly recommended.

.PARAMETER Source
    Where this rip lives. Defaults to 'library'. Reserved values:
    'library', 'reviewqueue', 'sent', 'recycled'. The 'sent' value
    is set by Phase 6.1 LocalRetention=MoveToSentAfterAllSynced and
    points at <LibraryRoot>\_Sent\... ; 'recycled' is set by
    LocalRetention=RecycleAfterAllSynced and intentionally records
    a path that no longer exists on disk so the duplicate-disc
    dialog still fires on re-insert.
#>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$DiscId,
        [Parameter(Mandatory)] [string]$Path,
        [string]$Label,
        [ValidateSet('library', 'reviewqueue', 'sent', 'recycled')] [string]$Source = 'library'
    )

    $indexPath = Get-RipperLibraryDiscIndexPath -LibraryRoot $LibraryRoot
    $indexDir  = Split-Path -Parent $indexPath
    if (-not (Test-Path -LiteralPath $indexDir)) {
        New-Item -ItemType Directory -Path $indexDir -Force | Out-Null
    }

    $idx   = Get-RipperLibraryDiscIndex -LibraryRoot $LibraryRoot
    $entry = [pscustomobject]@{
        Path     = $Path
        Label    = if ($PSBoundParameters.ContainsKey('Label')) { $Label } else { '' }
        RippedAt = [DateTime]::UtcNow.ToString('o')
        Source   = $Source
    }
    $idx[$DiscId] = $entry

    # Serialize back as a flat object (so JSON keys = DiscIds).
    $payload = [ordered]@{}
    foreach ($k in ($idx.Keys | Sort-Object)) { $payload[$k] = $idx[$k] }
    $json = ($payload | ConvertTo-Json -Depth 5)

    $tmp = "$indexPath.tmp"
    try {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tmp -Destination $indexPath -Force
        Write-RipperLog INFO 'LibraryIndex' "Indexed DiscId $DiscId -> $Path."
    } catch {
        Write-RipperLog WARN 'LibraryIndex' "Failed to write index at ${indexPath}: $($_.Exception.Message)."
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}
