# Desktop Icon Repair v2.1.0

Windows desktop shortcuts all showing a blank-page icon? Fix it in one click. Download the latest ZIP from [Releases](https://github.com/wwj5/desktop-icon-repair/releases/latest), unzip, double-click `一键诊断.bat` then `一键修复.bat`. No install, no admin rights, fully reversible.

> **Symptom**: every `.lnk` on the desktop renders as the generic "blank page + blue shortcut arrow" icon. The same `.lnk` copied to Documents, Downloads or `%TEMP%` shows its real icon. Rebuilding the icon cache, clearing `Shell Icons`, re-logging, and reinstalling the app all failed.
>
> **Root cause in the author's case**: a third-party "remove the shortcut arrow" tweaker redirected the shell icon handler to a blank `.ico`. After it was removed, the desktop shell namespace binding kept degrading until every desktop `.lnk` fell back to the generic icon.

**Fastest path**: download the ZIP, double-click `一键诊断.bat` to see the verdicts, then `一键修复.bat`. No admin rights, fully reversible.

`中文完整文档见 [README.md](README.md)` — this file is a condensed English overview.

---

## 30-second self check

1. Copy any blank desktop shortcut into `Documents`.
2. Press `F5` on the desktop and look at that copy.

- Copy becomes colorful → the desktop icon *channel* is broken. This repo fixes it.
- Copy is still blank → the shortcut file itself, or its target program, is broken. See "Boundaries" below.

---

## How the tool decides (no color thresholds)

Counting "colored pixels" and calling <80 pixels a blank icon **misreports** black-and-white or dark icons (the author's own machine had 4 healthy shortcuts with 24/0/0 colored pixels). This tool compares images instead:

| Reference / subject | How it is obtained | Meaning |
| --- | --- | --- |
| Fallback image A | a temporary `.lnk` pointing at a non-existent target | what "blank page + arrow" looks like |
| Target image B | the icon of the exe the `.lnk` points to | what it should look like |
| Current image | the icon the `.lnk` actually displays | the subject |

All three are normalized to 32×32 and compared by mean absolute difference (threshold 12). If the current image differs from A, the icon is fine. If it matches A, the same `.lnk` is copied to a temp folder and measured again to tell "desktop channel is broken" from "shortcut itself is broken".

## Verdicts

| Verdict | Situation | Action |
| --- | --- | --- |
| `正常` (OK) | differs from the fallback image | leave it alone |
| `可修(桌面)` (fixable: desktop) | blank in this folder, fine when copied elsewhere | clean stale `Shell Icons`, rebuild icon cache, migrate the desktop path |
| `可修(单)` (fixable: single) | blank everywhere, target icon is fine | rewrite that `.lnk`'s `IconLocation` |
| `可修(路径)` (fixable: path) | target program moved | find the exe by name via App Paths / installed-app registry / Program Files, rewrite target + working dir + icon |
| `需人工` (manual) | Store/UWP shortcut, program uninstalled, exe has no icon resource, multiple same-name candidates | report the reason and the manual step only |

After repairing, the tool re-scans and lists what it could not fix.

## Usage

Double-click:

- `一键诊断.bat` — read-only scan
- `一键修复.bat` — detect, then repair only what is fixable
- `一键回滚.bat` — restore the latest backup

Command line (main engine `Repair-AllIcons.ps1`):

```powershell
# read-only scan
powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1 -DiagnoseOnly

# scan + repair (5s countdown, Ctrl+C to cancel)
powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1

# no prompt (what the .bat uses)
powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1 -Yes

# scan one arbitrary folder, no desktop migration
powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1 -DiagnoseOnly -ScanPath "D:\SomeFolder"

# custom new desktop location
powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1 -NewDesktopPath "D:\Desktop"

# roll back the latest backup
powershell -ExecutionPolicy Bypass -File .\Repair-AllIcons.ps1 -Restore
```

## Backup and rollback

Before every change a backup directory is created under `%TEMP%\IconRepair_<timestamp>\`:

- registry exports: `UserShellFolders.reg`, `ShellFolders.reg`, `ShellIcons_*.reg`, `lnkfile.reg`, `CLSID_lnk.reg`
- modified shortcuts: `lnk\` subfolder, with `lnk\_map.txt` recording each original full path

`-Restore` replays them one by one. Machine-level keys (`HKLM\SOFTWARE\Classes\lnkfile`) need admin rights to restore; without them the import step reports a failure, and that is expected — user-level settings and shortcuts still come back.

## Boundaries (it will not pretend to fix these)

- **Store / UWP shortcuts** (no target path): the icon comes from the app package. Reinstall the app or re-drag it from Start.
- **Program genuinely uninstalled** and no same-name exe exists anywhere: delete the shortcut and recreate it after reinstalling.
- **Exe has no icon resource**: set one manually via Properties → Change Icon.
- **Several same-name candidates found**: the tool refuses to guess.

## Files

| File | Purpose |
| --- | --- |
| `Repair-AllIcons.ps1` | main engine: scan, classify, repair, back up, roll back |
| `一键诊断.bat` / `一键修复.bat` / `一键回滚.bat` | double-click entry points (GBK + CRLF, absolute paths, PATH-safe) |
| `Diagnose-DesktopIcons.ps1` | legacy read-only entry, now a thin forwarder to the new engine |
| `Fix-DesktopIcons.ps1` | legacy desktop-path migration only |
| `README.md` | full Chinese documentation: real case, root cause, symptom variants, troubleshooting |
| `LICENSE` | MIT |

## Notes

- No admin rights, no UAC prompt; machine-level keys fall back to `HKCU\Software\Classes` overrides.
- Explorer restarts once (taskbar flickers) so the changes take effect.
- Do **not** delete `Bags\1\Desktop` / `BagMRU` to fix icons — that is exactly where icon positions live.
- Prefer never using "remove shortcut arrow" tweakers; if you must, only dump `Shell Icons` 29/77 to a blank `.ico` and never touch `lnkfile` or the `CLSID` keys.

MIT © 2026 wwj5
