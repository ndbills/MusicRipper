<#
.SYNOPSIS
    Manual WPF smoke harness for Show-RipperMetadataDialog. Builds a
    fake metadata object from one of the tests/fixtures/mb-*.json files
    and pops the dialog so you can click around without inserting a
    real disc.

.DESCRIPTION
    Not part of the shipping product. Lives next to the dialog so
    Phase 3's "verify" step (each of 3 fixtures + cancel + edits
    round-trip) can be performed offline.

.PARAMETER Fixture
    Which fixture to load. Defaults to single-match.

.PARAMETER WithCoverArt
    If set, attaches a synthetic 16x16 PNG byte array as CoverArtBytes
    so you can confirm the cover Image control renders.

.EXAMPLE
    PS> ./src/ui/Show-MetadataDialog.smoke.ps1 -Fixture multi -WithCoverArt
#>

[CmdletBinding()]
param(
    [ValidateSet('single','multi','none')]
    [string]$Fixture = 'single',

    [switch]$WithCoverArt
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'src\core\Get-DiscMetadata.ps1')
. (Join-Path $repoRoot 'src\ui\Show-MetadataDialog.ps1')

$fixtureMap = @{
    single = @{ File = 'mb-single-match.json'; DiscId = 'Wn8eRBtfLDfM0qjYPdxrz.Zjs_I-' }
    multi  = @{ File = 'mb-multi-match.json';  DiscId = 'abcdefMULTIabcdefMULTI______' }
    none   = @{ File = 'mb-no-match.json';     DiscId = 'noMATCHnoMATCHnoMATCHnoMATCH'  }
}

$f       = $fixtureMap[$Fixture]
$jsonPath = Join-Path $repoRoot ('tests\fixtures\' + $f.File)
$json     = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

$cands = ConvertFrom-MusicBrainzDiscIdResponse -Response $json -DiscId $f.DiscId
$best  = Select-BestMusicBrainzCandidate -Candidates $cands

if ($best -and $WithCoverArt) {
    # Tiny solid-red 16x16 PNG, base64-encoded.
    $b64 = 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAFElEQVR4nGP8z8DwHwMDAwMTAxQAACAAB/93qJxhAAAAAElFTkSuQmCC'
    $bytes = [Convert]::FromBase64String($b64)
    $best | Add-Member -NotePropertyName CoverArtBytes -NotePropertyValue $bytes -Force
}

$status = if (@($cands).Count -eq 0) { 'NoMatch' }
          elseif (@($cands).Count -gt 1) { 'MultiMatch' }
          else { 'Match' }

$meta = [pscustomobject]@{
    DiscId     = $f.DiscId
    Status     = $status
    BestMatch  = $best
    Candidates = @($cands)
}

# Re-search just returns the same fake fixture (to prove the wiring works).
$onResearch = {
    Write-Host '[smoke] Re-search clicked; returning the same fixture.' -ForegroundColor Yellow
    $meta
}.GetNewClosure()

Write-Host "[smoke] Fixture=$Fixture  Status=$status  Candidates=$(@($cands).Count)" -ForegroundColor Cyan

$result = Show-RipperMetadataDialog -Metadata $meta -OnResearch $onResearch

Write-Host ''
Write-Host '[smoke] Result:' -ForegroundColor Cyan
Write-Host "  Action: $($result.Action)"
if ($result.Metadata) {
    Write-Host "  Album:        $($result.Metadata.Album)"
    Write-Host "  Album Artist: $($result.Metadata.AlbumArtist)"
    Write-Host "  Year:         $($result.Metadata.Year)"
    Write-Host "  Compilation:  $($result.Metadata.IsCompilation)"
    Write-Host "  Tracks:"
    foreach ($t in @($result.Metadata.Tracks)) {
        Write-Host ("    {0,2}. {1}  --  {2}" -f $t.Number, $t.Title, $t.Artist)
    }
}
