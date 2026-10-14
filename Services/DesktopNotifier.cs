using Avalonia.Threading;

namespace broom.Services;

/// <summary>
/// 桌面通知:右下角弹出的短暂提示窗口(主窗口隐藏到托盘时同样可见),并同步托盘图标的提示文字。
/// </summary>
public sealed class DesktopNotifier
{
    private readonly Action<string>? _setTrayTooltip;

    public DesktopNotifier(Action<string>? setTrayTooltip = null) => _setTrayTooltip = setTrayTooltip;

    public void Notify(string title, string message)
    {
        try
        {
            _setTrayTooltip?.Invoke($"broom · {title}:{message}");
            Dispatcher.UIThread.Post(() =>
            {
                var window = new NotificationWindow(title, message);
                window.Show();
            });
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException)
        {
            // 通知是辅助信息:失败不影响清理流程
        }
    }
}
