# 更新日志

桌面图标修复（Windows 桌面快捷方式白纸图标检测与修复工具）。
版本号体现在 `Repair-AllIcons.ps1` 的 `$ScriptVersion`、本文件、GitHub Release 三处，改版本时三处要一致。

## 2.2.0 — 2026-11-09

### 新增

- **单文件 exe**：`desktop-icon-repair-v2.2.0.exe`，双击直接进菜单（`1` 只检测 / `2` 检测并修复 / `3` 回滚 / `0` 退出）。命令行参数也照常转发，`-DiagnoseOnly`、`-ScanPath`、`-Restore` 都能用。
- **无参数启动给菜单**：直接跑 `.ps1` 或双击 exe 时先问你要做什么，不会一打开就开始改；带参数的调用（三个 bat）行为完全不变。
- **可复现的打包方式**：`tools\launcher.cs` 是几十行的启动器，`tools\build-exe.ps1` 用系统自带的 `csc.exe` 把 `Repair-AllIcons.ps1` 作为资源编进 exe，不需要安装任何模块。

### 说明

- exe 只是外壳，判定与修复逻辑仍然只有 `Repair-AllIcons.ps1` 一份，不存在两份代码互相漂移的问题。
- exe 没有数字签名，首次运行可能弹 SmartScreen「已保护你的电脑」，点「更多信息 → 仍要运行」。
- 曾试过用 ps2exe 打包，实测其产物在本机会卡在控制台输入、重定向后拿不到输出、进程不退出，因此改为 csc 方案。

## 2.1.0 — 2026-11-09

第一个正式对外发布的版本。

### 新增

- **版本号与软件名**：主脚本内置 `$ScriptName` / `$ScriptVersion`，运行横幅显示「桌面图标修复 v2.1.0」，方便反馈问题时对上版本。
- **下载入口**：README 顶部加「点这里下载最新版」，直接跳到 Releases 最新版；徽章显示最新版本、平台、许可证、CI 状态。
- **更新日志**：本文件。

### 保持不变

- 五个 bat / ps1 文件与判定逻辑一律未改，行为与 v2.0.0 一致。

## 2.0.0 — 2026-11-09

### 新增

- **`Repair-AllIcons.ps1` 主引擎**：用「兜底图 / 目标程序图 / 复制到别处对照」的相似度比对，替代「彩色像素少于 80 就是白纸」的阈值判定。黑白、深色图标不再误报（作者机器 27 个快捷方式实测全部判正常，旧判据误报 4 个）。
- **五类判定**：`正常` / `可修(桌面)` / `可修(单)` / `可修(路径)` / `需人工`，只修真坏了的，正常项不碰。
- **目标搬家自动找回**：快捷方式指向的 exe 不在原路径时，按文件名依次查 App Paths、已安装程序清单、Program Files 限深搜索；找到唯一候选则改写目标路径 + 工作目录 + 图标。
- **逐项备份与回滚**：每个 lnk 改动前单独备份到 `<备份目录>\lnk\`，`_map.txt` 记录原完整路径，`-Restore` 逐项还原。注册表侧仍导出 `UserShellFolders.reg` 等。
- **英文概览** `README_EN.md`。
- **CI**：`tools/verify-files.ps1` 校验 ps1(BOM+CRLF+语法)、bat(GBK+CRLF)、md(LF)；PSScriptAnalyzer 错误级必须通过。

### 改动

- `Diagnose-DesktopIcons.ps1` 改为转发新引擎的只读诊断，旧阈值判据不再输出误报。
- 三个 bat 全部改为调用新引擎（诊断 → `-DiagnoseOnly`，修复 → `-Yes`，回滚 → `-Restore`）。
- README 增补通用版判定表、实测输出、能力边界、备份与回滚说明。

### 修复

- `reg export` 不存在的键时 stderr 触发 `NativeCommandError` 导致备份步骤中断。
- PowerShell 无 `HKCR:` 盘符导致 `DriveNotFoundException`；写入改为「机器级失败自动回退用户级」。
- 图标缓存删除改用 `Remove-Item` 并统计删除 / 失败数量。

## 1.0.0 — 2026-11-09

最初的版本，只处理一种病因：桌面路径的图标链路损坏。

- 用「彩色像素少于 80 判白纸、多于 200 判正常」的阈值判定。
- 修复方式是 robocopy 桌面 → 新目录，改 `User Shell Folders\Desktop` 与 `Shell Folders\Desktop`，重启 explorer。
- `-Restore` 恢复注册表备份与桌面路径。

已知问题（2.0.0 已解决）：黑白图标会被误报；程序搬家、快捷方式本身损坏这两类只会报「修不了」。
