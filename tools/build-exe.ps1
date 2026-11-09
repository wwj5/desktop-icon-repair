<#
.SYNOPSIS
    把 Repair-AllIcons.ps1 打包成单文件 exe（用系统自带的 csc.exe，不需要装任何模块）。

.DESCRIPTION
    做法：tools\launcher.cs 是一个很小的启动器，编译时把 Repair-AllIcons.ps1
    作为资源嵌进 exe；运行时释放到临时目录，用系统 powershell.exe 执行，参数原样转发。
    逻辑只有仓库里的一份 ps1，exe 只是外壳。

    为什么不用 ps2exe：实测本机 ps2exe 生成的 exe 会卡在控制台输入上（重定向后拿不到输出、
    进程不退出），换成 csc 编译的普通控制台程序后行为可预期。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\build-exe.ps1 -OutFile .\桌面图标修复.exe
#>

[CmdletBinding()]
param(
    [string]$OutFile = '桌面图标修复.exe',
    [string]$Icon
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script = Join-Path $repo 'Repair-AllIcons.ps1'
$launcher = Join-Path $repo 'tools\launcher.cs'
if (-not $Icon) { $Icon = Join-Path $repo 'assets\icon.ico' }

if (-not (Test-Path -LiteralPath $script))   { throw "找不到 $script" }
if (-not (Test-Path -LiteralPath $launcher)) { throw "找不到 $launcher" }
if (-not (Test-Path -LiteralPath $Icon)) {
    throw "找不到图标 $Icon；先运行 tools\make-icon.ps1 生成"
}

# 优先 64 位编译器，退到 32 位
$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '找不到 csc.exe（需要 .NET Framework 4.x 运行时，Windows 10/11 自带）' }

if (-not [IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path $repo $OutFile }
if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }

$argsList = @(
    '/target:exe',
    '/platform:anycpu',
    '/optimize+',
    '/nologo',
    ('/win32icon:' + $Icon),
    ('/out:' + $OutFile),
    ('/resource:' + $script + ',Repair-AllIcons.ps1'),
    $launcher
)

& $csc $argsList
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败，退出码 $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $OutFile)) { throw '编译后没有生成 exe' }

$item = Get-Item -LiteralPath $OutFile
$hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
Write-Host ''
Write-Host ('  已生成 ' + $item.FullName)
Write-Host ('  大小   ' + $item.Length + ' 字节')
Write-Host ('  SHA256 ' + $hash)
Write-Host ''
