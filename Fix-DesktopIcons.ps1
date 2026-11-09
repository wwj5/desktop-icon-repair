<#
.SYNOPSIS
    修复 Windows 桌面上快捷方式图标变成「白纸 + 蓝色箭头」的问题。

.DESCRIPTION
    原理：Windows 把桌面当成一个「桌面命名空间」（虚拟容器），它给快捷方式配图标时
    必须调用图标处理器（IconHandler，CLSID {00021401-…}，实现在 windows.storage.dll 里）
    去目标程序抽取图标。当这个容器与桌面路径的绑定坏掉时，这一步失败，系统只能退回
    兜底图标（白纸 + 蓝箭头）。docx / pdf 这类文件走的是「文件关联默认图标」另一条路，
    所以它们的图标一直正常。

    本脚本不修那条坏绑定，而是把桌面换到一条干净路径，让系统重建它：

        1. 完整复制桌面内容到新文件夹（原桌面一个文件不动）
        2. 逐项核对副本数量与大小
        3. 备份两个注册表值（并校验备份文件真实落盘）
        4. 把系统「桌面」位置指向新文件夹
        5. 重启资源管理器
        6. 重新测图标验证

    全程可用 -Restore 回滚。不需要管理员权限（只改 HKCU）。

.PARAMETER NewDesktopPath
    新桌面文件夹的完整路径。默认 %USERPROFILE%\DesktopNew。

.PARAMETER Restore
    回滚：把桌面路径改回 %USERPROFILE%\Desktop，并重启资源管理器。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-DesktopIcons.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-DesktopIcons.ps1 -NewDesktopPath "D:\Desktop"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-DesktopIcons.ps1 -Restore
#>

[CmdletBinding()]
param(
    [string]$NewDesktopPath,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$usfKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$sfKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$defaultDesktop = Join-Path $env:USERPROFILE 'Desktop'
$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$regExe   = Join-Path $env:SystemRoot 'System32\reg.exe'

# ---------------------------------------------------------------- 工具函数

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok   { param([string]$T) Write-Host "    OK   $T" -ForegroundColor Green }
function Write-Warn { param([string]$T) Write-Host "    注意 $T" -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host "    失败 $T" -ForegroundColor Red }

function Set-DesktopPath {
    param([string]$Path)
    New-ItemProperty -Path $usfKey -Name 'Desktop' -Value $Path -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $sfKey  -Name 'Desktop' -Value $Path -PropertyType String       -Force | Out-Null
}

function Restart-Explorer {
    $procs = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    Write-Ok "重启资源管理器（当前 $($procs.Count) 个进程），任务栏会闪一下"
    foreach ($p in $procs) {
        try { $p | Stop-Process -Force -ErrorAction Stop } catch { Write-Warn "结束进程失败: $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 2
    Start-Process explorer.exe
    Start-Sleep -Seconds 4
    $after = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    if ($after.Count -ge 1) { Write-Ok "资源管理器已重启（$($after.Count) 个进程）" }
    else { Write-Bad '资源管理器没有自动重启，请按 Ctrl+Shift+Esc 手动启动 explorer.exe' }
}

# ---------------------------------------------------------------- 图标检测

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

    private const uint SHGFI_ICON          = 0x000000100;
    private const uint SHGFI_SHELLICONSIZE = 0x000000004;

    public static int CountColorPixels(string path)
    {
        SHFILEINFO fi = new SHFILEINFO();
        IntPtr ret = SHGetFileInfo(path, 0, ref fi,
            (uint)Marshal.SizeOf(typeof(SHFILEINFO)),
            SHGFI_ICON | SHGFI_SHELLICONSIZE);

        if (ret == IntPtr.Zero || fi.hIcon == IntPtr.Zero) return -1;

        try
        {
            using (Icon icon = Icon.FromHandle(fi.hIcon))
            using (Bitmap bmp = icon.ToBitmap())
            {
                int colored = 0;
                for (int x = 0; x < bmp.Width; x++)
                    for (int y = 0; y < bmp.Height; y++)
                    {
                        Color c = bmp.GetPixel(x, y);
                        if (c.A > 8 &&
                            (Math.Abs(c.R - c.G) > 15 ||
                             Math.Abs(c.G - c.B) > 15 ||
                             Math.Abs(c.R - c.B) > 15))
                            colored++;
                    }
                return colored;
            }
        }
        finally { DestroyIcon(fi.hIcon); }
    }
}
'@ -ReferencedAssemblies System.Drawing

function Test-IconAt {
    param([string]$LnkPath)
    return [ShellIconProbe]::CountColorPixels($LnkPath)
}

# ---------------------------------------------------------------- 回滚分支

if ($Restore) {
    Write-Step '回滚：把桌面路径改回默认位置'
    $current = [Environment]::GetFolderPath('Desktop')
    Write-Warn "当前桌面路径 : $current"
    Write-Warn "目标（默认）: $defaultDesktop"

    if (-not (Test-Path -LiteralPath $defaultDesktop)) {
        Write-Bad "默认桌面文件夹不存在：$defaultDesktop"
        Write-Bad '请先把原来桌面里的文件放回该文件夹，再运行 -Restore'
        exit 3
    }

    Set-DesktopPath -Path $defaultDesktop
    Write-Ok "注册表已改回 $defaultDesktop"
    Restart-Explorer

    $lnk = @(Get-ChildItem -LiteralPath $defaultDesktop -Filter *.lnk -File -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($lnk) {
        $px = Test-IconAt $lnk.FullName
        Write-Host "    抽查 $($lnk.Name) 彩色像素 = $px" -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '回滚完成。' -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- 修复分支

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  修复：桌面快捷方式图标白纸问题' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

$currentDesktop = [Environment]::GetFolderPath('Desktop')
Write-Host "  当前桌面路径 : $currentDesktop"

if (-not $NewDesktopPath) { $NewDesktopPath = Join-Path $env:USERPROFILE 'DesktopNew' }
Write-Host "  目标新桌面   : $NewDesktopPath"
Write-Host ''

if (-not (Test-Path -LiteralPath $robocopy)) {
    Write-Bad "找不到 robocopy：$robocopy"
    exit 3
}
if (-not (Test-Path -LiteralPath $regExe)) {
    Write-Bad "找不到 reg.exe：$regExe"
    exit 3
}

if ($NewDesktopPath.TrimEnd('\') -eq $currentDesktop.TrimEnd('\')) {
    Write-Bad '目标路径与当前桌面路径相同，没有意义。请用 -NewDesktopPath 指定其他路径。'
    exit 3
}

if (Test-Path -LiteralPath $NewDesktopPath) {
    $existing = @(Get-ChildItem -LiteralPath $NewDesktopPath -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $NewDesktopPath 'desktop.ini'))) {
        Write-Bad "目标文件夹已存在且有内容：$NewDesktopPath"
        Write-Bad '为避免覆盖，请换一个路径：-NewDesktopPath "D:\Desktop"'
        exit 3
    }
    Write-Warn '目标文件夹已存在，将直接使用其中已有内容'
}

Write-Host '  即将执行：复制桌面 → 核对 → 改注册表 → 重启资源管理器' -ForegroundColor Yellow
Write-Host '  请先保存正在编辑的文件。Ctrl+C 可在 5 秒内取消。' -ForegroundColor Yellow
Start-Sleep -Seconds 5

# ---- 1. 基线
Write-Step '1/6 统计当前桌面'
$srcItems = @(Get-ChildItem -LiteralPath $currentDesktop -Force -ErrorAction SilentlyContinue)
$srcFiles = @($srcItems | Where-Object { -not $_.PSIsContainer })
$srcSize  = ($srcFiles | Measure-Object -Property Length -Sum).Sum
if (-not $srcSize) { $srcSize = 0 }
Write-Ok "$($srcItems.Count) 项（文件 $($srcFiles.Count)），共 $([math]::Round($srcSize / 1MB, 2)) MB"

# ---- 2. 复制
Write-Step "2/6 复制到 $NewDesktopPath"
if (-not (Test-Path -LiteralPath $NewDesktopPath)) {
    New-Item -ItemType Directory -Path $NewDesktopPath -Force | Out-Null
}
$null = & $robocopy $currentDesktop $NewDesktopPath /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    Write-Bad "robocopy 失败，退出码 $rc（8 以上表示出错），已中止，未改任何注册表。"
    exit 4
}
Write-Ok "复制完成（robocopy 退出码 $rc）"

# ---- 3. 核对
Write-Step '3/6 核对副本完整性'
$dstItems = @(Get-ChildItem -LiteralPath $NewDesktopPath -Force -ErrorAction SilentlyContinue)
$dstFiles = @($dstItems | Where-Object { -not $_.PSIsContainer })
$dstSize  = ($dstFiles | Measure-Object -Property Length -Sum).Sum
if (-not $dstSize) { $dstSize = 0 }

Write-Host ("    源 : {0} 项 / {1} MB" -f $srcItems.Count, [math]::Round($srcSize / 1MB, 2)) -ForegroundColor Gray
Write-Host ("    副本: {0} 项 / {1} MB" -f $dstItems.Count, [math]::Round($dstSize / 1MB, 2)) -ForegroundColor Gray

if ($dstItems.Count -lt $srcItems.Count) {
    Write-Bad "副本项数少于源（$($dstItems.Count) < $($srcItems.Count)），可能有文件被占用。已中止，未改注册表。"
    Write-Bad "请关闭占用文件的程序后重试，或手动处理后再运行。"
    exit 4
}
Write-Ok '数量核对通过'

# ---- 4. 备份注册表
Write-Step '4/6 备份当前桌面路径设置'
$backupDir = Join-Path $env:TEMP ('DesktopIconRepair_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$bkUsf = Join-Path $backupDir 'UserShellFolders_Desktop.reg'
$bkSf  = Join-Path $backupDir 'ShellFolders_Desktop.reg'

$null = & $regExe export 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' $bkUsf /y
$null = & $regExe export 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'      $bkSf  /y
Start-Sleep -Milliseconds 400

$bkOk = $true
foreach ($b in @($bkUsf, $bkSf)) {
    if (-not (Test-Path -LiteralPath $b)) { Write-Bad "备份文件没有落盘：$b"; $bkOk = $false }
    elseif ((Get-Item -LiteralPath $b).Length -lt 100) { Write-Bad "备份文件异常（过小）：$b"; $bkOk = $false }
    else { Write-Ok "备份 $([IO.Path]::GetFileName($b))  $((Get-Item -LiteralPath $b).Length) 字节" }
}
if (-not $bkOk) {
    Write-Bad '注册表备份失败，已中止。'
    exit 5
}

# ---- 5. 改路径
Write-Step "5/6 把桌面指向 $NewDesktopPath"
Write-Host "    原值 : $((Get-ItemProperty -LiteralPath $usfKey).Desktop)" -ForegroundColor Gray
Set-DesktopPath -Path $NewDesktopPath
Write-Ok "User Shell Folders\Desktop = $((Get-ItemProperty -LiteralPath $usfKey).Desktop)"
Write-Ok "Shell Folders\Desktop      = $((Get-ItemProperty -LiteralPath $sfKey).Desktop)"

# 让 desktop.ini 生效（显示名仍为「桌面」）
try {
    $d = Get-Item -LiteralPath $NewDesktopPath -Force
    if (-not $d.Attributes.ToString().Contains('ReadOnly')) {
        $d.Attributes = $d.Attributes -bor [IO.FileAttributes]::ReadOnly
    }
    Write-Ok '已给新桌面设置 ReadOnly 属性（让 desktop.ini 的显示名生效）'
}
catch { Write-Warn "设置属性失败：$($_.Exception.Message)" }

# ---- 6. 重启并验证
Write-Step '6/6 重启资源管理器并验证'
Restart-Explorer

$probe = @(Get-ChildItem -LiteralPath $NewDesktopPath -Filter *.lnk -File -ErrorAction SilentlyContinue) |
         Select-Object -First 3
if (@($probe).Count -eq 0) {
    Write-Warn '新桌面里没有快捷方式，无法自动验证。请手动查看桌面图标。'
}
else {
    foreach ($f in $probe) {
        $px = Test-IconAt $f.FullName
        if ($px -ge 200) { Write-Ok "  $($f.Name) 彩色像素 $px（正常）" }
        else             { Write-Bad "  $($f.Name) 彩色像素 $px（仍然异常）" }
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  完成。请看一下桌面图标。' -ForegroundColor Cyan
Write-Host '  注册表备份在: ' -NoNewline -ForegroundColor Gray
Write-Host $backupDir -ForegroundColor Gray
Write-Host '  如需回滚: .\Fix-DesktopIcons.ps1 -Restore' -ForegroundColor Gray
Write-Host '  原桌面文件夹全程未改动，确认没问题后可自行删除。' -ForegroundColor Gray
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
