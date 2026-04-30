<#
.SYNOPSIS
    Phase 7: Promote a tagged _ReviewQueue album folder into the main
    library tree using the standard Plex-friendly layout.

.DESCRIPTION
    Pipeline position:
        Standalone helper. Run by the engineer (or a power-user
        parent) after they have re-tagged a _ReviewQueue entry in
        MusicBrainz Picard. Reads the now-correct tags off the
        per-track FLACs, computes the target library path with the
        same helper Move-RipToLibrary uses, then moves the per-track
        FLACs + cover.jpg + .cue + .log into place. The
        review-queue artifacts (REVIEW.txt and the _image\
        single-file image folder) are discarded by default --
        they're inspection scratch, not library content.

    Lookup ladder for tag values (first hit wins):
        1. -AlbumArtist / -Album / -Year / -IsCompilation parameters
           (explicit overrides; useful when tags are still partial)
        2. ALBUMARTIST + ALBUM + DATE/YEAR + COMPILATION on
           track-1 of the source folder, read via metaflac --show-tag
        3. (Compilation auto-detect) ALBUMARTIST == 'Various Artists'

    Disc-index seeding: if the source folder's REVIEW.txt or the
    track-1 MUSICBRAINZ_DISCID tag yields a disc id, the new
    library path is recorded in <LibraryRoot>\.musicripper\discids.json
    via Add-RipperLibraryDiscIndexEntry so cross-session
    duplicate-disc detection (Phase 5.8) trips on re-insert.
    Failures here are logged and swallowed -- never fatal.

    Returns:
        [pscustomobject]@{
            Source            = absolute source folder path
            Target            = absolute destination folder path
            IsSideBySide      = $true if `[rip N]` suffix was used
            FilesMoved        = int
            FilesSkipped      = int (REVIEW.txt + _image\ contents
                                     when -KeepReviewArtifacts is off)
            DiscIdSeeded      = $true / $false
            AlbumArtist, Album, Year, IsCompilation, DiscId
        }

    Sister tool: src/tools/Build-LibraryDiscIndex.ps1 also reads
    MUSICBRAINZ_DISCID off promoted albums and rebuilds the index
    from scratch, so seeding here is a convenience, not a contract.

.PARAMETER AlbumFolder
    Absolute path to the source folder under <LibraryRoot>\_ReviewQueue\.

.PARAMETER LibraryRoot
    Absolute path to the music library root. Optional; defaults to
    cfg.LibraryRoot from %LOCALAPPDATA%\MusicRipper\config.json.

.PARAMETER AlbumArtist
    Override the AlbumArtist read from track-1 tags. Use when
    Picard's MUSICBRAINZ_ALBUMARTIST differs from what you want on
    disk.

.PARAMETER Album
    Override the Album read from track-1 tags.

.PARAMETER Year
    Override the album Year (used in the `<Album> (YYYY)\` folder
    suffix). 0 / unset means "no year suffix".

.PARAMETER IsCompilation
    Force-route under `Various Artists\` regardless of tag values.

.PARAMETER Force
    Overwrite an existing library target file-by-file.

.PARAMETER AllowSideBySide
    When the target already exists and -Force is not given, land in
    `<Album> (<Year>) [rip 2]` (then `[rip 3]`, ...) instead of
    throwing. Same square-bracket convention Move-RipToLibrary uses
    so Plex doesn't parse the suffix as a year.

.PARAMETER KeepReviewArtifacts
    Move REVIEW.txt and the _image\ subfolder into the destination
    too. Default behaviour is to discard them (delete from source)
    once the move succeeds.

.EXAMPLE
    PS> ./src/tools/Move-FromReviewQueue.ps1 `
            'E:\digitize\MusicRipper\_ReviewQueue\UNKNOWN - 2026-04-12 - 12tracks 51m23s - abc123'
    Reads tags from the first FLAC, computes
    'E:\digitize\MusicRipper\<AlbumArtist>\<Album> (<Year>)\', moves
    per-track FLACs + cover.jpg + .cue + .log over, deletes
    REVIEW.txt + _image\, removes the now-empty source folder.

.EXAMPLE
    PS> ./src/tools/Move-FromReviewQueue.ps1 -WhatIf $reviewFolder
    Show what would move without touching disk.

.NOTES
    Same-volume moves are essentially free (Move-Item does a
    directory entry rename); cross-volume falls back to copy + delete
    transparently. metaflac.exe is required (provided by winget xiph
    flac); resolved via Get-MetaflacPath.

    Pure-logic helpers exported for Pester:
      - Get-RipperReviewPromotionPlan : disk-free target/file plan.
      - Read-RipperFlacTagValue       : metaflac --show-tag wrapper
        (mocked in tests via stub flac.cmd / mocked metaflac path).
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([pscustomobject])]
param(
    # Not [Parameter(Mandatory)] so dot-sourcing this script for its
    # helpers (Pester) doesn't trigger an interactive prompt before the
    # MyInvocation guard at the bottom kicks in. Validated by hand
    # below when the script actually runs the promote workflow.
    [Parameter(Position = 0)]
    [string] $AlbumFolder,

    [string] $LibraryRoot,

    [string] $AlbumArtist,
    [string] $Album,
    [int]    $Year,
    [Nullable[bool]] $IsCompilation,

    [switch] $Force,
    [switch] $AllowSideBySide,
    [switch] $KeepReviewArtifacts
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'src\lib\Common.psd1')  -Force
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Config.psd1')  -Force
. (Join-Path $repoRoot 'src\core\Move-ToLibrary.ps1')
. (Join-Path $repoRoot 'src\core\Get-LibraryDiscIndex.ps1')


# --- helpers (exported for Pester) ----------------------------------------

function Read-RipperFlacTagValue {
<#
.SYNOPSIS
    Read the first value of a Vorbis comment from a FLAC via metaflac.

.DESCRIPTION
    Returns $null when the tag is missing, empty, or metaflac fails.
    Pulled out as a reusable helper because Update-AlbumTags.ps1
    has the exact same pattern; we can fold the dupes together in a
    later refactor.

.PARAMETER Flac
    Absolute path to the FLAC file.

.PARAMETER Name
    Vorbis comment name (case-insensitive in the FLAC spec; metaflac
    matches case-insensitive on lookup).

.PARAMETER MetaflacPath
    Absolute path to metaflac.exe. Defaults to Get-MetaflacPath
    so unit tests can inject a stub.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Flac,
        [Parameter(Mandatory)] [string] $Name,
        [string] $MetaflacPath
    )
    if (-not $MetaflacPath) { $MetaflacPath = Get-MetaflacPath }
    $out = & $MetaflacPath "--show-tag=$Name" $Flac 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if (-not $out) { return $null }
    $line = @($out)[0]
    if ($line -match '^[^=]+=(.*)$') {
        $v = $Matches[1].Trim()
        if ($v) { return $v }
    }
    $null
}


function Get-RipperReviewPromotionPlan {
<#
.SYNOPSIS
    Pure-logic target-folder + file-classification planner for
    Move-FromReviewQueue.

.DESCRIPTION
    No I/O. Given the source folder path, the resolved tag values,
    the library root, and a list of file/folder names found in the
    source, returns an object describing:
      - the absolute target folder (as Get-RipperLibraryTargetDir
        would compute it for a Library-routed rip),
      - which source items move into the target ('library content':
        per-track *.flac at the source root + cover.jpg + *.cue +
        *.log + the standalone <Album>.cue/.log if present),
      - which source items are review-queue artifacts to discard
        (REVIEW.txt + the _image\ subfolder + stray dispatcher
        sidecars).

    The discard list is empty when -KeepReviewArtifacts is set --
    the caller will move them into the target alongside library
    content.

    Files we have never seen in a Phase-5 _ReviewQueue album are
    treated conservatively: they go on the 'unknown' list and are
    moved (not discarded), so a parent who dropped a stray PDF or a
    Picard side-car (.txt / .opus / .m3u) into the folder doesn't
    lose it.

.PARAMETER SourceFolder
    Absolute path to the _ReviewQueue album folder.

.PARAMETER LibraryRoot
    Absolute path to the music library root.

.PARAMETER Metadata
    pscustomobject with at least { AlbumArtist, Album, Year,
    IsCompilation }.

.PARAMETER DiscId
    MusicBrainz disc id. Required by Get-RipperLibraryTargetDir's
    signature even though library-routed rips don't use it.

.PARAMETER SourceEntries
    Array of items as returned by Get-ChildItem -LiteralPath
    $SourceFolder (top-level, not recursive). Each item must have
    .Name, .PSIsContainer.

.PARAMETER KeepReviewArtifacts
    When true, REVIEW.txt + _image\ go on the move list.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SourceFolder,
        [Parameter(Mandatory)] [string] $LibraryRoot,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string] $DiscId,
        [Parameter(Mandatory)] [object[]] $SourceEntries,
        [switch] $KeepReviewArtifacts
    )

    # Synthetic Quality: empty RoutingPrefix routes to main library.
    $quality = [pscustomobject]@{ RoutingPrefix = '' }
    $target  = Get-RipperLibraryTargetDir `
                  -LibraryRoot $LibraryRoot `
                  -Metadata    $Metadata `
                  -Quality     $quality `
                  -DiscId      $DiscId

    $move    = [System.Collections.Generic.List[object]]::new()
    $discard = [System.Collections.Generic.List[object]]::new()

    foreach ($e in $SourceEntries) {
        if ($e.PSIsContainer) {
            if ($e.Name -ieq '_image') {
                if ($KeepReviewArtifacts) { $move.Add($e) | Out-Null }
                else                      { $discard.Add($e) | Out-Null }
            } else {
                # Unknown subfolder -- preserve it.
                $move.Add($e) | Out-Null
            }
            continue
        }

        if ($e.Name -ieq 'REVIEW.txt') {
            if ($KeepReviewArtifacts) { $move.Add($e) | Out-Null }
            else                      { $discard.Add($e) | Out-Null }
            continue
        }

        # Dispatcher / debug sidecars never belong in the library.
        if ($e.Name -like '*-dispatcher.log') {
            $discard.Add($e) | Out-Null
            continue
        }

        # Everything else (FLACs, cover.jpg, .cue, .log, stray files
        # the parent dropped in) moves over verbatim.
        $move.Add($e) | Out-Null
    }

    [pscustomobject]@{
        Target  = $target
        Move    = $move.ToArray()
        Discard = $discard.ToArray()
    }
}


function Resolve-RipperReviewSourceMetadata {
<#
.SYNOPSIS
    Build a Metadata pscustomobject from track-1 Vorbis comments,
    overlaid with explicit param overrides.

.DESCRIPTION
    Internal-ish helper, exported only because it's pure (no
    interactive prompts) and worth a Pester lock-in.

    Reads ALBUMARTIST, ALBUM, DATE/YEAR, COMPILATION,
    MUSICBRAINZ_DISCID off $FirstFlac via the supplied
    Read-RipperFlacTagValue scriptblock (so the test rig can
    inject a hashtable instead of metaflac). DATE-style values
    like '1973-03-01' degrade to the year prefix. COMPILATION
    is interpreted via [System.Xml.XmlConvert]::ToBoolean (the
    same way Picard writes it: '1' / 'true').

    Returns a pscustomobject with fields:
        AlbumArtist, Album, Year, IsCompilation, DiscId,
        TotalDiscs (always 1 -- multi-disc review-queue albums
        don't exist; each disc lands in its own folder).
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $FirstFlac,
        [Parameter(Mandatory)] [scriptblock] $ReadTag,
        [string] $OverrideAlbumArtist,
        [string] $OverrideAlbum,
        [int]    $OverrideYear,
        [Nullable[bool]] $OverrideIsCompilation
    )

    $tagAlbumArtist  = & $ReadTag $FirstFlac 'ALBUMARTIST'
    if (-not $tagAlbumArtist) { $tagAlbumArtist = & $ReadTag $FirstFlac 'ARTIST' }
    $tagAlbum        = & $ReadTag $FirstFlac 'ALBUM'
    $tagDate         = & $ReadTag $FirstFlac 'DATE'
    if (-not $tagDate) { $tagDate = & $ReadTag $FirstFlac 'YEAR' }
    $tagCompilation  = & $ReadTag $FirstFlac 'COMPILATION'
    $tagDiscId       = & $ReadTag $FirstFlac 'MUSICBRAINZ_DISCID'

    $albumArtist = if ($OverrideAlbumArtist) { $OverrideAlbumArtist } else { $tagAlbumArtist }
    $album       = if ($OverrideAlbum)       { $OverrideAlbum }       else { $tagAlbum }

    $year = 0
    if ($OverrideYear -gt 0) {
        $year = $OverrideYear
    } elseif ($tagDate) {
        if ($tagDate -match '^(\d{4})') { $year = [int]$Matches[1] }
    }

    $isComp = $false
    if ($null -ne $OverrideIsCompilation) {
        $isComp = [bool]$OverrideIsCompilation
    } elseif ($tagCompilation) {
        try { $isComp = [System.Xml.XmlConvert]::ToBoolean($tagCompilation.ToLowerInvariant()) }
        catch { $isComp = ($tagCompilation -eq '1') }
    }
    if (-not $isComp -and $albumArtist -and $albumArtist -ieq 'Various Artists') {
        $isComp = $true
    }

    [pscustomobject]@{
        AlbumArtist   = $albumArtist
        Album         = $album
        Year          = $year
        IsCompilation = $isComp
        DiscId        = $tagDiscId
        TotalDiscs    = 1
    }
}


function Read-RipperReviewTxtDiscId {
<#
.SYNOPSIS
    Extract the DiscId line from a REVIEW.txt body. Returns $null if
    the file is missing or no DiscId line is present.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ReviewTxtPath)
    if (-not (Test-Path -LiteralPath $ReviewTxtPath -PathType Leaf)) { return $null }
    $body = Get-Content -LiteralPath $ReviewTxtPath -Raw
    if ($body -match '(?im)^DiscId:\s*([0-9A-Za-z._\-]+)\s*$') {
        $v = $Matches[1].Trim()
        if ($v -and $v -ne 'none') { return $v }
    }
    $null
}


# --- main -----------------------------------------------------------------

# When dot-sourced (e.g. by Pester for helper-only access), MyInvocation's
# InvocationName is '.'; in that case we just publish the helpers and exit
# without running the promote workflow.
if ($MyInvocation.InvocationName -eq '.' -or $MyInvocation.Line -match 'Get-Command|Get-Help') {
    return
}

if (-not $AlbumFolder) {
    throw 'AlbumFolder is required. Pass the absolute path to the _ReviewQueue album folder you want to promote.'
}
if (-not (Test-Path -LiteralPath $AlbumFolder -PathType Container)) {
    throw "AlbumFolder not found: $AlbumFolder"
}
$AlbumFolder = (Resolve-Path -LiteralPath $AlbumFolder).ProviderPath

# Resolve LibraryRoot from config if not supplied.
if (-not $LibraryRoot) {
    try { $cfg = Import-RipperConfig } catch { throw "LibraryRoot not supplied and config could not be loaded: $($_.Exception.Message)" }
    if (-not $cfg.PSObject.Properties['LibraryRoot'] -or -not $cfg.LibraryRoot) {
        throw 'LibraryRoot not supplied and not present in config.json.'
    }
    $LibraryRoot = [string]$cfg.LibraryRoot
}
if (-not (Test-Path -LiteralPath $LibraryRoot -PathType Container)) {
    throw "LibraryRoot does not exist: $LibraryRoot"
}

$logPath = Start-RipperLog -Context 'move-from-reviewqueue'
Write-RipperLog INFO 'Move-FromReviewQueue' "Promoting '$AlbumFolder' -> library root '$LibraryRoot'."

try {
    # --- Find a probe FLAC ------------------------------------------------
    $flacs = @(Get-ChildItem -LiteralPath $AlbumFolder -File -Filter '*.flac' | Sort-Object Name)
    if ($flacs.Count -eq 0) {
        throw "No *.flac files at the root of '$AlbumFolder'. Did you tag the per-track FLACs (not the _image\ single-file image)?"
    }
    $firstFlac = $flacs[0].FullName

    # --- Read tags --------------------------------------------------------
    $metaflac = Get-MetaflacPath
    if (-not (Test-Path -LiteralPath $metaflac -PathType Leaf)) {
        throw "metaflac.exe not found at: $metaflac. Re-run setup\Install-Dependencies.ps1."
    }
    $readTag = { param($f, $n) Read-RipperFlacTagValue -Flac $f -Name $n -MetaflacPath $metaflac }

    # Cast Bool param to Nullable[bool] for the helper signature.
    $overrideComp = $null
    if ($PSBoundParameters.ContainsKey('IsCompilation')) { $overrideComp = [Nullable[bool]]$IsCompilation }

    $md = Resolve-RipperReviewSourceMetadata `
              -FirstFlac             $firstFlac `
              -ReadTag               $readTag `
              -OverrideAlbumArtist   $AlbumArtist `
              -OverrideAlbum         $Album `
              -OverrideYear          $Year `
              -OverrideIsCompilation $overrideComp

    if (-not $md.AlbumArtist -or -not $md.Album) {
        throw ("Could not determine AlbumArtist and Album from track-1 tags " +
               "(read AlbumArtist='$($md.AlbumArtist)', Album='$($md.Album)'). " +
               "Tag the FLACs in MusicBrainz Picard first, or pass -AlbumArtist / -Album explicitly.")
    }

    # DiscId discovery: tag wins, REVIEW.txt is fallback.
    $discId = $md.DiscId
    if (-not $discId) {
        $discId = Read-RipperReviewTxtDiscId -ReviewTxtPath (Join-Path $AlbumFolder 'REVIEW.txt')
    }
    if (-not $discId) { $discId = '' }

    Write-RipperLog INFO 'Move-FromReviewQueue' (
        "Resolved metadata: AlbumArtist='$($md.AlbumArtist)' Album='$($md.Album)' " +
        "Year=$($md.Year) IsCompilation=$($md.IsCompilation) DiscId='$discId'.")

    # --- Build move plan --------------------------------------------------
    $entries = @(Get-ChildItem -LiteralPath $AlbumFolder -Force)
    $plan = Get-RipperReviewPromotionPlan `
                -SourceFolder        $AlbumFolder `
                -LibraryRoot         $LibraryRoot `
                -Metadata            $md `
                -DiscId              $discId `
                -SourceEntries       $entries `
                -KeepReviewArtifacts:$KeepReviewArtifacts

    $target = $plan.Target

    # --- Resolve collisions ----------------------------------------------
    $isSideBySide = $false
    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        if ($AllowSideBySide) {
            $orig = $target
            for ($n = 2; $n -lt 100; $n++) {
                $candidate = "$orig [rip $n]"
                if (-not (Test-Path -LiteralPath $candidate)) {
                    $target       = $candidate
                    $isSideBySide = $true
                    Write-RipperLog INFO 'Move-FromReviewQueue' "Side-by-side: '$orig' exists, using '$target'."
                    break
                }
            }
            if (-not $isSideBySide) {
                throw "Tried 99 side-by-side suffixes for '$orig' and they're all taken. Clean up before re-running."
            }
        } else {
            throw ("Target already exists: '$target'. Pass -Force to overwrite file-by-file, " +
                   "or -AllowSideBySide to land in '<Album> (Year) [rip N]'.")
        }
    }

    # --- Execute ----------------------------------------------------------
    if (-not $PSCmdlet.ShouldProcess($AlbumFolder, "Promote -> $target")) {
        Write-RipperLog INFO 'Move-FromReviewQueue' '(WhatIf) skipping disk operations.'
        return [pscustomobject]@{
            Source        = $AlbumFolder
            Target        = $target
            IsSideBySide  = $isSideBySide
            FilesMoved    = $plan.Move.Count
            FilesSkipped  = $plan.Discard.Count
            DiscIdSeeded  = $false
            AlbumArtist   = $md.AlbumArtist
            Album         = $md.Album
            Year          = $md.Year
            IsCompilation = $md.IsCompilation
            DiscId        = $discId
            WhatIf        = $true
        }
    }

    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    $moved = 0
    foreach ($item in $plan.Move) {
        $dest = Join-Path $target $item.Name
        if ((Test-Path -LiteralPath $dest) -and -not $Force) {
            # With -AllowSideBySide we landed in a fresh folder above, so
            # this only fires under -Force=false + collision-in-newly-
            # created-empty-target (impossible) OR the rare unknown-file
            # case where parents pre-populated the destination by hand.
            throw "Destination file already exists and -Force not set: $dest"
        }
        Move-Item -LiteralPath $item.FullName -Destination $target -Force:$Force | Out-Null
        $moved++
    }

    foreach ($item in $plan.Discard) {
        try {
            if ($item.PSIsContainer) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force
            } else {
                Remove-Item -LiteralPath $item.FullName -Force
            }
            Write-RipperLog INFO 'Move-FromReviewQueue' "Discarded review artifact: $($item.Name)"
        } catch {
            Write-RipperLog WARN 'Move-FromReviewQueue' "Failed to discard '$($item.Name)': $($_.Exception.Message)"
        }
    }

    # --- Remove now-empty source folder ----------------------------------
    try {
        $remaining = @(Get-ChildItem -LiteralPath $AlbumFolder -Force)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $AlbumFolder -Force
            Write-RipperLog INFO 'Move-FromReviewQueue' "Removed empty source folder: $AlbumFolder"
        } else {
            Write-RipperLog WARN 'Move-FromReviewQueue' "Source folder not empty ($($remaining.Count) item(s) remain); leaving in place."
        }
    } catch {
        Write-RipperLog WARN 'Move-FromReviewQueue' "Failed to remove source folder: $($_.Exception.Message)"
    }

    # --- Seed disc-id index (best-effort) --------------------------------
    $discIdSeeded = $false
    if ($discId) {
        try {
            $label = "$($md.AlbumArtist) - $($md.Album)"
            if ($md.Year) { $label = "$label ($($md.Year))" }
            Add-RipperLibraryDiscIndexEntry `
                -LibraryRoot $LibraryRoot `
                -DiscId      $discId `
                -Path        $target `
                -Label       $label `
                -Source      'library'
            $discIdSeeded = $true
        } catch {
            Write-RipperLog WARN 'Move-FromReviewQueue' "Failed to seed discids.json for '$discId': $($_.Exception.Message)"
        }
    } else {
        Write-RipperLog INFO 'Move-FromReviewQueue' 'No DiscId available -- skipping discids.json seed.'
    }

    Write-RipperLog INFO 'Move-FromReviewQueue' "Promoted to '$target' (moved=$moved, discarded=$($plan.Discard.Count), discid-seeded=$discIdSeeded)."

    [pscustomobject]@{
        Source        = $AlbumFolder
        Target        = $target
        IsSideBySide  = $isSideBySide
        FilesMoved    = $moved
        FilesSkipped  = $plan.Discard.Count
        DiscIdSeeded  = $discIdSeeded
        AlbumArtist   = $md.AlbumArtist
        Album         = $md.Album
        Year          = $md.Year
        IsCompilation = $md.IsCompilation
        DiscId        = $discId
        WhatIf        = $false
    }
}
finally {
    Stop-RipperLog
}
