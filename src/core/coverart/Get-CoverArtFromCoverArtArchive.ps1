<#
.SYNOPSIS
    Cover-art provider: Cover Art Archive (CAA, MusicBrainz-tied).

.DESCRIPTION
    The original cover-art source. Requires an MB ReleaseMbid (so this
    only fires when the chosen metadata candidate came from MB or the
    merged candidate inherited an MB ReleaseMbid).

    Pipeline position:
        Plug-in for the cover-art chain orchestrated by
        src/core/coverart/Get-CoverArt.ps1.

    Provider contract (every cover-art provider returns this shape):
        Source : 'CoverArtArchive' | 'iTunesSearch' | 'Deezer' | ...
        Bytes  : [byte[]] image bytes, or $null when the provider had
                 nothing for this candidate
        Url    : URL the bytes came from (for logging / diagnostics)
        Diagnostic : optional [string]

    Returns Bytes=$null on 404 or any HTTP error -- the chain orchestrator
    will fall through to the next provider in line. The provider does NOT
    throw on network errors so a single dead source doesn't kill the rip.

.NOTES
    Why 1200px and not the original: see Get-DiscMetadata.ps1
    Get-RipperCoverArt .NOTES (same rationale, same URL).
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'src\lib\Logging.psd1') -Force

function Invoke-CoverArtArchiveProvider {
<#
.SYNOPSIS
    Cover-art provider entry point: try Cover Art Archive for a candidate.

.PARAMETER Candidate
    The chosen metadata candidate. Must carry .ReleaseMbid (and .HasCoverArt
    is consulted as a hint -- when MB explicitly says the release has no
    front art we skip the round-trip).

.EXAMPLE
    PS> $r = Invoke-CoverArtArchiveProvider -Candidate $best
    PS> $r.Bytes.Length
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject]$Candidate)

    $hasMbid    = $Candidate.PSObject.Properties['ReleaseMbid'] -and $Candidate.ReleaseMbid
    $hasFront   = $Candidate.PSObject.Properties['HasCoverArt'] -and $Candidate.HasCoverArt
    if (-not $hasMbid) {
        return [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$null; Url=$null; Diagnostic='No ReleaseMbid on candidate.' }
    }
    if ($hasMbid -and $Candidate.PSObject.Properties['HasCoverArt'] -and -not $hasFront) {
        # MB told us there's no front art -- skip the round-trip.
        return [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$null; Url=$null; Diagnostic='MB release record reports no front art.' }
    }

    $url = "https://coverartarchive.org/release/$($Candidate.ReleaseMbid)/front-1200"
    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 30 -UseBasicParsing | Out-Null
            $bytes = [System.IO.File]::ReadAllBytes($tmp)
            Write-RipperLog INFO 'Get-CoverArt' "CAA: got $($bytes.Length) bytes from $url"
            return [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$bytes; Url=$url; Diagnostic=$null }
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            $msg = "404 (no cover at $url)"
        }
        Write-RipperLog INFO 'Get-CoverArt' "CAA: $msg"
        return [pscustomobject]@{ Source='CoverArtArchive'; Bytes=$null; Url=$url; Diagnostic=$msg }
    }
}
