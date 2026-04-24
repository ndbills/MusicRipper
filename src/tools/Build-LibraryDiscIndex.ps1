<#
.SYNOPSIS
    Phase 5.8: build (or rebuild) the cross-session DiscId index from
    MUSICBRAINZ_DISCID tags already embedded in your library's FLACs.

.DESCRIPTION
    Optional one-shot tool. The runtime ripper does not need this --
    the index will fill itself one disc at a time as new rips land.
    Run this if you want existing albums detected by the duplicate-disc
    prompt without first re-ripping each one.

    Walks every FLAC under <LibraryRoot>, reads MUSICBRAINZ_DISCID via
    `metaflac --show-tag=MUSICBRAINZ_DISCID`, and writes one entry per
    distinct DiscId pointing at the album folder containing the FLAC.

    Skips:
      - <LibraryRoot>\_ReviewQueue\... (review queue is not indexed).
      - <LibraryRoot>\.musicripper\... (the index dir itself).
      - FLACs with no MUSICBRAINZ_DISCID tag (older / non-MusicRipper rips).

    The first FLAC found per album folder wins; subsequent FLACs in the
    same folder are skipped (they share the same DiscId by construction).

.PARAMETER LibraryRoot
    Path to the music library root. Defaults to `cfg.LibraryRoot`.

.PARAMETER Force
    Replace any existing index file. By default the tool merges new
    findings into the existing index so manually-recorded entries are
    preserved.

.EXAMPLE
    PS> ./src/tools/Build-LibraryDiscIndex.ps1
    PS> ./src/tools/Build-LibraryDiscIndex.ps1 -LibraryRoot 'E:\digitize\MusicRipper'
#>

[CmdletBinding()]
param(
    [string]$LibraryRoot,
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
. (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')

if (-not $LibraryRoot) {
    $cfg = Read-RipperConfig
    $LibraryRoot = $cfg.LibraryRoot
}
if (-not (Test-Path -LiteralPath $LibraryRoot -PathType Container)) {
    throw "LibraryRoot not found: $LibraryRoot"
}

Start-RipperLog -Context 'build-library-disc-index' | Out-Null
Write-RipperLog INFO 'BuildLibraryIndex' "Scanning library: $LibraryRoot"

$metaflac = Get-MetaflacPath
$indexPath = Get-RipperLibraryDiscIndexPath -LibraryRoot $LibraryRoot

if ($Force -and (Test-Path -LiteralPath $indexPath)) {
    Write-RipperLog INFO 'BuildLibraryIndex' "-Force: removing existing index $indexPath."
    Remove-Item -LiteralPath $indexPath -Force
}

$reviewRoot = (Join-Path $LibraryRoot '_ReviewQueue').TrimEnd('\') + '\'
$indexRoot  = (Join-Path $LibraryRoot '.musicripper').TrimEnd('\') + '\'

$albumsSeen = @{}   # albumPath -> $true (so we only probe one FLAC per folder)
$added      = 0
$skipped    = 0
$noTag      = 0

# Reuse a single existing index read so we don't re-parse for every entry.
$existing = Get-RipperLibraryDiscIndex -LibraryRoot $LibraryRoot

Get-ChildItem -LiteralPath $LibraryRoot -Recurse -File -Filter '*.flac' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $flac     = $_
        $album    = $flac.Directory.FullName
        $albumKey = $album.ToLowerInvariant()

        if ($album.StartsWith($reviewRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
        if ($album.StartsWith($indexRoot,  [StringComparison]::OrdinalIgnoreCase)) { return }
        if ($albumsSeen.ContainsKey($albumKey)) { $skipped++; return }
        $albumsSeen[$albumKey] = $true

        $tagOut = & $metaflac '--show-tag=MUSICBRAINZ_DISCID' $flac.FullName 2>$null
        if (-not $tagOut) { $noTag++; return }
        # `metaflac --show-tag=K` emits 'K=value' on a single line, possibly
        # repeated if multiple K tags exist. Take the first non-empty value.
        $line = ($tagOut | Where-Object { $_ -match '^MUSICBRAINZ_DISCID=' } | Select-Object -First 1)
        if (-not $line) { $noTag++; return }
        $discId = $line.Substring('MUSICBRAINZ_DISCID='.Length).Trim()
        if (-not $discId) { $noTag++; return }

        # Build a friendly label from the folder layout (last two
        # segments: <Artist>\<Album (Year)>). Falls back to the bare
        # leaf if the structure looks unusual.
        $albumLeaf  = Split-Path -Leaf $album
        $artistLeaf = Split-Path -Leaf (Split-Path -Parent $album)
        $label = if ($artistLeaf -and $albumLeaf) { "$artistLeaf - $albumLeaf" } else { $albumLeaf }

        if (-not $Force -and $existing.ContainsKey($discId)) {
            Write-RipperLog INFO 'BuildLibraryIndex' "Skip (already indexed): $discId -> $album"
            return
        }

        try {
            Add-RipperLibraryDiscIndexEntry `
                -LibraryRoot $LibraryRoot `
                -DiscId      $discId `
                -Path        $album `
                -Label       $label `
                -Source      'library'
            $added++
        } catch {
            Write-RipperLog WARN 'BuildLibraryIndex' "Failed to index ${album}: $($_.Exception.Message)"
        }
    }

Write-RipperLog INFO 'BuildLibraryIndex' "Done. Added=$added, skipped-dup-folder=$skipped, no-discid-tag=$noTag."
Write-Host ""
Write-Host "Library DiscId index built." -ForegroundColor Green
Write-Host "  Index file:        $indexPath"
Write-Host "  Albums added:      $added"
Write-Host "  Albums skipped:    $skipped (multiple FLACs in the same folder)"
Write-Host "  No DISCID tag:     $noTag (older rips, non-MusicRipper FLACs)"

Stop-RipperLog
