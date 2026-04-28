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
        trip duplicate-disc detection), OR
      - the entry's Source is 'library', the on-disk path is gone,
        AND the Phase 6.1 sync-state index records at least one
        sync target as Status='OK' for the same album-relative key.
        That covers "the user manually moved/deleted the local copy
        after sync, but we know it was backed up off-box, so re-insert
        should still trip duplicate-disc detection." See D-022.
    Otherwise (path missing, Source='library', no sync vouch)
    returns $null, so genuinely-stale 'I deleted that folder by hand
    before any sync target saw it' index rows quietly self-heal on
    next re-insert.

    The sync-state lookup is best-effort: if the sync helper isn't
    loaded (e.g. a tools script that only dot-sources core), the
    vouch step is skipped and behaviour falls back to today's
    self-heal -- no exceptions, no warnings.

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

    if (Test-Path -LiteralPath $entry.Path) { return $entry }

    # Path is gone. For Source='library', try the sync-state vouch
    # before declaring the entry stale. (Source='sent' rows whose
    # _Sent\... folder was deleted by hand fall through to self-heal
    # -- the user explicitly removed the only on-box copy of an
    # already-sent album, so forgetting the row is the right call.)
    if ($source -eq 'library') {
        $convertCmd = Get-Command -Name ConvertTo-RipperLibraryRelativeKey -ErrorAction SilentlyContinue
        $stateCmd   = Get-Command -Name Get-RipperLibrarySyncState         -ErrorAction SilentlyContinue
        if ($convertCmd -and $stateCmd) {
            try {
                $key   = & $convertCmd -LibraryRoot $LibraryRoot -AlbumPath $entry.Path
                $state = & $stateCmd   -LibraryRoot $LibraryRoot
                if ($state -and $state.ContainsKey($key)) {
                    $sEntry = $state[$key]
                    if ($sEntry.PSObject.Properties['Targets'] -and $sEntry.Targets) {
                        foreach ($p in $sEntry.Targets.PSObject.Properties) {
                            if ([string]$p.Value.Status -eq 'OK') {
                                Write-RipperLog INFO 'LibraryIndex' "Stale library path for DiscId ${DiscId} ('$($entry.Path)') vouched by sync-state (target '$($p.Name)' OK); surfacing entry."
                                return $entry
                            }
                        }
                    }
                }
            } catch {
                # Sync-state read failures are advisory; fall through
                # to the self-heal path so a corrupt sync-state.json
                # never silently breaks duplicate-disc detection in
                # the OTHER direction (returning a bogus entry).
                Write-RipperLog WARN 'LibraryIndex' "Sync-state vouch lookup failed for DiscId ${DiscId}: $($_.Exception.Message). Falling back to self-heal."
            }
        }
    }

    Write-RipperLog INFO 'LibraryIndex' "Stale index entry for DiscId ${DiscId}: '$($entry.Path)' no longer exists."
    $null
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
