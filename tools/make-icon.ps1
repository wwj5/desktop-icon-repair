# 生成 assets\icon.ico：蓝底圆角方块 + 白色循环箭头（修复/刷新）
# 输出多种尺寸，供 exe 图标与窗口标题使用。
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutFile) { $OutFile = Join-Path $repo 'assets\icon.ico' }

function New-MasterBitmap {
    $S = 256
    $bmp = New-Object Drawing.Bitmap($S, $S, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([Drawing.Color]::Transparent)

    # 圆角方块底
    $margin = 6
    $side = $S - 2 * $margin
    $rad = 56
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc($margin, $margin, $rad, $rad, 180, 90)
    $path.AddArc($margin + $side - $rad, $margin, $rad, $rad, 270, 90)
    $path.AddArc($margin + $side - $rad, $margin + $side - $rad, $rad, $rad, 0, 90)
    $path.AddArc($margin, $margin + $side - $rad, $rad, $rad, 90, 90)
    $path.CloseFigure()
    $rect = New-Object Drawing.Rectangle($margin, $margin, $side, $side)
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, [Drawing.Color]::FromArgb(255, 74, 144, 255), [Drawing.Color]::FromArgb(255, 20, 68, 150), 60.0)
    $g.FillPath($brush, $path)
    $brush.Dispose()
    $path.Dispose()

    # 内侧浅色描边，增加层次
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(60, 255, 255, 255), 3)
    $pen.Alignment = [Drawing.Drawing2D.PenAlignment]::Inset
    $g.DrawPath($pen, (New-Object Drawing.Drawing2D.GraphicsPath))
    $pen.Dispose()

    # 白色循环箭头：两段圆弧 + 两个箭头尖
    $cx = 128.0
    $cy = 128.0
    $r = 66.0
    $penW = 24.0
    $arrow = New-Object Drawing.Pen([Drawing.Color]::White, $penW)
    $arrow.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
    $box = New-Object Drawing.RectangleF(($cx - $r), ($cy - $r), (2 * $r), (2 * $r))

    # 两段各 128°，中间留 52° 缺口
    $g.DrawArc($arrow, $box, 16, 128)
    $g.DrawArc($arrow, $box, 196, 128)

    # 箭头尖
    foreach ($deg in @(144.0, 324.0)) {
        $rad2 = $deg * [Math]::PI / 180.0
        $px = $cx + $r * [Math]::Cos($rad2)
        $py = $cy + $r * [Math]::Sin($rad2)
        $tx = - [Math]::Sin($rad2)
        $ty = [Math]::Cos($rad2)
        $nx = [Math]::Cos($rad2)
        $ny = [Math]::Sin($rad2)
        $pts = @(
            (New-Object Drawing.PointF(($px + $tx * 34), ($py + $ty * 34))),
            (New-Object Drawing.PointF(($px - $tx * 10 + $nx * 26), ($py - $ty * 10 + $ny * 26))),
            (New-Object Drawing.PointF(($px - $tx * 10 - $nx * 26), ($py - $ty * 10 - $ny * 26)))
        )
        $g.FillPolygon([Drawing.Brushes]::White, $pts)
    }
    $arrow.Dispose()

    $g.Dispose()
    return $bmp
}

function Get-IcoBytes {
    param([Drawing.Bitmap]$Master, [int[]]$Sizes, [string]$PreviewDir)

    $entries = @()
    foreach ($s in $Sizes) {
        $bmp = New-Object Drawing.Bitmap($s, $s, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([Drawing.Color]::Transparent)
        $g.DrawImage($Master, (New-Object Drawing.Rectangle(0, 0, $s, $s)))
        $g.Dispose()

        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $ms.Dispose()
        $entries += [pscustomobject]@{ Size = $s; Bytes = $bytes }

        if ($PreviewDir) {
            if (-not (Test-Path -LiteralPath $PreviewDir)) { New-Item -ItemType Directory -Path $PreviewDir -Force | Out-Null }
            $bmp.Save((Join-Path $PreviewDir ("icon_" + $s + ".png")), [Drawing.Imaging.ImageFormat]::Png)
        }
        $bmp.Dispose()
    }

    $msIco = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($msIco)
    $bw.Write([UInt16]0)              # reserved
    $bw.Write([UInt16]1)              # type = icon
    $bw.Write([UInt16]$entries.Count)
    $offset = 6 + 16 * $entries.Count
    foreach ($e in $entries) {
        $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
        $bw.Write([Byte]$dim)
        $bw.Write([Byte]$dim)
        $bw.Write([Byte]0)
        $bw.Write([Byte]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]32)
        $bw.Write([UInt32]$e.Bytes.Length)
        $bw.Write([UInt32]$offset)
        $offset += $e.Bytes.Length
    }
    foreach ($e in $entries) { $bw.Write($e.Bytes) }
    $bw.Flush()
    $out = $msIco.ToArray()
    $bw.Dispose()
    return $out
}

$master = New-MasterBitmap
$bytes = Get-IcoBytes -Master $master -Sizes @(16, 24, 32, 48, 64, 128, 256) -PreviewDir (Join-Path $env:TEMP 'ico_preview_out')
$master.Dispose()

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllBytes($OutFile, $bytes)

# 回读验证：能当图标加载，且尺寸齐全
$icon = New-Object Drawing.Icon($OutFile)
Write-Output ('  已生成 ' + $OutFile)
Write-Output ('  大小   ' + (Get-Item -LiteralPath $OutFile).Length + ' 字节，条目主尺寸 ' + $icon.Width + '×' + $icon.Height)
$icon.Dispose()
