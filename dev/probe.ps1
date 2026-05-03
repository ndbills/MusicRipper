$ErrorActionPreference = "Stop"
. .\src\core\Move-ToLibrary.ps1
Import-Module .\src\lib\Logging.psd1 -Force
Import-Module .\src\lib\Common.psd1 -Force
Import-Module .\src\lib\RipHelpers.psd1 -Force

$root = Join-Path $env:TEMP ("probe-" + [guid]::NewGuid())
$rip  = Join-Path $root "rip"
$lib  = Join-Path $root "lib"
New-Item -ItemType Directory -Path $rip -Force | Out-Null
New-Item -ItemType Directory -Path $lib -Force | Out-Null
1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $rip "$_.flac") -Value "x" }
$meta = [pscustomobject]@{ AlbumArtist="X"; Album="Y"; Year="2007"; ReleaseDate="2007-01-01"; Tracks=@(); Source="t"; DiscNumber=1; TotalDiscs=1 }
$q    = [pscustomobject]@{ Status="Verified"; ARConfidence=10; CTDBConfidence=10 }

Move-RipToLibrary -RipFolder $rip -LibraryRoot $lib -Metadata $meta -Quality $q -DiscId "d" | Out-Null
1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $rip "$_.flac") -Value "x" }

try {
    Move-RipToLibrary -RipFolder $rip -LibraryRoot $lib -Metadata $meta -Quality $q -DiscId "d" | Out-Null
} catch {
    Write-Host "TYPE: $($_.Exception.GetType().FullName)"
    Write-Host "HAS DATA: $($null -ne $_.Exception.Data)"
    Write-Host "KEYS: $(@($_.Exception.Data.Keys) -join ",")"
    Write-Host "Contains TargetExists: $($_.Exception.Data.Contains("TargetExists"))"
    Write-Host "VAL: $($_.Exception.Data["TargetExists"])"
    Write-Host "INNER: $($_.Exception.InnerException)"
}
Remove-Item $root -Recurse -Force
