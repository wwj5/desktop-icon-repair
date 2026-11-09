<#
.SYNOPSIS
    只读诊断（旧入口，已转发到新引擎 Repair-AllIcons.ps1）。

.DESCRIPTION
    本文件过去自带一套「彩色像素少于 80 = 白纸」的阈值判据，会误报黑白 / 深色图标
    （实测某些程序 exe 本身只有 24 个彩色像素，被误判成白纸）。
    新引擎把判定改成「相似度比对」，不再有这个问题，所以这里只保留一个转发入口，
    保持老用户的命令和双击习惯，同时避免再输出误报结果。

    想直接调用新引擎：Repair-AllIcons.ps1 -DiagnoseOnly

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-DesktopIcons.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-DesktopIcons.ps1 -ScanPath D:\SomeFolder
#>

[CmdletBinding()]
param(
    [string]$ScanPath
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'Repair-AllIcons.ps1'

if (-not (Test-Path -LiteralPath $engine)) {
    Write-Host ''
    Write-Host '  [错误] 同目录下找不到新引擎 Repair-AllIcons.ps1' -ForegroundColor Red
    Write-Host "         应为：$engine" -ForegroundColor Gray
    Write-Host '         请把仓库里的文件整体解压到一起，不要只拿单个脚本。' -ForegroundColor Gray
    Write-Host ''
    exit 3
}

$argList = @('-DiagnoseOnly')
if ($ScanPath) { $argList += @('-ScanPath', $ScanPath) }

$pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $engine @argList
exit $LASTEXITCODE
