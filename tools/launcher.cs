// 桌面图标修复 —— 单文件 exe 启动器
//
// 作用：把 Repair-AllIcons.ps1 作为资源嵌进 exe，运行时释放到临时目录，
//       再调用系统自带的 powershell.exe 执行它，命令行参数原样转发。
//
// 为什么不直接封装整段脚本逻辑：这样 exe 只有一个几百行的启动器，
// 真正的判定与修复代码仍然只有一份（仓库里的 .ps1），不会出现两份逻辑互相漂移。

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

internal static class Program
{
    private const string ResourceName = "Repair-AllIcons.ps1";

    private static int Main(string[] args)
    {
        string workDir = Path.Combine(Path.GetTempPath(),
            "DesktopIconRepair_" + Guid.NewGuid().ToString("N").Substring(0, 8));
        string scriptPath = Path.Combine(workDir, ResourceName);

        try
        {
            Directory.CreateDirectory(workDir);
            using (Stream res = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
            {
                if (res == null)
                {
                    Console.WriteLine("内置脚本缺失，exe 可能已损坏，请重新下载。");
                    Pause();
                    return 3;
                }
                using (FileStream fs = File.Create(scriptPath)) { res.CopyTo(fs); }
            }

            string psExe = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(psExe)) { psExe = "powershell.exe"; }

            StringBuilder cmd = new StringBuilder();
            cmd.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(scriptPath).Append("\"");
            foreach (string a in args) { cmd.Append(' ').Append(Quote(a)); }

            ProcessStartInfo psi = new ProcessStartInfo(psExe, cmd.ToString());
            psi.UseShellExecute = false;   // 共用当前窗口，输出不打到新窗口

            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("启动失败：" + ex.Message);
            Console.WriteLine("可以直接用同目录下的 一键诊断.bat / 一键修复.bat 代替。");
            Pause();
            return 4;
        }
        finally
        {
            try { if (Directory.Exists(workDir)) Directory.Delete(workDir, true); } catch { }
        }
    }

    private static void Pause()
    {
        try { Console.WriteLine("按回车键退出"); Console.ReadLine(); } catch { }
    }

    private static string Quote(string s)
    {
        if (string.IsNullOrEmpty(s)) { return "\"\""; }
        if (s.IndexOf(' ') < 0 && s.IndexOf('"') < 0 && s.IndexOf('&') < 0) { return s; }
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }
}
