<#
.SYNOPSIS
    桌面图标统一检测 + 修复：自动判断每个快捷方式图标是否真的坏了、坏在哪一类，并只修能修的。

.DESCRIPTION
    判定不再是「彩色像素少于 80 就是白纸」这种一刀切阈值 —— 很多程序图标本身就是黑白 / 深色，
    彩色像素天然很低（实测某程序 exe 只有 24 个彩色像素），一律按阈值判会误报。

    本脚本改用「相似度比对」：
        · 参照图 A：兜底图标。临时建一个指向不存在文件的快捷方式，取它的图标 → 就是「白纸 + 蓝箭头」
        · 参照图 B：目标程序自己的图标。直接对 lnk 指向的 exe 取图标
        把桌面 lnk 的图标分别与 A、B 逐像素比较（32×32 归一化后算平均绝对差）：
            接近 A          → 真的是兜底白纸
            接近 B          → 图标正常（哪怕它是黑白的）
            既不像 A 也不像 B → 可疑，输出实际差值供判断

    再配合「同一个文件复制到临时目录」的对照，把白纸分成三类：
        ① 桌面通道坏了   → 桌面上像兜底图，复制到临时目录就正常 → 可由「换桌面路径」修复
        ② 快捷方式本身坏 → 临时目录里同样是兜底图，但目标程序图标正常 → 重写 IconLocation 修复
        ③ 目标缺失/程序无图标/商店应用 → 兜底图，且无从修 → 标记为需人工

    修复动作按检测结果才执行，不做无用的改动：
        注册表清理（去箭头工具的空白 ico 覆盖位）→ 图标缓存重建 → 单个 lnk 修复 → 桌面路径迁移
    每一步前都备份，`-Restore` 可回滚。

.PARAMETER DiagnoseOnly
    只检测、不修。输出每个快捷方式的判定与原因。

.PARAMETER Yes
    修复前不再询问（给 bat 用；bat 自己已经问过一遍）。

.PARAMETER NewDesktopPath
    桌面通道需要迁移时，新桌面文件夹的完整路径。默认 %USERPROFILE%\DesktopNew。

.PARAMETER ScanPath
    只扫描指定文件夹（用于自测或检查非桌面目录）。指定后不会做桌面路径迁移。

.PARAMETER Restore
    回滚：恢复最近一次修复前的注册表备份 + 桌面路径。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1 -DiagnoseOnly

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1 -Restore
#>

[CmdletBinding()]
param(
    [switch]$DiagnoseOnly,
    [switch]$Yes,
    [string]$NewDesktopPath,
    [string]$ScanPath,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 版本

# 软件名与版本号：诊断/修复输出、发布页、CHANGELOG 三处保持一致
$ScriptName    = '桌面图标修复'
$ScriptVersion = '2.1.0'

# ---------------------------------------------------------------- 常量

$usfKey        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$sfKey         = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$shellIconKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'
)
$lnkfileKey    = 'Registry::HKEY_CLASSES_ROOT\lnkfile'
$clsidKey      = 'Registry::HKEY_CLASSES_ROOT\CLSID\{00021401-0000-0000-C000-000000000046}'
$userLnkfileKey = 'HKCU:\Software\Classes\lnkfile'
$userClsidKey   = 'HKCU:\Software\Classes\CLSID\{00021401-0000-0000-C000-000000000046}'
$defaultDesktop = Join-Path $env:USERPROFILE 'Desktop'
$robocopy      = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$regExe        = Join-Path $env:SystemRoot 'System32\reg.exe'
$iconCacheDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
$script:BackupDir = $null
$script:Changed   = @()

# ---------------------------------------------------------------- 输出

function Write-Step { param([string]$T) Write-Host ''; Write-Host "==> $T" -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host "    OK   $T" -ForegroundColor Green }
function Write-Warn { param([string]$T) Write-Host "    注意 $T" -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host "    失败 $T" -ForegroundColor Red }

# ---------------------------------------------------------------- 图标探针

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class IcoSig
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

    private const uint SHGFI_ICON = 0x100;
    private const uint SHGFI_SHELLICONSIZE = 0x4;

    /// <summary>取外壳图标，归一化到 32x32 RGBA，返回 4096 字节；取不到返回 null。</summary>
    public static byte[] Signature(string path)
    {
        SHFILEINFO fi = new SHFILEINFO();
        IntPtr ret = SHGetFileInfo(path, 0, ref fi,
            (uint)Marshal.SizeOf(typeof(SHFILEINFO)), SHGFI_ICON | SHGFI_SHELLICONSIZE);
        if (ret == IntPtr.Zero || fi.hIcon == IntPtr.Zero) return null;

        try
        {
            using (Icon icon = Icon.FromHandle(fi.hIcon))
            using (Bitmap src = icon.ToBitmap())
            using (Bitmap dst = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(dst))
                {
                    g.Clear(Color.Transparent);
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(src, 0, 0, 32, 32);
                }
                byte[] bytes = new byte[32 * 32 * 4];
                int i = 0;
                for (int y = 0; y < 32; y++)
                    for (int x = 0; x < 32; x++)
                    {
                        Color c = dst.GetPixel(x, y);
                        bytes[i++] = c.R;
                        bytes[i++] = c.G;
                        bytes[i++] = c.B;
                        bytes[i++] = c.A;
                    }
                return bytes;
            }
        }
        finally { DestroyIcon(fi.hIcon); }
    }

    /// <summary>两张 32x32 图的平均绝对差（只算不透明像素的 RGB）。差异越大越不像，0 = 完全相同。</summary>
    public static double Diff(byte[] a, byte[] b)
    {
        if (a == null || b == null) return 999.0;
        long sum = 0;
        int n = 0;
        for (int p = 0; p < 32 * 32; p++)
        {
            int o = p * 4;
            if (a[o + 3] > 8 || b[o + 3] > 8)
            {
                sum += Math.Abs(a[o] - b[o]) + Math.Abs(a[o + 1] - b[o + 1]) + Math.Abs(a[o + 2] - b[o + 2]);
                n += 3;
            }
        }
        if (n == 0) return 0.0;
        return (double)sum / n;
    }

    /// <summary>彩色像素数（仅作参考信息输出，不用于判定）。</summary>
    public static int ColorPixels(string path)
    {
        SHFILEINFO fi = new SHFILEINFO();
        IntPtr ret = SHGetFileInfo(path, 0, ref fi,
            (uint)Marshal.SizeOf(typeof(SHFILEINFO)), SHGFI_ICON | SHGFI_SHELLICONSIZE);
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

# 阈值：与参照图的平均绝对差小于此值，视为「同一张图」
$SameThreshold = 12.0

function Get-Sig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [IcoSig]::Signature($Path)
}

function Get-Diff {
    param($A, $B)
    return [IcoSig]::Diff($A, $B)
}

function Get-LnkInfo {
    param([string]$LnkPath)
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($LnkPath)
    $target = $sc.TargetPath
    $iconLoc = $sc.IconLocation
    [PSCustomObject]@{
        TargetPath   = $target
        IconLocation = $iconLoc
        TargetExists = [bool]($target -and (Test-Path -LiteralPath $target))
    }
}

function Get-FallbackSig {
    # 指向不存在目标的快捷方式 → 系统只能发兜底图标（白纸 + 蓝箭头）
    $tmpLnk = Join-Path $env:TEMP ('__icon_ref_' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.lnk')
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($tmpLnk)
        $sc.TargetPath = 'Z:\__no_such_target__\__no_such_target__.exe'
        $sc.Save()
        Start-Sleep -Milliseconds 300
        return [IcoSig]::Signature($tmpLnk)
    }
    finally {
        if (Test-Path -LiteralPath $tmpLnk) { Remove-Item -LiteralPath $tmpLnk -Force -ErrorAction SilentlyContinue }
    }
}

function Restart-Explorer {
    $procs = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Start-Process explorer.exe; Start-Sleep -Seconds 3; return }
    foreach ($p in $procs) {
        try { $p | Stop-Process -Force -ErrorAction Stop } catch { Write-Warn "结束进程失败: $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds 2
    Start-Process explorer.exe
    Start-Sleep -Seconds 4
}

# ---------------------------------------------------------------- 调 reg.exe（不因 stderr 中断）

function Invoke-RegExport {
    param([string]$Key, [string]$File)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $regExe export $Key $File /y 2>&1 | Out-Null
    }
    catch { }
    finally { $ErrorActionPreference = $prev }
    return [bool](Test-Path -LiteralPath $File)
}

function Invoke-RegImport {
    param([string]$File)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $regExe import $File 2>&1 | Out-Null
        $code = $LASTEXITCODE
    }
    catch { $code = 1 }
    finally { $ErrorActionPreference = $prev }
    return ($code -eq 0)
}

# ---------------------------------------------------------------- 检测

function Measure-Desktop {
    <#  返回每个 lnk 的判定结果
        判定字段：Verdict / Cause / Fixable / Detail  #>
    param([string]$DesktopPath, $RefSig)

    $items = @(Get-ChildItem -LiteralPath $DesktopPath -Filter *.lnk -File -ErrorAction SilentlyContinue)
    $results = @()
    $tmpDir = $env:TEMP

    foreach ($f in $items) {
        $sigLnk = Get-Sig -Path $f.FullName
        $tmpCopy = Join-Path $tmpDir ('__probe_' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.lnk')
        $sigTmp = $null
        try {
            Copy-Item -LiteralPath $f.FullName -Destination $tmpCopy -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 120
            $sigTmp = Get-Sig -Path $tmpCopy
        }
        catch { }
        finally {
            if (Test-Path -LiteralPath $tmpCopy) { Remove-Item -LiteralPath $tmpCopy -Force -ErrorAction SilentlyContinue }
        }

        $info = Get-LnkInfo -LnkPath $f.FullName
        $sigTarget = $null
        if ($info.TargetExists) { $sigTarget = Get-Sig -Path $info.TargetPath }

        $dRef  = Get-Diff $sigLnk $RefSig          # 桌面图标 vs 兜底图
        $dTmp  = Get-Diff $sigTmp $RefSig          # 临时目录图标 vs 兜底图
        $dTgt  = Get-Diff $sigLnk $sigTarget       # 桌面图标 vs 目标程序自己的图标

        $verdict = ''
        $cause   = ''
        $fixable = '否'
        $detail  = ''
        $foundTarget = ''

        if ($sigLnk -eq $null) {
            $verdict = '取不到图标'; $cause = '文件被占用或已损坏'; $detail = '像素取不到'
        }
        elseif ($dRef -ge $SameThreshold) {
            # 与兜底图标明显不同 → 显示的是真图标（黑白/深色图标也算正常）
            $verdict = '正常'
            if ($sigTarget -ne $null -and $dTgt -lt $SameThreshold) { $cause = '与目标程序图标一致' }
            else { $cause = '显示的是程序自己的图标' }
            $detail = ("与兜底图距离 {0:N1}" -f $dRef)
        }
        else {
            # 桌面显示的就是兜底白纸
            $detail = ("与兜底图距离 {0:N1}" -f $dRef)
            if ($dTmp -ge $SameThreshold) {
                # 同一个文件复制到临时目录就正常 → 桌面通道坏了
                $verdict = '可修(桌面)'; $cause = '桌面图标通道坏了（复制到别处就正常）'; $fixable = '是'
            }
            elseif ([string]::IsNullOrWhiteSpace($info.TargetPath)) {
                $verdict = '需人工'; $cause = '商店应用 / 特殊快捷方式（没有目标路径）'
            }
            elseif (-not $info.TargetExists) {
                # 目标程序不在了 —— 先试着在系统里把同一个 exe 找回来
                $cands = @(Find-TargetCandidate -OldTarget $info.TargetPath)
                if ($cands.Count -eq 1) {
                    $verdict = '可修(路径)'; $cause = '程序搬家了，已在别处找到同名程序'; $fixable = '是'
                    $foundTarget = $cands[0]
                    $detail = "新位置: $($cands[0])"
                }
                elseif ($cands.Count -gt 1) {
                    $verdict = '需人工'; $cause = '找到多个同名程序，需你确认用哪个'
                    $detail = ($cands -join ' | ')
                }
                else {
                    $verdict = '需人工'; $cause = '目标程序不存在（已卸载或路径变了）'
                    $detail = "目标: $($info.TargetPath)"
                }
            }
            elseif ($sigTarget -eq $null -or $dTgt -lt $SameThreshold) {
                $verdict = '需人工'; $cause = '目标程序本身没有可用图标'
            }
            else {
                $verdict = '可修(单)'; $cause = '快捷方式图标解析坏了（可重写图标位置）'; $fixable = '是'
            }
        }

        $results += [PSCustomObject]@{
            Name         = $f.Name
            Path         = $f.FullName
            Verdict      = $verdict
            Cause        = $cause
            Fixable      = $fixable
            Detail       = $detail
            TargetExists = $info.TargetExists
            TargetPath   = $info.TargetPath
            FoundTarget  = $foundTarget
            IconLocation = $info.IconLocation
            DRef         = $dRef
            DTmp         = $dTmp
            DTgt         = $dTgt
        }
    }
    return $results
}

function Show-Table {
    param($Results)
    Write-Host ('  {0,-40} {1,-12} {2}' -f '快捷方式', '判定', '原因') -ForegroundColor Gray
    Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
    foreach ($r in $Results) {
        $name = $r.Name
        if ($name.Length -gt 38) { $name = $name.Substring(0, 35) + '...' }
        $color = 'Green'
        if ($r.Verdict -like '可修*') { $color = 'Yellow' }
        elseif ($r.Verdict -eq '需人工') { $color = 'Red' }
        elseif ($r.Verdict -eq '可疑') { $color = 'DarkYellow' }
        Write-Host ('  {0,-40} {1,-12} {2}' -f $name, $r.Verdict, $r.Cause) -ForegroundColor $color
    }
    Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 备份 / 回滚

function Backup-Registry {
    $dir = Join-Path $env:TEMP ('IconRepair_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $targets = @(
        @{ key = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'; file = 'UserShellFolders.reg' },
        @{ key = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders';      file = 'ShellFolders.reg' },
        @{ key = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons';        file = 'ShellIcons_HKCU.reg' },
        @{ key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons';       file = 'ShellIcons_HKLM.reg' },
        @{ key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\lnkfile';                                             file = 'lnkfile.reg' },
        @{ key = 'HKEY_CURRENT_USER\Software\Classes\lnkfile';                                              file = 'lnkfile_user.reg' },
        @{ key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{00021401-0000-0000-C000-000000000046}';         file = 'CLSID_lnk.reg' }
    )
    $ok = $true
    foreach ($t in $targets) {
        $p = Join-Path $dir $t.file
        $psPath = $null
        try { $psPath = $t.key -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CLASSES_ROOT', 'Registry::HKEY_CLASSES_ROOT' } catch { }
        $exists = $false
        if ($psPath) { $exists = Test-Path -LiteralPath $psPath }
        if (-not $exists) {
            Write-Warn "$($t.file) 该注册表键不存在，跳过（属正常）"
            continue
        }
        if (Invoke-RegExport -Key $t.key -File $p) {
            if ((Get-Item -LiteralPath $p).Length -lt 80) { Write-Warn "$($t.file) 备份文件过小" }
        }
        else {
            Write-Warn "$($t.file) 导出失败"
            if ($t.file -eq 'UserShellFolders.reg') { $ok = $false }
        }
        Start-Sleep -Milliseconds 150
    }
    $bkUsf = Join-Path $dir 'UserShellFolders.reg'
    if (-not (Test-Path -LiteralPath $bkUsf)) {
        if (Invoke-RegExport -Key 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -File $bkUsf) {
            Start-Sleep -Milliseconds 300
        }
    }
    if (-not (Test-Path -LiteralPath $bkUsf)) { Write-Bad "User Shell Folders 备份失败：$bkUsf"; $ok = $false }

    $manifest = @{
        time          = (Get-Date).ToString('s')
        desktopBefore = [Environment]::GetFolderPath('Desktop')
    } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), $manifest, (New-Object Text.UTF8Encoding($false)))

    $script:BackupDir = $dir
    if ($ok) { Write-Ok "备份目录：$dir" }
    return $ok
}

function Restore-All {
    $dirs = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'IconRepair_*' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    if ($dirs.Count -eq 0) { Write-Bad '找不到任何修复备份目录（%TEMP%\IconRepair_*）'; exit 3 }
    $dir = $dirs[0].FullName
    Write-Warn "使用备份：$dir"

    foreach ($f in @('UserShellFolders.reg','ShellFolders.reg','ShellIcons_HKCU.reg','ShellIcons_HKLM.reg','lnkfile.reg','CLSID_lnk.reg')) {
        $p = Join-Path $dir $f
        if (Test-Path -LiteralPath $p) {
            if (Invoke-RegImport -File $p) { Write-Ok "已导入 $f" }
            else { Write-Warn "导入失败 $f" }
        }
    }

    $m = Join-Path $dir 'manifest.json'
    if (Test-Path -LiteralPath $m) {
        $j = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        if ($j.desktopBefore) {
            New-ItemProperty -Path $usfKey -Name 'Desktop' -Value $j.desktopBefore -PropertyType ExpandString -Force | Out-Null
            New-ItemProperty -Path $sfKey  -Name 'Desktop' -Value $j.desktopBefore -PropertyType String       -Force | Out-Null
            Write-Ok "桌面路径已改回 $($j.desktopBefore)"
        }
    }

    # 被改过的快捷方式逐個还原
    $lnkDir = Join-Path $dir 'lnk'
    $map = Join-Path $lnkDir '_map.txt'
    if (Test-Path -LiteralPath $map) {
        $lines = @(Get-Content -LiteralPath $map -Encoding utf8)
        $restored = 0
        foreach ($l in $lines) {
            if (-not $l.Trim()) { continue }
            $parts = $l -split "`t", 2
            if ($parts.Count -ne 2) { continue }
            $src = Join-Path $lnkDir $parts[0]
            $dst = $parts[1]
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $parent = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $parent)) { Write-Warn "原目录不存在，跳过：$dst"; continue }
            try {
                Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
                $restored++
            }
            catch { Write-Warn "还原失败：$dst" }
        }
        if ($restored -gt 0) { Write-Ok "已还原 $restored 个快捷方式" }
    }

    Write-Step '重启资源管理器'
    Restart-Explorer
    Write-Ok '回滚完成'
    exit 0
}

# ---------------------------------------------------------------- 注册表清理

function Get-RegVal {
    param([string]$Path, [string]$Name)
    try {
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $p.$Name
    }
    catch { return $null }
}

function Set-RegValAnyWay {
    <#  先试机器级（需管理员），失败就写 HKCU\Software\Classes 的用户级覆盖（普通权限即可）。
        返回 'machine' / 'user' / $null  #>
    param([string]$MachineKey, [string]$UserKey, [string]$Name, [string]$Value)

    try {
        if (-not (Test-Path -LiteralPath $MachineKey)) { New-Item -Path $MachineKey -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $MachineKey -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
        return 'machine'
    }
    catch { }

    try {
        if (-not (Test-Path -LiteralPath $UserKey)) { New-Item -Path $UserKey -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $UserKey -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
        return 'user'
    }
    catch { return $null }
}

function Repair-Registry {
    $changed = $false

    # 1) 去箭头工具留下的空白图标覆盖位
    foreach ($k in $shellIconKeys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $props = Get-ItemProperty -LiteralPath $k
        foreach ($name in @('29', '77', '30', '31')) {
            $val = $null
            try { $val = $props.$name } catch { }
            if ($null -eq $val) { continue }
            $path = ($val -split ',')[0].Trim()
            $exists = Test-Path -LiteralPath $path
            if (-not $exists -or $path -match 'blank|empty|transparent') {
                Remove-ItemProperty -LiteralPath $k -Name $name -Force -ErrorAction SilentlyContinue
                Write-Ok "移除 $k 的 $name（原指向 [$val]，无有效图标）"
                $changed = $true
            }
        }
    }
    if (-not $changed) { Write-Ok 'Shell Icons 无空白图标覆盖位，跳过' }

    # 2) 快捷方式图标处理链：只在确实不对的时候才写
    $defIcon = Get-RegVal -Path $lnkfileKey -Name 'DefaultIcon'
    if ($defIcon -ne '%SystemRoot%\system32\shell32.dll,3') {
        $r = Set-RegValAnyWay -MachineKey $lnkfileKey -UserKey $userLnkfileKey -Name 'DefaultIcon' -Value '%SystemRoot%\system32\shell32.dll,3'
        if ($r) { Write-Ok "重设 lnkfile\DefaultIcon（原值 [$defIcon]，写入 $r 级）"; $changed = $true }
        else   { Write-Bad "无法写入 lnkfile\DefaultIcon（原值 [$defIcon]）" }
    }
    else { Write-Ok 'lnkfile\DefaultIcon 正常，跳过' }

    $handler = Get-RegVal -Path (Join-Path $lnkfileKey 'shellex\IconHandler') -Name '(default)'
    if ($handler -ne '{00021401-0000-0000-C000-000000000046}') {
        $r = Set-RegValAnyWay -MachineKey (Join-Path $lnkfileKey 'shellex\IconHandler') -UserKey (Join-Path $userLnkfileKey 'shellex\IconHandler') -Name '(default)' -Value '{00021401-0000-0000-C000-000000000046}'
        if ($r) { Write-Ok "重设 IconHandler（原值 [$handler]，写入 $r 级）"; $changed = $true }
        else   { Write-Bad "无法写入 IconHandler（原值 [$handler]）" }
    }
    else { Write-Ok 'lnkfile\shellex\IconHandler 正常，跳过' }

    $inproc = Get-RegVal -Path (Join-Path $clsidKey 'InProcServer32') -Name '(default)'
    $inprocOk = ($inproc -eq '%SystemRoot%\system32\windows.storage.dll') -or ($inproc -like '*\windows.storage.dll')
    if (-not $inprocOk) {
        $r = Set-RegValAnyWay -MachineKey (Join-Path $clsidKey 'InProcServer32') -UserKey (Join-Path $userClsidKey 'InProcServer32') -Name '(default)' -Value '%SystemRoot%\system32\windows.storage.dll'
        if ($r) { Write-Ok "重设 InProcServer32（原值 [$inproc]，写入 $r 级）"; $changed = $true }
        else   { Write-Bad "无法写入 InProcServer32（原值 [$inproc]）" }
    }
    else { Write-Ok 'CLSID 的 InProcServer32 正常，跳过' }

    return $changed
}

function Rebuild-IconCache {
    $dbs = @(Get-ChildItem -LiteralPath $iconCacheDir -Filter 'iconcache_*.db' -Force -ErrorAction SilentlyContinue)
    if ($dbs.Count -eq 0) { Write-Warn "没有找到图标缓存文件：$iconCacheDir"; return $false }
    $before = ($dbs | Measure-Object -Property Length -Sum).Sum
    $deleted = 0; $failed = 0
    foreach ($f in $dbs) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $deleted++
        }
        catch { $failed++ }
    }
    Start-Sleep -Seconds 1
    Write-Ok ("图标缓存已清理（原来 $($dbs.Count) 个 / $([math]::Round($before/1KB,0)) KB，删除 $deleted 个、失败 $failed 个）")
    if ($failed -gt 0) { Write-Warn '部分缓存被占用未删除，重启资源管理器后系统会重建剩下的' }
    return $true
}

# ---------------------------------------------------------------- 目标程序搬家 → 找回

function Find-TargetCandidate {
    <#  快捷方式指向的 exe 不在了，按 exe 文件名在系统里找回来的路径。
        查找顺序：App Paths 注册表 → 已安装程序清单（Uninstall）→ Program Files 限深搜索。
        返回 0 / 1 / 多个 命中路径。  #>
    param([string]$OldTarget)

    $exe = [IO.Path]::GetFileName($OldTarget)
    if ([string]::IsNullOrWhiteSpace($exe)) { return @() }
    $found = @()

    # 1) App Paths —— 程序自己登记的启动路径，最可靠
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths'
    )) {
        $k = Join-Path $root $exe
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $v = Get-RegVal -Path $k -Name '(default)'
        if ($v) {
            $p = $v.Trim('"', ' ')
            if (Test-Path -LiteralPath $p) { $found += $p }
        }
    }

    # 2) 已安装程序清单里的 DisplayIcon / InstallLocation
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $subs = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
        foreach ($s in $subs) {
            try { $props = Get-ItemProperty -LiteralPath $s.PSPath -ErrorAction Stop } catch { continue }
            $di = $props.DisplayIcon
            if ($di) {
                $p = ($di -split ',')[0].Trim().Trim('"', ' ')
                if ([IO.Path]::GetFileName($p) -eq $exe -and (Test-Path -LiteralPath $p)) { $found += $p }
            }
            $loc = $props.InstallLocation
            if ($loc) {
                $p = Join-Path $loc.Trim().Trim('"') $exe
                if (Test-Path -LiteralPath $p) { $found += $p }
            }
        }
    }

    # 3) 兜底：Program Files 系目录里限深找（不扫全盘，避免几分钟）
    if ($found.Count -eq 0) {
        $rootDirs = @()
        foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
            if ($r -and (Test-Path -LiteralPath $r)) { $rootDirs += $r }
        }
        foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $rd = $d.Root
            if (Test-Path -LiteralPath $rd) {
                foreach ($sub in @('Program Files', 'Program Files (x86)', 'Apps', '软件')) {
                    $p = Join-Path $rd $sub
                    if (Test-Path -LiteralPath $p) { $rootDirs += $p }
                }
            }
        }
        $rootDirs = @($rootDirs | Where-Object { $_ -and -not ($_ -like '*\Windows\*') } | Select-Object -Unique)
        foreach ($r in $rootDirs) {
            try {
                $hits = @(Get-ChildItem -LiteralPath $r -Filter $exe -File -Recurse -Depth 4 -ErrorAction SilentlyContinue)
                foreach ($h in $hits) { $found += $h.FullName }
            }
            catch { }
        }
    }

    return @($found | Where-Object { $_ } | Select-Object -Unique)
}

function Backup-LnkFile {
    param([string]$LnkPath)
    if (-not $script:BackupDir) { return }
    $d = Join-Path $script:BackupDir 'lnk'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    try {
        Copy-Item -LiteralPath $LnkPath -Destination (Join-Path $d ([IO.Path]::GetFileName($LnkPath))) -Force -ErrorAction Stop
        $map = Join-Path $d '_map.txt'
        [IO.File]::AppendAllText($map, ([IO.Path]::GetFileName($LnkPath) + "`t" + $LnkPath + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    }
    catch { Write-Warn "快捷方式备份失败：$LnkPath" }
}

# ---------------------------------------------------------------- 单 lnk 修复

function Repair-LnkIcon {
    param($Item)
    # 只对「目标存在但 lnk 图标解析坏」的重写图标位置
    Backup-LnkFile -LnkPath $Item.Path
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Item.Path)
    $before = $sc.IconLocation
    $sc.IconLocation = "$($Item.TargetPath),0"
    $sc.Save()
    Start-Sleep -Milliseconds 300
    $sig = Get-Sig -Path $Item.Path
    return [PSCustomObject]@{
        Name   = $Item.Name
        Before = $before
        After  = "$($Item.TargetPath),0"
        Sig    = $sig
    }
}

function Repair-LnkTarget {
    <#  目标程序搬家：把快捷方式重新指到找到的新 exe，并同步图标与工作目录。  #>
    param($Item, [string]$NewTarget)
    Backup-LnkFile -LnkPath $Item.Path
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Item.Path)
    $beforeTarget = $sc.TargetPath
    $sc.TargetPath = $NewTarget
    $sc.WorkingDirectory = Split-Path -Parent $NewTarget
    $sc.IconLocation = "$NewTarget,0"
    $sc.Save()
    Start-Sleep -Milliseconds 300
    $sig = Get-Sig -Path $Item.Path
    return [PSCustomObject]@{
        Name    = $Item.Name
        Before  = $beforeTarget
        After   = $NewTarget
        Sig     = $sig
    }
}

# ---------------------------------------------------------------- 主流程

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("  {0} v{1}" -f $ScriptName, $ScriptVersion) -ForegroundColor Cyan
Write-Host '  桌面快捷方式图标检测与修复' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $robocopy)) { Write-Bad "找不到 robocopy：$robocopy"; exit 3 }
if (-not (Test-Path -LiteralPath $regExe))   { Write-Bad "找不到 reg.exe：$regExe";     exit 3 }

if ($Restore) {
    Write-Step '回滚'
    Restore-All
}

$desktop = [Environment]::GetFolderPath('Desktop')
$isDesktopScan = $true
if ($ScanPath) {
    $desktop = (Resolve-Path -LiteralPath $ScanPath).Path
    $isDesktopScan = $false
    Write-Host "  扫描目录 : $desktop（自定义，不做桌面迁移）"
}
else {
    Write-Host "  桌面路径 : $desktop"
}

if (-not (Test-Path -LiteralPath $desktop)) { Write-Bad "桌面路径不存在：$desktop"; exit 3 }

# ---- 参照图
Write-Step '建立参照图（兜底白纸图标）'
$refSig = Get-FallbackSig
if ($refSig -eq $null) { Write-Bad '取不到兜底图标参照，无法比对。请确认系统 shell 正常。'; exit 3 }
Write-Ok '已取到兜底图标参照（32×32）'

# ---- 检测
Write-Step '检测桌面快捷方式'
$before = Measure-Desktop -DesktopPath $desktop -RefSig $refSig
if ($before.Count -eq 0) { Write-Warn '桌面上没有快捷方式（.lnk）'; exit 0 }

Write-Host ''
Show-Table -Results $before
Write-Host ''
$cntNormal  = @($before | Where-Object { $_.Verdict -eq '正常' }).Count
$cntDesk    = @($before | Where-Object { $_.Verdict -eq '可修(桌面)' }).Count
$cntSingle  = @($before | Where-Object { $_.Verdict -eq '可修(单)' }).Count
$cntTarget  = @($before | Where-Object { $_.Verdict -eq '可修(路径)' }).Count
$cntManual  = @($before | Where-Object { $_.Verdict -eq '需人工' }).Count
$cntSuspect = @($before | Where-Object { $_.Verdict -eq '可疑' }).Count
Write-Host ("  汇总：正常 $cntNormal   桌面通道可修 $cntDesk   单个 lnk 可修 $cntSingle   路径可修 $cntTarget   需人工 $cntManual   可疑 $cntSuspect") -ForegroundColor Cyan

if ($DiagnoseOnly) {
    Write-Host ''
    Write-Host '  仅检测模式，未做任何修改。' -ForegroundColor Gray
    exit 0
}

# ---- 准备
Write-Step '准备修复'
Write-Ok "将针对 $($cntDesk + $cntSingle + $cntTarget) 个异常项执行修复；正常项不动"

$needRegistry = $true      # 每轮都做一遍，幂等
$doCache      = ($cntDesk -gt 0)     # 只有桌面通道问题才需要重建缓存刷新
$doLnk        = ($cntSingle + $cntTarget) -gt 0
$doMigrate    = ($cntDesk -gt 0) -and $isDesktopScan

if (-not $doCache -and -not $doLnk -and -not $doMigrate) {
    Write-Ok '没有需要修复的项目，结束。'
    exit 0
}

if (-not $Yes) {
    Write-Host ''
    Write-Host ('  即将修改注册表 / 图标缓存 / 快捷方式' + $(if ($doMigrate) { ' / 桌面路径' } else { '' })) -ForegroundColor Yellow
    Write-Host '  每个快捷方式改动前都会单独备份。请先保存正在编辑的文件。Ctrl+C 可在 5 秒内取消。' -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}

Write-Step '备份'
if (-not (Backup-Registry)) { Write-Bad '备份失败，已中止，未做任何修改。'; exit 5 }

# ---- 第一步：注册表清理
Write-Step '1) 清理快捷方式图标注册表'
$regChanged = Repair-Registry
if ($regChanged) { $script:Changed += '注册表' }

# ---- 第二步：图标缓存
Write-Step '2) 重建图标缓存'
if ($doCache) {
    if (Rebuild-IconCache) { $script:Changed += '图标缓存' }
}
else { Write-Ok '无需重建（没有异常项）' }

if ($regChanged -or $doCache) {
    Write-Step '重启资源管理器让前面的改动生效'
    Restart-Explorer
    Write-Ok '已重启'
}

# ---- 第三步：单个 lnk（图标位置坏 / 目标搬家）
if ($doLnk) {
    Write-Step '3) 修复快捷方式本身'
    $single = @($before | Where-Object { $_.Verdict -eq '可修(单)' })
    foreach ($item in $single) {
        try {
            $r = Repair-LnkIcon -Item $item
            if ($r.Sig -ne $null) {
                $d = Get-Diff $r.Sig $refSig
                if ($d -lt $SameThreshold) { Write-Bad "$($r.Name) 重写后仍是兜底图（该程序可能没有图标资源）" }
                else { Write-Ok "$($r.Name) 图标已恢复（$($r.Before) → $($r.After)）" }
            }
            else { Write-Warn "$($r.Name) 重写后取不到图标" }
        }
        catch { Write-Bad "$($item.Name) 重写失败：$($_.Exception.Message)" }
    }

    $moved = @($before | Where-Object { $_.Verdict -eq '可修(路径)' })
    foreach ($item in $moved) {
        try {
            $r = Repair-LnkTarget -Item $item -NewTarget $item.FoundTarget
            if ($r.Sig -ne $null) {
                $d = Get-Diff $r.Sig $refSig
                if ($d -lt $SameThreshold) { Write-Bad "$($r.Name) 改指向后仍是兜底图（新程序可能没有图标资源）" }
                else { Write-Ok "$($r.Name) 已重新指到 $($r.After)" }
            }
            else { Write-Warn "$($r.Name) 改指向后取不到图标" }
        }
        catch { Write-Bad "$($item.Name) 改指向失败：$($_.Exception.Message)" }
    }

    if ($single.Count -gt 0) { $script:Changed += '单个快捷方式图标' }
    if ($moved.Count -gt 0)  { $script:Changed += '快捷方式目标路径' }
}
else { Write-Ok '无需处理（没有单个 lnk 异常）' }

# ---- 第四步：桌面路径迁移
if ($doMigrate) {
    Write-Step '4) 桌面通道修复：迁移桌面路径'
    $cur = [Environment]::GetFolderPath('Desktop')
    if (-not $NewDesktopPath) { $NewDesktopPath = Join-Path $env:USERPROFILE 'DesktopNew2' }
    if ($NewDesktopPath.TrimEnd('\') -eq $cur.TrimEnd('\')) {
        Write-Bad "目标路径与当前桌面相同：$NewDesktopPath ，请用 -NewDesktopPath 指定别的路径"
    }
    else {
        if (Test-Path -LiteralPath $NewDesktopPath) {
            $existing = @(Get-ChildItem -LiteralPath $NewDesktopPath -Force -ErrorAction SilentlyContinue)
            if ($existing.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $NewDesktopPath 'desktop.ini'))) {
                Write-Bad "目标已存在且有内容：$NewDesktopPath ，请换路径"
                $NewDesktopPath = $null
            }
        }
        if ($NewDesktopPath) {
            if (-not (Test-Path -LiteralPath $NewDesktopPath)) { New-Item -ItemType Directory -Path $NewDesktopPath -Force | Out-Null }
            $srcItems = @(Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue)
            $srcSize  = (@($srcItems | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum)
            if (-not $srcSize) { $srcSize = 0 }
            Write-Ok "源：$($srcItems.Count) 项 / $([math]::Round($srcSize/1MB,2)) MB"

            $null = & $robocopy $cur $NewDesktopPath /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS
            if ($LASTEXITCODE -ge 8) { Write-Bad "robocopy 失败（$LASTEXITCODE），已中止，桌面路径未改"; $NewDesktopPath = $null }
        }
        if ($NewDesktopPath) {
            $dstItems = @(Get-ChildItem -LiteralPath $NewDesktopPath -Force -ErrorAction SilentlyContinue)
            $dstSize  = (@($dstItems | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum)
            if (-not $dstSize) { $dstSize = 0 }
            if ($dstItems.Count -lt $srcItems.Count) {
                Write-Bad "副本项数少于源（$($dstItems.Count) < $($srcItems.Count)），已中止，桌面路径未改"
                $NewDesktopPath = $null
            }
            else {
                Write-Ok "副本核对通过：$($dstItems.Count) 项 / $([math]::Round($dstSize/1MB,2)) MB"
                New-ItemProperty -Path $usfKey -Name 'Desktop' -Value $NewDesktopPath -PropertyType ExpandString -Force | Out-Null
                New-ItemProperty -Path $sfKey  -Name 'Desktop' -Value $NewDesktopPath -PropertyType String       -Force | Out-Null
                try {
                    $d = Get-Item -LiteralPath $NewDesktopPath -Force
                    if (-not $d.Attributes.ToString().Contains('ReadOnly')) { $d.Attributes = $d.Attributes -bor [IO.FileAttributes]::ReadOnly }
                } catch { }
                Write-Ok "桌面已指向 $NewDesktopPath"
                $script:Changed += '桌面路径'
                Restart-Explorer
                $desktop = $NewDesktopPath
            }
        }
    }
}
else { Write-Ok '无需迁移（桌面通道正常）' }

# ---- 复检
Write-Step '复检'
$after = Measure-Desktop -DesktopPath $desktop -RefSig $refSig
Write-Host ''
Show-Table -Results $after
Write-Host ''
$afterBad = @($after | Where-Object { $_.Verdict -like '可修*' -or $_.Verdict -eq '可疑' }).Count
$afterManual = @($after | Where-Object { $_.Verdict -eq '需人工' }).Count
$afterOk = @($after | Where-Object { $_.Verdict -eq '正常' }).Count
Write-Host ("  修复后：正常 $afterOk   仍异常 $afterBad   需人工 $afterManual") -ForegroundColor Cyan

if ($afterManual -gt 0) {
    Write-Host ''
    Write-Host '  以下项本工具修不了，需要你手动处理：' -ForegroundColor Yellow
    foreach ($r in @($after | Where-Object { $_.Verdict -eq '需人工' })) {
        Write-Host ("    - {0}：{1}" -f $r.Name, $r.Cause) -ForegroundColor Yellow
        if ($r.Cause -like '目标程序不存在*') {
            Write-Host ("      重建方法：删掉它，从开始菜单重新拖一个到桌面") -ForegroundColor Gray
        }
        elseif ($r.Cause -like '商店应用*') {
            Write-Host ("      这是商店应用/UWP 快捷方式，图标由应用自身提供；如仍白纸，重装该应用或从开始菜单重新拖") -ForegroundColor Gray
        }
        else {
            Write-Host ("      该程序 exe 里没有可用图标，可在右键→属性→更改图标 手动指定一个 .ico") -ForegroundColor Gray
        }
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  完成。' -ForegroundColor Cyan
if ($script:Changed.Count -gt 0) {
    Write-Host ('  本次改动：' + ($script:Changed -join ' / ')) -ForegroundColor Gray
}
else {
    Write-Host '  本次没有做任何修改。' -ForegroundColor Gray
}
if ($script:BackupDir) {
    Write-Host "  备份目录：$($script:BackupDir)" -ForegroundColor Gray
    Write-Host '  如需回滚：.\Repair-AllIcons.ps1 -Restore' -ForegroundColor Gray
}
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
