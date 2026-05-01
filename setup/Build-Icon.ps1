<#
.SYNOPSIS
    Build assets\musicripper.ico (multi-resolution) from assets\musicripper.png.

.DESCRIPTION
    Pipeline position:
        Asset build script. Run once whenever assets\musicripper.png is
        replaced; commit the regenerated .ico alongside the new .png.
        Not part of the per-machine setup chain (Install-MusicRipper.ps1
        does NOT run this -- the .ico is committed to the repo).

    Why we hand-roll the ICO container instead of letting System.Drawing
    do it: System.Drawing.Icon.Save() only writes whichever single
    resolution was loaded. Windows Explorer / shortcut icons want a
    multi-resolution .ico (16, 24, 32, 48, 64, 128, 256) so the right
    bitmap is picked at every zoom level. Building the ICONDIR /
    ICONDIRENTRY container by hand and embedding PNG-encoded frames is
    well-supported on Windows Vista+ and is what modern toolchains
    (e.g. magick, png2ico) emit.

    File format reference:
        https://en.wikipedia.org/wiki/ICO_(file_format)
        - 6-byte ICONDIR header: reserved=0, type=1 (icon), count=N
        - N x 16-byte ICONDIRENTRY: width, height, palette, reserved,
          planes, bitcount, image-bytes-size, image-bytes-offset
        - Concatenated PNG bytes for each frame.
        - Width / Height fields are stored as 0 for 256 px (and only 256).

.PARAMETER SourcePng
    Path to the master PNG. Must be square. Defaults to
    <repo>\assets\musicripper.png.

.PARAMETER OutputIco
    Output .ico path. Defaults to <repo>\assets\musicripper.ico.

.PARAMETER Sizes
    Resolutions (in pixels) to include. The default merges Windows'
    standard icon sizes (16, 24, 32, 48, 64, 128, 256) with a couple
    of intermediate ones useful for WPF window chrome at various DPI
    scales (30, 36, 60, 72, 96). One PNG file is emitted per size and
    every size is also embedded into the multi-res .ico.

    Note: the .ico spec stores width/height in a single byte each, so
    the only special-cased value is 256 (encoded as 0). Sizes between
    1 and 255 are written verbatim; >256 is rejected by Windows.

.PARAMETER PaddingPercent
    How much breathing room to leave around the disc inside each
    rendered ICO frame, expressed as a percentage of the frame side.
    Default 6 (= 3 % on each edge). Lower => disc fills more of the
    icon (better for taskbar / Alt-Tab visibility); higher => more
    breathing room (closer to the source PNG composition).

    The source PNG is left unchanged on disk; this only affects what
    gets baked into the .ico container. The source has ~12 % transparent
    border around the disc itself + ~20 % below for the drop shadow,
    which makes the disc appear small at 32 px taskbar size; with the
    default crop the disc fills ~94 % of each frame width.

.PARAMETER NoCrop
    Skip the auto-crop step entirely and render each frame from the
    full source canvas. Useful for diagnosing alpha-bbox detection
    issues, or when the source PNG is already tightly cropped.

.PARAMETER SkipPngFiles
    Build only the multi-resolution .ico; do not emit per-size PNG
    files. Useful when you only need a refreshed icon for the
    Desktop shortcut and don't want to churn the per-size assets.

.EXAMPLE
    PS> ./setup/Build-Icon.ps1
    Regenerate assets/musicripper.ico from assets/musicripper.png with
    the default tight crop.

.EXAMPLE
    PS> ./setup/Build-Icon.ps1 -PaddingPercent 12
    More generous breathing room (~6 % each edge); useful if the icon
    feels visually cramped at 256 px in Explorer's "Extra large" view.

.EXAMPLE
    PS> ./setup/Build-Icon.ps1 -NoCrop
    Render frames from the full 1024x1024 source -- equivalent to the
    pre-crop behaviour.

.EXAMPLE
    PS> ./setup/Build-Icon.ps1 -Sizes 24, 48 -SkipPngFiles
    Build a small .ico with just two frames; skip the per-size PNGs.

.NOTES
    Requires System.Drawing.Common (ships with PowerShell 7 on Windows).
    Pure-PowerShell otherwise -- no winget / ImageMagick / external dep.
#>

[CmdletBinding()]
param(
    [string]   $SourcePng,
    [string]   $OutputIco,
    [int[]]    $Sizes          = @(16, 24, 30, 32, 36, 48, 60, 64, 72, 96, 128, 256),
    [double]   $PaddingPercent = 6,
    [switch]   $NoCrop,
    [switch]   $SkipPngFiles
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SourcePng) { $SourcePng = Join-Path $repoRoot 'assets\musicripper.png' }
if (-not $OutputIco) { $OutputIco = Join-Path $repoRoot 'assets\musicripper.ico' }

if (-not (Test-Path -LiteralPath $SourcePng)) {
    throw "Source PNG not found at '$SourcePng'."
}

# .ico stores width / height in a single byte each; 256 is the only
# special case (encoded as 0). Sizes outside 1..256 are not valid.
foreach ($s in $Sizes) {
    if ($s -lt 1 -or $s -gt 256) {
        throw "Sizes must be between 1 and 256 (got $s). The Windows .ico format cannot represent larger frames."
    }
}

Add-Type -AssemblyName System.Drawing | Out-Null

# Load source bitmap once.
$srcBytes = [System.IO.File]::ReadAllBytes($SourcePng)
$srcMs    = [System.IO.MemoryStream]::new($srcBytes)
$src      = [System.Drawing.Bitmap]::new($srcMs)

if ($src.Width -ne $src.Height) {
    Write-Warning "Source PNG is not square ($($src.Width)x$($src.Height)) -- output may look stretched."
}

# --- Auto-crop ---------------------------------------------------------
# Find the bounding box of "the disc proper" (alpha >= opaqueThreshold)
# so we can ignore the soft drop shadow that bleeds into the bottom
# transparent margin. Taskbar / Alt-Tab icons are rendered at 32-48 px
# where every percent of frame area matters; the source PNG was
# composed for 1024 px banner use and has ~12 % transparent border
# around the disc + ~20 % below for the shadow.
#
# After detecting the bbox we squarify around its center (taking the
# larger dimension), add the requested padding margin, and clamp to
# the canvas. Each frame is then rendered from this cropped sub-rect.
$cropRect = $null
if (-not $NoCrop) {
    $opaqueThreshold = 180
    $sampleStep      = 2

    # Lock raw bitmap bits for fast alpha sampling. GetPixel is
    # ~1000x slower and would make a 1024 px source measurable.
    $rect = [System.Drawing.Rectangle]::new(0, 0, $src.Width, $src.Height)
    $data = $src.LockBits(
        $rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $bytes  = [byte[]]::new($stride * $data.Height)
        [System.Runtime.InteropServices.Marshal]::Copy(
            $data.Scan0, $bytes, 0, $bytes.Length)

        $minX = [int]::MaxValue
        $minY = [int]::MaxValue
        $maxX = -1
        $maxY = -1
        for ($y = 0; $y -lt $src.Height; $y += $sampleStep) {
            $row = $y * $stride
            for ($x = 0; $x -lt $src.Width; $x += $sampleStep) {
                # Format32bppArgb is little-endian BGRA in memory ->
                # alpha is at offset +3 of each 4-byte pixel.
                $a = $bytes[$row + ($x * 4) + 3]
                if ($a -ge $opaqueThreshold) {
                    if ($x -lt $minX) { $minX = $x }
                    if ($y -lt $minY) { $minY = $y }
                    if ($x -gt $maxX) { $maxX = $x }
                    if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }
    } finally {
        $src.UnlockBits($data)
    }

    if ($maxX -lt 0) {
        Write-Warning "Auto-crop: no opaque pixels found (alpha >= $opaqueThreshold). Falling back to full canvas."
    } else {
        # Squarify around the bbox center, then add padding.
        $cx   = ($minX + $maxX) / 2.0
        $cy   = ($minY + $maxY) / 2.0
        $side = [Math]::Max($maxX - $minX, $maxY - $minY)
        $side = [Math]::Round($side * (1 + ($PaddingPercent / 100.0)))

        $left   = [int][Math]::Round($cx - ($side / 2.0))
        $top    = [int][Math]::Round($cy - ($side / 2.0))

        # Clamp to canvas; if clamping would shrink one dimension,
        # shrink the square to match so we keep aspect.
        if ($left -lt 0) { $left = 0 }
        if ($top  -lt 0) { $top  = 0 }
        if (($left + $side) -gt $src.Width)  { $side = $src.Width  - $left }
        if (($top  + $side) -gt $src.Height) { $side = $src.Height - $top  }

        $cropRect = [System.Drawing.Rectangle]::new($left, $top, [int]$side, [int]$side)
        Write-Verbose "Auto-crop: bbox=($minX,$minY)-($maxX,$maxY); square crop=$cropRect (padding $PaddingPercent %)."
    }
}

# Render each requested size to a PNG byte array using high-quality bicubic.
$frames = foreach ($size in $Sizes) {
    $bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.CompositingMode    = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            if ($cropRect) {
                # 5-arg overload: dest rect (in dest), src rect (in source), src unit.
                $destRect = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
                $g.DrawImage($src, $destRect, $cropRect, [System.Drawing.GraphicsUnit]::Pixel)
            } else {
                $g.DrawImage($src, 0, 0, $size, $size)
            }
        } finally { $g.Dispose() }

        $ms = [System.IO.MemoryStream]::new()
        try {
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            [pscustomobject]@{
                Size  = $size
                Bytes = $ms.ToArray()
            }
        } finally { $ms.Dispose() }
    } finally { $bmp.Dispose() }
}

$src.Dispose()
$srcMs.Dispose()

# Emit one PNG per requested size, named musicripper-{N}.png next to
# the source. Useful for WPF Window.Icon = single-frame BitmapImage
# (Set-RipperWindowIcon picks one of these by default).
$writtenPngs = @()
if (-not $SkipPngFiles) {
    $assetsDir = Split-Path -Parent $OutputIco
    foreach ($f in $frames) {
        $pngPath = Join-Path $assetsDir ('musicripper-{0}.png' -f $f.Size)
        [System.IO.File]::WriteAllBytes($pngPath, $f.Bytes)
        $writtenPngs += $pngPath
    }
}

# Build the ICO container.
# Layout: [ICONDIR (6)] [ICONDIRENTRY * N (16 each)] [PNG payloads...]
$dirCount    = $frames.Count
$payloadStart = 6 + (16 * $dirCount)

$out = [System.IO.MemoryStream]::new()
$bw  = [System.IO.BinaryWriter]::new($out)
try {
    # ICONDIR
    $bw.Write([uint16]0)         # reserved
    $bw.Write([uint16]1)         # type: 1 = icon
    $bw.Write([uint16]$dirCount) # image count

    # ICONDIRENTRY for each frame
    $offset = $payloadStart
    foreach ($f in $frames) {
        $w = if ($f.Size -ge 256) { 0 } else { [byte]$f.Size }
        $h = if ($f.Size -ge 256) { 0 } else { [byte]$f.Size }
        $bw.Write([byte]$w)              # width  (0 == 256)
        $bw.Write([byte]$h)              # height (0 == 256)
        $bw.Write([byte]0)               # color count (0 for >= 8bpp)
        $bw.Write([byte]0)               # reserved
        $bw.Write([uint16]1)             # color planes
        $bw.Write([uint16]32)            # bits per pixel
        $bw.Write([uint32]$f.Bytes.Length)  # PNG payload size
        $bw.Write([uint32]$offset)       # offset to payload
        $offset += $f.Bytes.Length
    }

    # PNG payloads, concatenated in the same order
    foreach ($f in $frames) {
        $bw.Write($f.Bytes)
    }

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($OutputIco, $out.ToArray())
} finally {
    $bw.Dispose()
    $out.Dispose()
}

$icoSize = (Get-Item -LiteralPath $OutputIco).Length
$cropDesc = if ($cropRect) { "crop $($cropRect.Width)x$($cropRect.Height) @ ($($cropRect.X),$($cropRect.Y))" } else { 'no crop' }
Write-Host "Wrote $OutputIco  ($([math]::Round($icoSize / 1KB, 1)) KB, sizes: $($Sizes -join ', '), $cropDesc)" -ForegroundColor Green
if ($writtenPngs.Count -gt 0) {
    Write-Host ("Wrote {0} per-size PNGs to {1}\musicripper-{{N}}.png" -f $writtenPngs.Count, (Split-Path -Parent $OutputIco)) -ForegroundColor Green
}
