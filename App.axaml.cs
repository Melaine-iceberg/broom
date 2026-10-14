using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Platform;
using Avalonia.Threading;
using broom.Services;
using CommunityToolkit.Mvvm.Input;

namespace broom;

public partial class App : Application
{
    private TrayIcon? _trayIcon;
    private AutoCleanService? _autoClean;
    private AutoCleanScheduler? _scheduler;
    private DiskSpaceWatcher? _diskWatcher;
    private DesktopNotifier? _notifier;

    public override void Initialize()
    {
        // 开发者工具由 Program.cs 的 .WithDeveloperTools() 统一挂载,此处不要再次 AttachDeveloperTools
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            _notifier = new DesktopNotifier(SetTrayTooltip);
            _autoClean = new AutoCleanService();
            SetupTrayIcon();

            var window = new MainWindow();
            desktop.MainWindow = window;

            // 应用内定时 + 托盘常驻:到达设置的频率即自动清理(范围与删除方式按设置,可关闭)
            _scheduler = new AutoCleanScheduler(() => window.ViewModel.Settings, RunScheduledCleanAsync);
            _diskWatcher = new DiskSpaceWatcher(
                () => window.ViewModel.Settings,
                alert => _notifier?.Notify("磁盘空间不足", alert.Message));
            desktop.Exit += (_, _) => DisposeServices();
        }

        base.OnFrameworkInitializationCompleted();
    }

    private void SetupTrayIcon()
    {
        try
        {
            using var stream = AssetLoader.Open(new Uri("avares://broom/Assets/broom.ico"));
            var menu = new NativeMenu();
            menu.Items.Add(new NativeMenuItem("打开 broom") { Command = new RelayCommand(ShowMainWindow) });
            menu.Items.Add(new NativeMenuItem("立即清理(按自动清理设置)") { Command = new RelayCommand(() => _ = RunCleanAsync(AutoCleanTrigger.Manual)) });
            menu.Items.Add(new NativeMenuItemSeparator());
            menu.Items.Add(new NativeMenuItem("退出 broom") { Command = new RelayCommand(ExitApplication) });

            _trayIcon = new TrayIcon
            {
                Icon = new WindowIcon(stream),
                ToolTipText = "broom · 垃圾清理",
                Menu = menu,
                Command = new RelayCommand(ShowMainWindow),
            };
            TrayIcon.SetIcons(this, [_trayIcon]);
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException)
        {
            // 托盘不可用(不支持的桌面环境等)不影响主界面使用
        }
    }

    private async Task RunScheduledCleanAsync() => await RunCleanAsync(AutoCleanTrigger.Scheduled);

    /// <summary>执行一次自动清理并把结果同步到通知与主界面(如果有)。</summary>
    private async Task RunCleanAsync(AutoCleanTrigger trigger)
    {
        if (_autoClean is null)
        {
            return;
        }

        var result = await _autoClean.RunAsync(trigger);
        _notifier?.Notify("broom 自动清理", result.Summary);
        Dispatcher.UIThread.Post(() =>
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime { MainWindow: MainWindow window })
            {
                window.ViewModel.NotifyExternalClean(result.Summary, result.Report, result.Source);
            }
        });
    }

    private void ShowMainWindow()
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime { MainWindow: MainWindow window })
            {
                window.Show();
                window.Activate();
            }
        });
    }

    private void ExitApplication()
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            {
                if (desktop.MainWindow is MainWindow window)
                {
                    window.ExitRequested = true;
                }

                DisposeServices();
                desktop.Shutdown();
            }
        });
    }

    private void SetTrayTooltip(string text)
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (_trayIcon is not null)
            {
                _trayIcon.ToolTipText = text.Length > 120 ? $"{text[..120]}…" : text;
            }
        });
    }

    private void DisposeServices()
    {
        _scheduler?.Dispose();
        _diskWatcher?.Dispose();
        _trayIcon?.Dispose();
        _scheduler = null;
        _diskWatcher = null;
        _trayIcon = null;
    }
}