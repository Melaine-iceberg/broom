using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;

namespace broom;

/// <summary>右下角短暂提示:自动清理结果与磁盘空间提醒;点击任意处立即关闭。</summary>
public partial class NotificationWindow : Window
{
    private static readonly TimeSpan VisibleDuration = TimeSpan.FromSeconds(8);

    private readonly DispatcherTimer _closeTimer;

    /// <summary>供 XAML 运行时加载器使用;实际创建走带标题与内容的构造函数。</summary>
    public NotificationWindow()
        : this("", "")
    {
    }

    public NotificationWindow(string title, string message)
    {
        InitializeComponent();
        TitleText.Text = title;
        MessageText.Text = message;
        _closeTimer = new DispatcherTimer { Interval = VisibleDuration };
        _closeTimer.Tick += (_, _) => Close();
    }

    protected override void OnOpened(EventArgs e)
    {
        base.OnOpened(e);

        // 停靠到主屏幕工作区右下角
        var screen = Screens.ScreenFromWindow(this) ?? Screens.Primary;
        if (screen is not null)
        {
            var area = screen.WorkingArea;
            Position = new PixelPoint(
                area.X + area.Width - (int)Width - 16,
                area.Y + area.Height - (int)Height - 16);
        }

        _closeTimer.Start();
    }

    protected override void OnClosed(EventArgs e)
    {
        _closeTimer.Stop();
        base.OnClosed(e);
    }

    private void OnPointerPressed(object? sender, PointerPressedEventArgs e) => Close();
}
