<#
.SYNOPSIS
    诊断：桌面上的快捷方式图标是否被降级成「白纸 + 蓝色箭头」通用图标。

.DESCRIPTION
    Windows 画快捷方式图标时，会调用「图标处理器」去目标程序里抽图。
    正常情况下，桌面上的 .lnk 与放在文档 / 下载 / 临时目录里的 .lnk 应该取到同样的图标。
    如果桌面上的取不到、换个目录就能取到，说明桌面命名空间（Desktop Namespace）的绑定坏了。

    本脚本用 SHGetFileInfo 取外壳图标，统计「彩色像素」作为客观指标：
        ≈ 54   白纸通用图标（只有中间那个蓝色箭头是彩的）
        ≥ 200  正常彩色程序图标（常见 500 ~ 900）

    只读，不修改任何系统设置。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-DesktopIcons.ps1
#>

[CmdletBinding()]
param(
    # 白纸上限：彩色像素少于这个值，判定为白纸图标
    [int]$WhiteMax = 80,
    # 正常下限：彩色像素大于等于这个值，判定为正常
    [int]$NormalMin = 200
)

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;

public static class ShellIconProbe
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int    iIcon;
        public uint   dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]  public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes,
        ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    private const uint SHGFI_ICON           = 0x000000100;
    private const uint SHGFI_SHELLICONSIZE  = 0x000000004;

    /// <summary>取外壳图标，返回「彩色像素数」。取不到返回 -1。</summary>
    public static int CountColorPixels(string path)
    {
        SHFILEINFO fi = new SHFILEINFO();
        IntPtr ret = SHGetFileInfo(path, 0, ref fi,
            (uint)Marshal.SizeOf(typeof(SHFILEINFO)),
            SHGFI_ICON | SHGFI_SHELLICONSIZE);

        if (ret == IntPtr.Zero || fi.hIcon == IntPtr.Zero)
            return -1;

        try
        {
            using (Icon icon = Icon.FromHandle(fi.hIcon))
            using (Bitmap bmp = icon.ToBitmap())
            {
                int colored = 0;
                for (int x = 0; x < bmp.Width; x++)
                {
                    for (int y = 0; y < bmp.Height; y++)
                    {
                        Color c = bmp.GetPixel(x, y);
                        if (c.A > 8 &&
                            (Math.Abs(c.R - c.G) > 15 ||
                             Math.Abs(c.G - c.B) > 15 ||
                             Math.Abs(c.R - c.B) > 15))
                        {
                            colored++;
                        }
                    }
                }
                return colored;
            }
        }
        finally
        {
            DestroyIcon(fi.hIcon);
        }
    }
}
'@ -ReferencedAssemblies System.Drawing

# ---------------------------------------------------------------- 主流程

$desktop = [Environment]::GetFolderPath('Desktop')

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  桌面快捷方式图标诊断' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  桌面路径 : $desktop"
Write-Host "  判据     : 彩色像素 < $WhiteMax 视为白纸；≥ $NormalMin 视为正常"
Write-Host ''

if (-not (Test-Path -LiteralPath $desktop)) {
    Write-Host "  桌面路径不存在，无法诊断。" -ForegroundColor Red
    exit 2
}

$lnks = @(Get-ChildItem -LiteralPath $desktop -Filter *.lnk -File -ErrorAction SilentlyContinue)

if ($lnks.Count -eq 0) {
    Write-Host '  桌面上没有任何快捷方式（.lnk），没什么可诊断的。' -ForegroundColor Yellow
    exit 0
}

Write-Host "  共找到 $($lnks.Count) 个快捷方式" -ForegroundColor Cyan
Write-Host ''
Write-Host ('  {0,-46} {1,-10} {2}' -f '文件名', '彩色像素', '判定') -ForegroundColor Gray
Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkGray

$whiteCount   = 0
$normalCount  = 0
$unknownCount = 0

foreach ($f in $lnks) {
    $px = [ShellIconProbe]::CountColorPixels($f.FullName)

    if ($px -lt 0) {
        $verdict = '取不到'
        $color   = 'DarkYellow'
        $unknownCount++
    }
    elseif ($px -lt $WhiteMax) {
        $verdict = '白纸（异常）'
        $color   = 'Red'
        $whiteCount++
    }
    elseif ($px -ge $NormalMin) {
        $verdict = '正常'
        $color   = 'Green'
        $normalCount++
    }
    else {
        $verdict = '可疑'
        $color   = 'Yellow'
        $unknownCount++
    }

    $name = $f.Name
    if ($name.Length -gt 44) { $name = $name.Substring(0, 41) + '...' }

    Write-Host ('  {0,-46} {1,-10} {2}' -f $name, $px, $verdict) -ForegroundColor $color
}

Write-Host ('  ' + ('-' * 74)) -ForegroundColor DarkGray
Write-Host "  正常: $normalCount    白纸: $whiteCount    可疑/取不到: $unknownCount"
Write-Host ''

# ------------------------------------------------- 对照测试：同一文件换到临时目录

if ($whiteCount -gt 0) {
    $sample = $null
    foreach ($f in $lnks) {
        if ([ShellIconProbe]::CountColorPixels($f.FullName) -lt $WhiteMax) { $sample = $f; break }
    }

    if ($sample) {
        $tempDir  = $env:TEMP
        $tempCopy = Join-Path $tempDir ('ico_probe_' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.lnk')

        try {
            Copy-Item -LiteralPath $sample.FullName -Destination $tempCopy -Force -ErrorAction Stop
            $pxTemp = [ShellIconProbe]::CountColorPixels($tempCopy)

            Write-Host '  对照测试（把同一个快捷方式复制到临时目录再取图）:' -ForegroundColor Cyan
            Write-Host ("    在桌面   : {0}  （{1}）" -f [ShellIconProbe]::CountColorPixels($sample.FullName),
                $(if ([ShellIconProbe]::CountColorPixels($sample.FullName) -lt $WhiteMax) { '白纸' } else { '正常' }))
            Write-Host ("    在临时目录: {0}" -f $pxTemp)

            if ($pxTemp -ge $NormalMin) {
                Write-Host ''
                Write-Host '    结论：同一个文件换个目录就正常，' -ForegroundColor Green
                Write-Host '          说明文件本身没坏，是「桌面这个位置」的图标通道出了问题。' -ForegroundColor Green
                Write-Host '          → 可以用 Fix-DesktopIcons.ps1 修复。' -ForegroundColor Green
            }
            else {
                Write-Host ''
                Write-Host ('    结论：换目录也取不到正常图标（{0}），问题不在桌面路径。' -f $pxTemp) -ForegroundColor Yellow
                Write-Host '          建议检查系统文件：sfc /scannow 与 DISM /Online /Cleanup-Image /RestoreHealth' -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "    对照测试失败：$($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        finally {
            if (Test-Path -LiteralPath $tempCopy) { Remove-Item -LiteralPath $tempCopy -Force -ErrorAction SilentlyContinue }
        }
    }
}
elseif ($normalCount -eq $lnks.Count) {
    Write-Host '  结论：桌面所有快捷方式图标都正常，无需修复。' -ForegroundColor Green
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
