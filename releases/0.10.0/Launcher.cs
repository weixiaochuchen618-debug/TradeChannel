using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        try
        {
            bool selfTest = args.Length == 3 && args[0] == "--self-test" && args[1] == "--output";
            if (args.Length != 0 && !selfTest)
                throw new ArgumentException("验证用法：TradeChannel.exe --self-test --output 输出目录");
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string temporaryRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (Path.GetFullPath(root).StartsWith(temporaryRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("请先点击「全部解压」，把整个 TradeChannel 文件夹放到固定位置（例如桌面），再运行 TradeChannel.exe。\n\n不要直接在压缩包或临时目录中启动：关闭窗口后，解压工具可能删除后台所需文件。");
            string manifest = Path.Combine(root, "package.sha256");
            if (!File.Exists(manifest)) throw new InvalidDataException("安装包校验清单缺失，请完整解压后再运行。");
            foreach (string line in File.ReadAllLines(manifest, Encoding.UTF8))
            {
                if (String.IsNullOrWhiteSpace(line)) continue;
                int divider = line.IndexOf('|');
                if (divider != 64) throw new InvalidDataException("安装包校验格式错误。");
                string relative = line.Substring(divider + 1);
                string full = Path.GetFullPath(Path.Combine(root, relative));
                if (!full.StartsWith(Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase) || Path.IsPathRooted(relative))
                    throw new InvalidDataException("安装包包含无效路径。");
                if (!File.Exists(full)) throw new FileNotFoundException("缺少文件：" + relative);
                string hash;
                using (var stream = File.OpenRead(full))
                using (var algorithm = SHA256.Create())
                    hash = BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "");
                if (!String.Equals(hash, line.Substring(0, 64), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("文件校验失败：" + relative + "。请重新解压原始安装包。");
            }
            string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            string script = Path.Combine(root, "TradeChannel.ps1").Replace("'", "''");
            string testArguments = selfTest ? " -SelfTest -TestOutputDirectory '" + Path.GetFullPath(args[2]).Replace("'", "''") + "'" : "";
            string command = "try { & '" + script + "'" + testArguments + " } catch { " +
                (selfTest ? "Write-Error $_.Exception.Message; exit 1" : "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('控制台启动未完成。请完整解压本版本，确认文件齐全后重新打开。错误类型：' + $_.Exception.GetType().Name, 'TradeChannel') | Out-Null; exit 1") + " }";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
            var info = new ProcessStartInfo(shell, "-NoProfile -STA -ExecutionPolicy Bypass -EncodedCommand " + encoded);
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            // A PowerShell 7 parent can pass Core module paths to Windows
            // PowerShell 5.1. Limit this child to its own Windows modules.
            info.EnvironmentVariables["PSModulePath"] = Path.Combine(Path.GetDirectoryName(shell), "Modules");
            var process = Process.Start(info);
            if (selfTest)
            {
                process.WaitForExit();
                int exitCode = process.ExitCode;
                process.Dispose();
                return exitCode;
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "TradeChannel 启动未完成", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
