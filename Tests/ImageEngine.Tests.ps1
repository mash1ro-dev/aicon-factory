# Run on Windows 11 / Windows PowerShell 5.1:
# powershell.exe -NoProfile -File .\Tests\ImageEngine.Tests.ps1
# No Pester/module download is required. Fixtures stay under Tests/.work and are removed.
[CmdletBinding()]
param(
    [string]$AppRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Root = (Join-Path $PSScriptRoot '.work')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Drawing
if (-not ('Aicon.ImageEngine' -as [type])) {
    Add-Type -Path (Join-Path $AppRoot 'App\ImageEngine.cs') -ReferencedAssemblies @('System.Drawing.dll', 'System.Core.dll')
}
$script:Passed = 0
$script:Failed = 0
$work = Join-Path $Root ('AiconEngineTests_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Test) {
    try { & $Test; $script:Passed++; Write-Host ('PASS ' + $Name) -ForegroundColor Green }
    catch { $script:Failed++; Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red }
}
function Assert-Throws([scriptblock]$Test, [string]$Match = '') {
    $caught = $null
    try { & $Test | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected an exception.'
    if ($Match) { Assert-True ($caught.ToString() -match $Match) ('Unexpected error: ' + $caught.ToString()) }
}
function New-Png([string]$Path, [int]$Width, [int]$Height, [Drawing.Rectangle]$Rect, [Drawing.Color]$Color) {
    $bitmap = New-Object Drawing.Bitmap($Width, $Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $brush = New-Object Drawing.SolidBrush($Color)
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        if ($Rect.Width -gt 0 -and $Rect.Height -gt 0) { $graphics.FillRectangle($brush, $Rect) }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
}
function Get-PngInfo([byte[]]$Bytes) {
    $stream = New-Object IO.MemoryStream(,$Bytes)
    $bitmap = New-Object Drawing.Bitmap($stream)
    try {
        $left = $bitmap.Width; $top = $bitmap.Height; $right = -1; $bottom = -1
        for ($y = 0; $y -lt $bitmap.Height; $y++) {
            for ($x = 0; $x -lt $bitmap.Width; $x++) {
                if ($bitmap.GetPixel($x, $y).A -gt 0) {
                    if ($x -lt $left) { $left = $x }; if ($x -gt $right) { $right = $x }
                    if ($y -lt $top) { $top = $y }; if ($y -gt $bottom) { $bottom = $y }
                }
            }
        }
        [pscustomobject]@{ Width = $bitmap.Width; Height = $bitmap.Height; Left = $left; Top = $top;
            Right = $right; Bottom = $bottom; VisibleWidth = $right - $left + 1; VisibleHeight = $bottom - $top + 1;
            CornerAlpha = $bitmap.GetPixel(0, 0).A; Center = $bitmap.GetPixel([int]($bitmap.Width / 2), [int]($bitmap.Height / 2)) }
    } finally { $bitmap.Dispose(); $stream.Dispose() }
}
try {
    $source = Join-Path $work 'source.png'
    New-Png $source 100 80 (New-Object Drawing.Rectangle(30, 20, 40, 20)) ([Drawing.Color]::FromArgb(255, 220, 50, 100))
    $hashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $modifiedBefore = [IO.File]::GetLastWriteTimeUtc($source)
    $result = $null
    Test-Case 'Trim, aspect ratio, centered padding, and transparent corners' {
        $script:result = [Aicon.ImageEngine]::Process($source)
        Assert-True ($result.SourceWidth -eq 100 -and $result.SourceHeight -eq 80) 'Incorrect input dimensions.'
        Assert-True ($result.TrimmedWidth -eq 40 -and $result.TrimmedHeight -eq 20) 'Transparent bounds were not trimmed exactly.'
        $frame = Get-PngInfo $result.Preview
        Assert-True ($frame.Width -eq 256 -and $frame.Height -eq 256) 'Preview is not 256x256.'
        Assert-True ($frame.Left -ge 19 -and $frame.Left -le 21) 'Horizontal padding is not about 8%.'
        Assert-True ([math]::Abs(($frame.Width - 1 - $frame.Right) - $frame.Left) -le 1) 'Horizontal centering is wrong.'
        Assert-True ([math]::Abs(($frame.Height - 1 - $frame.Bottom) - $frame.Top) -le 1) 'Vertical centering is wrong.'
        Assert-True ([math]::Abs($frame.VisibleWidth / $frame.VisibleHeight - 2.0) -lt 0.05) 'Aspect ratio changed.'
        Assert-True ($frame.CornerAlpha -eq 0 -and $frame.Center.A -eq 255) 'Alpha transparency was lost.'
    }
    Test-Case 'ICO directory has all seven correctly offset PNG frames' {
        Assert-True ($null -ne $result) 'Initial conversion did not complete.'
        [byte[]]$ico = $result.Ico
        Assert-True ([BitConverter]::ToUInt16($ico, 0) -eq 0) 'Reserved ICO header is incorrect.'
        Assert-True ([BitConverter]::ToUInt16($ico, 2) -eq 1) 'File is not ICO.'
        Assert-True ([BitConverter]::ToUInt16($ico, 4) -eq 7) 'Incorrect frame count.'
        $sizes = @(16, 24, 32, 48, 64, 128, 256)
        $expectedOffset = 118
        for ($i = 0; $i -lt 7; $i++) {
            $entry = 6 + 16 * $i; $size = $sizes[$i]
            $encodedDimension = $size; if ($size -eq 256) { $encodedDimension = 0 }
            Assert-True ($ico[$entry] -eq $encodedDimension -and $ico[$entry + 1] -eq $encodedDimension) 'ICO dimensions are incorrect.'
            Assert-True ([BitConverter]::ToUInt16($ico, $entry + 4) -eq 1) 'ICO planes are incorrect.'
            Assert-True ([BitConverter]::ToUInt16($ico, $entry + 6) -eq 32) 'ICO bit depth is incorrect.'
            $length = [BitConverter]::ToUInt32($ico, $entry + 8)
            $offset = [BitConverter]::ToUInt32($ico, $entry + 12)
            Assert-True ($offset -eq $expectedOffset) 'ICO offset is incorrect.'
            Assert-True ($length -eq $result.Frames[$size].Length) 'ICO frame length is incorrect.'
            Assert-True (($offset + $length) -le $ico.Length) 'ICO frame points outside the file.'
            Assert-True ($ico[$offset] -eq 137 -and $ico[$offset + 1] -eq 80) 'ICO frame is not PNG-compressed.'
            [byte[]]$embedded = New-Object byte[] $length
            [Array]::Copy($ico, $offset, $embedded, 0, $length)
            Assert-True ([Convert]::ToBase64String($embedded) -eq [Convert]::ToBase64String($result.Frames[$size])) 'Embedded PNG differs from preview frame.'
            $frame = Get-PngInfo $embedded
            Assert-True ($frame.Width -eq $size -and $frame.Height -eq $size) 'PNG size differs from directory size.'
            Assert-True ($frame.CornerAlpha -eq 0) 'Frame corner is not transparent.'
            $expectedOffset += $length
        }
        Assert-True ($expectedOffset -eq $ico.Length) 'Trailing or missing ICO data.'
    }
    Test-Case 'Input is unchanged and supports read-only files' {
        [IO.File]::SetAttributes($source, [IO.FileAttributes]::ReadOnly)
        try { $null = [Aicon.ImageEngine]::Process($source) }
        finally { [IO.File]::SetAttributes($source, [IO.FileAttributes]::Normal) }
        Assert-True ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -eq $hashBefore) 'Original bytes changed.'
        Assert-True ([IO.File]::GetLastWriteTimeUtc($source) -eq $modifiedBefore) 'Original modification time changed.'
    }
    Test-Case 'Any nonzero alpha counts as content' {
        $path = Join-Path $work 'alpha-one.png'
        New-Png $path 16 16 (New-Object Drawing.Rectangle(2, 3, 10, 8)) ([Drawing.Color]::FromArgb(1, 255, 0, 0))
        $r = [Aicon.ImageEngine]::Process($path)
        Assert-True ($r.TrimmedWidth -eq 10 -and $r.TrimmedHeight -eq 8) 'Alpha=1 content was discarded.'
    }
    Test-Case 'Single pixel is valid and remains centered' {
        $path = Join-Path $work 'one-pixel.png'
        New-Png $path 3 5 (New-Object Drawing.Rectangle(1, 2, 1, 1)) ([Drawing.Color]::White)
        $r = [Aicon.ImageEngine]::Process($path)
        Assert-True ($r.TrimmedWidth -eq 1 -and $r.TrimmedHeight -eq 1) 'Single pixel was lost.'
        Assert-True ((Get-PngInfo $r.Preview).Center.A -gt 0) 'Single pixel output is invisible.'
    }
    Test-Case 'Entirely transparent input is rejected' {
        $path = Join-Path $work 'empty.png'
        New-Png $path 20 20 ([Drawing.Rectangle]::Empty) ([Drawing.Color]::Transparent)
        Assert-Throws { [Aicon.ImageEngine]::Process($path) } 'completely transparent'
    }
    Test-Case 'Portrait aspect ratio is preserved' {
        $path = Join-Path $work 'portrait.png'
        New-Png $path 30 100 (New-Object Drawing.Rectangle(10, 10, 10, 80)) ([Drawing.Color]::RoyalBlue)
        $r = [Aicon.ImageEngine]::Process($path)
        $f = Get-PngInfo $r.Preview
        Assert-True ([math]::Abs($f.VisibleHeight / $f.VisibleWidth - 8.0) -lt 0.4) 'Portrait aspect ratio changed.'
    }
    Test-Case 'JPEG input receives transparent padding without background removal' {
        $path = Join-Path $work 'photo.JPEG'
        $b = New-Object Drawing.Bitmap(80, 40)
        $g = [Drawing.Graphics]::FromImage($b)
        try { $g.Clear([Drawing.Color]::White); $b.Save($path, [Drawing.Imaging.ImageFormat]::Jpeg) }
        finally { $g.Dispose(); $b.Dispose() }
        $r = [Aicon.ImageEngine]::Process($path)
        Assert-True ($r.TrimmedWidth -eq 80 -and $r.TrimmedHeight -eq 40) 'JPEG background was incorrectly removed.'
        $f = Get-PngInfo $r.Preview
        Assert-True ($f.Center.A -eq 255 -and $f.Center.R -ge 250 -and $f.CornerAlpha -eq 0) 'JPEG opacity or padding is incorrect.'
    }
    Test-Case 'Unicode and special characters in paths' {
        $path = Join-Path $work '画像 & image (1).png'
        Copy-Item -LiteralPath $source -Destination $path
        $r = [Aicon.ImageEngine]::Process($path)
        Assert-True ($r.Ico.Length -gt 118) 'Unicode path conversion failed.'
    }
    Test-Case 'Malformed, truncated, and mislabeled files are rejected' {
        $path = Join-Path $work 'bad.png'; [IO.File]::WriteAllText($path, 'not an image')
        Assert-Throws { [Aicon.ImageEngine]::Process($path) }
        $path = Join-Path $work 'wrong.jpg'; Copy-Item -LiteralPath $source -Destination $path
        Assert-Throws { [Aicon.ImageEngine]::Process($path) } 'extension'
        [byte[]]$bytes = [IO.File]::ReadAllBytes($source)
        $path = Join-Path $work 'truncated.png'; [IO.File]::WriteAllBytes($path, $bytes[0..($bytes.Length - 5)])
        Assert-Throws { [Aicon.ImageEngine]::Process($path) }
        $bytes[40] = $bytes[40] -bxor 1
        $path = Join-Path $work 'crc-error.png'; [IO.File]::WriteAllBytes($path, $bytes)
        Assert-Throws { [Aicon.ImageEngine]::Process($path) } 'damaged'
    }
    Test-Case 'Dimension and file-byte limits are checked before decode' {
        [byte[]]$bytes = [IO.File]::ReadAllBytes($source)
        $bytes[16] = 0; $bytes[17] = 1; $bytes[18] = 0; $bytes[19] = 0
        $path = Join-Path $work 'huge-header.png'; [IO.File]::WriteAllBytes($path, $bytes)
        Assert-Throws { [Aicon.ImageEngine]::Process($path) } 'safety limit'
        $path = Join-Path $work 'huge-file.png'
        $stream = [IO.File]::Create($path)
        try { $stream.SetLength([long]([Aicon.ImageEngine]::MaximumFileBytes + 1)) } finally { $stream.Dispose() }
        Assert-Throws { [Aicon.ImageEngine]::Process($path) } '64 MiB'
    }
    Test-Case 'Bundled lossless WebP decode preserves alpha and trim' {
        $decoder = Join-Path $AppRoot 'App\Native\dwebp.exe'
        Assert-True ([IO.File]::Exists($decoder)) 'Required bundled decoder is missing.'
        [Aicon.ImageEngine]::ConfigureWebPDecoder($decoder)
        $path = Join-Path $work 'lossless.webp'
        [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String('UklGRiwAAABXRUJQVlA4TB8AAAAvD8ACEA8wKIM8UPMf8CDMNtpv/qYHcXOI6P8EcGeRAA=='))
        $r = [Aicon.ImageEngine]::Process($path)
        Assert-True ($r.SourceWidth -eq 16 -and $r.SourceHeight -eq 12 -and $r.TrimmedWidth -eq 7 -and $r.TrimmedHeight -eq 5) 'WebP alpha or dimensions are wrong.'
        $f = Get-PngInfo $r.Preview
        Assert-True ($f.Center.A -eq 255 -and $f.CornerAlpha -eq 0 -and $f.Center.R -eq 200) 'WebP color or alpha changed.'
    }
    Test-Case 'Lossy and extended-alpha WebP decode' {
        $path = Join-Path $work 'lossy.webp'
        [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String('UklGRjYAAABXRUJQVlA4ICoAAABwAQCdASoQAAwAAUAmJaACdAF1AAD+7/24Hxcv/7nA//2cD//ZwP4kAAA='))
        $r = [Aicon.ImageEngine]::Process($path)
        Assert-True ($r.TrimmedWidth -eq 16 -and $r.TrimmedHeight -eq 12) 'Lossy WebP failed.'
        $path = Join-Path $work 'extended.webp'
        [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String('UklGRnwAAABXRUJQVlA4WAoAAAAQAAAADwAACwAAQUxQSBgAAAABDzD/ERGCMNtov/mbHsTNIaL/E8CdRQJWUDggPgAAAHABAJ0BKhAADAABQCYloAJ0AYhAAP75lwf//GBt5EX/+P/5cR/uko/+kBOgamfa//FuP91lH/1gP13SgAAA'))
        $r = [Aicon.ImageEngine]::Process($path)
        Assert-True ($r.TrimmedWidth -eq 7 -and $r.TrimmedHeight -eq 5) 'Extended WebP alpha failed.'
    }
    Test-Case 'Animated WebP gets a specific rejection' {
        [byte[]]$bytes = [Convert]::FromBase64String('UklGRnwAAABXRUJQVlA4WAoAAAAQAAAADwAACwAAQUxQSBgAAAABDzD/ERGCMNtov/mbHsTNIaL/E8CdRQJWUDggPgAAAHABAJ0BKhAADAABQCYloAJ0AYhAAP75lwf//GBt5EX/+P/5cR/uko/+kBOgamfa//FuP91lH/1gP13SgAAA')
        $bytes[20] = $bytes[20] -bor 2
        $path = Join-Path $work 'animation.webp'; [IO.File]::WriteAllBytes($path, $bytes)
        Assert-Throws { [Aicon.ImageEngine]::Process($path) } 'Animated WebP'
    }
    Test-Case 'Repeated processing does not retain input locks' {
        for ($i = 0; $i -lt 10; $i++) { $null = [Aicon.ImageEngine]::Process($source) }
        $exclusive = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $exclusive.Dispose()
    }
} finally {
    if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
Write-Host ('ImageEngine: {0} passed, {1} failed.' -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { throw ('ImageEngine failures: ' + $script:Failed) }
