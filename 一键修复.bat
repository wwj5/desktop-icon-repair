@echo off
"%SystemRoot%\System32\chcp.com" 936 >nul
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
title 桌面快捷方式图标修复
color 0E
cd /d "%~dp0"

echo ============================================================
echo   修复：桌面快捷方式图标变成白纸
echo ============================================================
echo.
echo 它会先自动检测每个快捷方式，只修真的坏了的：
echo   1. 清掉"去箭头工具"留下的空白图标设置
echo   2. 重建图标缓存（只在需要时做）
echo   3. 修单个快捷方式的图标，或把搬家了的程序重新指回去
echo   4. 整块桌面都白纸时，才把桌面位置迁到新文件夹（原桌面一个文件都不动）
echo   5. 重启资源管理器（任务栏会闪一下，属正常现象）
echo.
echo 每个快捷方式改动前都会单独备份，不需要管理员权限，不删除任何文件。
echo 请先保存正在编辑的文档（Word / Excel / 绘图软件）。
echo.

if not exist "Repair-AllIcons.ps1" (
    echo [错误] 没找到 Repair-AllIcons.ps1
    echo        请确认 bat 和 ps1 放在同一个文件夹里。
    echo.
    pause
    exit /b 1
)
if not exist "%PS%" (
    echo [错误] 没找到 PowerShell：%PS%
    echo        请用 Windows 自带 PowerShell 手动运行 Repair-AllIcons.ps1
    echo.
    pause
    exit /b 1
)

set "ok="
set /p "ok=确认开始修复？输入 y 再回车（输入其它任意键取消）: "
if /i not "%ok%"=="y" goto cancel

echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-AllIcons.ps1" -Yes

echo.
echo ------------------------------------------------------------
echo 修复结束。请看桌面图标是否恢复彩色。
echo 想恢复原样，双击"一键回滚.bat"即可。
echo 按任意键关闭。
pause >nul
exit /b 0

:cancel
echo.
echo 已取消，未做任何改动。
pause >nul
exit /b 0