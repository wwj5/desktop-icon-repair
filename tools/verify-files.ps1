<#
.SYNOPSIS
    校验仓库文件的编码与换行（CI 和本地都能跑）。

.DESCRIPTION
    约束（对 Windows 用户很关键，错了就双击报错或中文变问号）：
        *.ps1  → UTF-8 with BOM，CRLF
        *.bat  → GBK(936)，CRLF
        *.md   → UTF-8，LF

    只读检查，不改任何文件。发现不合规时退出码为 1。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\verify-files.ps1
#>

[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$Root = (Resolve-Path -LiteralPath $Root).Path

$utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$gbkStrict  = [Text.Encoding]::GetEncoding(936, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)

$fail = 0
$checked = 0

function Test-LineEndings {
    param([string]$Text)
    $crlf = ([regex]::Matches($Text, "`r`n")).Count
    $loneLf = ([regex]::Matches($Text, "(?<!`r)`n")).Count
    $loneCr = ([regex]::Matches($Text, "`r(?!`n)")).Count
    return @{ Crlf = $crlf; LoneLf = $loneLf; LoneCr = $loneCr }
}

function Report {
    param([string]$File, [bool]$Ok, [string]$Msg)
    $script:checked++
    if ($Ok) {
        Write-Host ("  OK    {0,-28} {1}" -f $File, $Msg) -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host ("  FAIL  {0,-28} {1}" -f $File, $Msg) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "校验目录：$Root"
Write-Host ''

# ---- PowerShell 脚本：UTF-8 BOM + CRLF + 能通过语法解析
$ps1 = @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -File -Recurse |
        Where-Object { $_.FullName -notlike '*\.git\*' })
foreach ($f in $ps1) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = $utf8Strict.GetString($bytes)
    # 手工解码会把 BOM 留成首字符 U+FEFF，解析前必须去掉，否则报「语法解析失败」
    $text = $text.TrimStart([char]0xFEFF)
    $eol = Test-LineEndings -Text $text

    $ok = $hasBom -and $eol.LoneLf -eq 0 -and $eol.LoneCr -eq 0
    $notes = @()
    if (-not $hasBom) { $notes += '缺少 UTF-8 BOM' }
    if ($eol.LoneLf -gt 0) { $notes += "有 $($eol.LoneLf) 处裸 LF" }
    if ($eol.LoneCr -gt 0) { $notes += "有 $($eol.LoneCr) 处裸 CR" }

    $parsed = $true
    try { [void][ScriptBlock]::Create($text) }
    catch { $parsed = $false; $notes += ('语法解析失败: ' + $_.Exception.Message) }

    Report -File $f.Name -Ok ($ok -and $parsed) -Msg ($(if ($ok -and $parsed) { 'UTF-8 BOM + CRLF + 语法 OK' } else { $notes -join '；' }))
}

# ---- bat：GBK 可解码 + CRLF
$bats = @(Get-ChildItem -LiteralPath $Root -Filter '*.bat' -File -Recurse |
         Where-Object { $_.FullName -notlike '*\.git\*' })
foreach ($f in $bats) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $ok = $true
    $notes = @()
    try { $text = $gbkStrict.GetString($bytes) } catch { $ok = $false; $notes += '不是合法 GBK 文本'; $text = '' }
    if ($ok) {
        $eol = Test-LineEndings -Text $text
        if ($eol.LoneLf -gt 0) { $ok = $false; $notes += "有 $($eol.LoneLf) 处裸 LF" }
        if ($text -notmatch '@echo off') { $ok = $false; $notes += '缺少 @echo off' }
    }
    Report -File $f.Name -Ok $ok -Msg ($(if ($ok) { 'GBK + CRLF OK' } else { $notes -join '；' }))
}

# ---- md：UTF-8 + LF（GitHub 无所谓，但保持仓库一致）
$mds = @(Get-ChildItem -LiteralPath $Root -Filter '*.md' -File -Recurse |
        Where-Object { $_.FullName -notlike '*\.git\*' })
foreach ($f in $mds) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    try { $text = $utf8Strict.GetString($bytes) } catch { Report -File $f.Name -Ok $false -Msg '不是合法 UTF-8'; continue }
    $eol = Test-LineEndings -Text $text
    if ($eol.LoneCr -gt 0) { Report -File $f.Name -Ok $false -Msg "有 $($eol.LoneCr) 处裸 CR" }
    else { Report -File $f.Name -Ok $true -Msg 'UTF-8 + LF OK' }
}

Write-Host ''
Write-Host ("检查了 $script:checked 个文件，失败 $script:fail 个。")
Write-Host ''

if ($script:fail -gt 0) { exit 1 }
exit 0
