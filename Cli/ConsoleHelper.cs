using System.Runtime.InteropServices;
using System.Text;

namespace broom.Cli;

/// <summary>
/// 命令行模式的控制台:主程序是 WinExe(没有控制台),Windows 下先附加父进程控制台
/// (在终端里运行时直接输出到该终端),失败且输出未被重定向时再分配一个。
/// </summary>
internal static class ConsoleHelper
{
    private const int AttachParentProcess = -1;

    public static void EnsureConsole()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        try
        {
            if (!AttachConsole(AttachParentProcess) && !Console.IsOutputRedirected)
            {
                AllocConsole();
            }

            // 附加后重绑标准流,并统一用 UTF-8 输出中文(控制台流不带 BOM)
            var utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
            Console.OutputEncoding = utf8;
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true });
            Console.SetError(new StreamWriter(Console.OpenStandardError(), utf8) { AutoFlush = true });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            // 拿不到控制台时按重定向输出处理,不影响命令行流程
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();
}
