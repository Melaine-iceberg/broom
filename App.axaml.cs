using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace broom;

public partial class App : Application
{
    public override void Initialize()
    {
        // 开发者工具由 Program.cs 的 .WithDeveloperTools() 统一挂载,此处不要再次 AttachDeveloperTools
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow();
        }

        base.OnFrameworkInitializationCompleted();
    }
}