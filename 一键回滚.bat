@echo off
"%SystemRoot%\System32\chcp.com" 936 >nul
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
title 桌面快捷方式图标修复 - 回滚
color 4F
cd /d "%~dp0"

echo ============================================================
echo   回滚：把桌面路径改回原来的位置
echo ============================================================
echo.
echo 会把系统"桌面"位置改回 用户目录\Desktop，并重启资源管理器。
echo 修复时新建的 DesktopNew 文件夹不会被删除，里面是你桌面的副本。
echo.

if not exist "Fix-DesktopIcons.ps1" (
    echo [错误] 没找到 Fix-DesktopIcons.ps1
    echo        请确认 bat 和 ps1 放在同一个文件夹里。
    echo.
    pause
    exit /b 1
)
if not exist "%PS%" (
    echo [错误] 没找到 PowerShell：%PS%
    echo.
    pause
    exit /b 1
)

set "ok="
set /p "ok=确认回滚？输入 y 再回车（输入其它任意键取消）: "
if /i not "%ok%"=="y" goto cancel

echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-DesktopIcons.ps1" -Restore

echo.
echo 按任意键关闭。
pause >nul
exit /b 0

:cancel
echo.
echo 已取消。
pause >nul
exit /b 0