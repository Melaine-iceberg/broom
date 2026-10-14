using Avalonia;
using System;
using System.Threading;
using broom.Cli;
using broom.Core;
using broom.Localization;

namespace broom;

class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't initialized
    // yet and stuff might break.
    [STAThread]
    public static int Main(string[] args)
    {
        // 文案语言先于界面 / 命令行输出确定:中文系统显示中文,其余显示英文
        Strings.ApplySystemLanguage();

        // 命令行 / 无人值守模式:不启动界面,扫描与清理直接跑完并返回退出码
        if (CommandLineParser.LooksLikeCliRequest(args))
        {
            ConsoleHelper.EnsureConsole();
            using var cts = new CancellationTokenSource();
            Console.CancelKeyPress += (_, e) =>
            {
                e.Cancel = true;
                cts.Cancel();
            };

            return CliRunner.Run(args, Console.Out, Console.Error, ct: cts.Token);
        }

        // GUI 单实例:已有实例在跑时静默退出(命令行 / 无人值守不受限,可与界面并行)
        using var singleInstance = SingleInstanceGuard.TryAcquire();
        if (singleInstance is null)
        {
            return 0;
        }

        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
#if DEBUG
            .WithDeveloperTools()
#endif
            .WithInterFont()
            .LogToTrace();
}
