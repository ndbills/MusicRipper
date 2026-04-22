<#
.SYNOPSIS
    Dump the Vorbis comments + PICTURE block summary from one or more
    FLAC files. Quick verification that Phase 5 tagging actually wrote
    what we think it wrote.

.DESCRIPTION
    Wraps `metaflac.exe --list` so you don't have to remember the path
    or the block-type flags. Resolves metaflac via the same
    Get-MetaflacPath helper Write-Tags uses, so this stays in sync with
    whatever winget actually installed.

    Accepts either:
      - one or more FLAC file paths, OR
      - a folder (lists every *.flac under it, non-recursive).

    For each file, prints a one-line header then the Vorbis comments,
    followed by a single line summarising any embedded PICTURE block
    (type / mime / dimensions / size in bytes).

    Why this exists separately from Write-Tags:
      Windows Explorer's built-in FLAC property handler is unreliable
      and frequently shows blank Title/Album columns even when the
      tags are perfectly written. Use this tool to confirm what's
      actually in the file. If foobar2000 / Plex / Picard see the tags
      and this tool sees the tags, Explorer is the problem, not us.
      (Install Icaros if you want Explorer columns to work — see
      docs/TROUBLESHOOTING.md.)

.PARAMETER Path
    File path, multiple file paths, or a folder. Folders are listed
    non-recursively. Pipeline-friendly.

.PARAMETER NoPictures
    Skip the PICTURE-block summary line. Useful when piping into a
    diff or a grep.

.EXAMPLE
    PS> ./src/tools/Show-FlacTags.ps1 'E:\digitize\MusicRipper\Mormon Tabernacle Choir\Spirit of the Season (2007)'
    Lists tags for every track in the album folder.

.EXAMPLE
    PS> ./src/tools/Show-FlacTags.ps1 .\01.flac, .\02.flac
    Lists tags for two specific files.

.EXAMPLE
    PS> Get-ChildItem -Recurse -Filter *.flac | ./src/tools/Show-FlacTags.ps1 -NoPictures
    Recursive scan via the pipeline.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName', 'PSPath')]
    [string[]] $Path,

    [switch] $NoPictures
)

begin {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

    $script:metaflac = Get-MetaflacPath
    if (-not (Test-Path -LiteralPath $script:metaflac -PathType Leaf)) {
        throw "metaflac.exe not found at: $script:metaflac"
    }

    function Resolve-FlacFiles {
        param([string]$InputPath)
        if (-not (Test-Path -LiteralPath $InputPath)) {
            Write-Warning "Path not found: $InputPath"
            return @()
        }
        $item = Get-Item -LiteralPath $InputPath
        if ($item.PSIsContainer) {
            return @(Get-ChildItem -LiteralPath $item.FullName -File -Filter '*.flac' |
                     Sort-Object Name)
        }
        if ($item.Extension -ne '.flac') {
            Write-Warning "Skipping non-FLAC file: $($item.FullName)"
            return @()
        }
        return @($item)
    }
}

process {
    foreach ($p in $Path) {
        foreach ($file in (Resolve-FlacFiles -InputPath $p)) {
            Write-Host ''
            Write-Host ("===== {0} =====" -f $file.FullName) -ForegroundColor Cyan

            # Vorbis comments (the human-readable tag set).
            & $script:metaflac --list --block-type=VORBIS_COMMENT $file.FullName

            if (-not $NoPictures) {
                # PICTURE-block summary. metaflac dumps a lot of bytes
                # when it lists this block in full; we only want the
                # one-liner per picture.
                $pic = & $script:metaflac --list --block-type=PICTURE $file.FullName 2>$null
                if ($LASTEXITCODE -eq 0 -and $pic) {
                    $type   = ($pic | Select-String -Pattern '^\s*type:\s*(.+)$'         | ForEach-Object { $_.Matches[0].Groups[1].Value }) -join ', '
                    $mime   = ($pic | Select-String -Pattern '^\s*MIME type:\s*(.+)$'    | ForEach-Object { $_.Matches[0].Groups[1].Value }) -join ', '
                    $width  = ($pic | Select-String -Pattern '^\s*width:\s*(\d+)$'       | ForEach-Object { $_.Matches[0].Groups[1].Value }) -join ', '
                    $height = ($pic | Select-String -Pattern '^\s*height:\s*(\d+)$'      | ForEach-Object { $_.Matches[0].Groups[1].Value }) -join ', '
                    $bytes  = ($pic | Select-String -Pattern '^\s*data length:\s*(\d+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value }) -join ', '
                    if ($type -or $mime) {
                        Write-Host ("  PICTURE: type={0} mime={1} {2}x{3} ({4} bytes)" `
                            -f $type, $mime, $width, $height, $bytes) -ForegroundColor DarkGray
                    } else {
                        Write-Host '  PICTURE: (none)' -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host '  PICTURE: (none)' -ForegroundColor DarkGray
                }
            }
        }
    }
}
