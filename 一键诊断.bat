@echo off
"%SystemRoot%\System32\chcp.com" 936 >nul
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
title 桌面快捷方式图标诊断（只读）
color 0B
cd /d "%~dp0"

echo ============================================================
echo   桌面快捷方式图标诊断（只读，不改任何系统设置）
echo ============================================================
echo.

if not exist "Repair-AllIcons.ps1" (
    echo [错误] 没找到 Repair-AllIcons.ps1
    echo        请确认 bat 和 ps1 放在同一个文件夹里，不要把 bat 单独挪走。
    echo.
    pause
    exit /b 1
)
if not exist "%PS%" (
    echo [错误] 没找到 PowerShell：%PS%
    echo        系统可能被精简过，请用 Windows 自带 PowerShell 手动运行 Repair-AllIcons.ps1
    echo.
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-AllIcons.ps1" -DiagnoseOnly

echo.
echo ------------------------------------------------------------
echo 诊断结束。窗口不会自动关闭，方便你看结果。
echo 按任意键关闭。
pause >nul
exit /b 0