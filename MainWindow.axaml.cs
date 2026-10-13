using Avalonia.Controls;
using broom.Core;
using broom.ViewModels;

namespace broom;

public partial class MainWindow : Window
{
    private readonly MainWindowViewModel _viewModel;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = new MainWindowViewModel();
        DataContext = _viewModel;

        // 新实例已以管理员身份启动,退出当前实例完成“重启”
        _viewModel.RestartRequested += (_, _) => Close();
        _viewModel.SettingsRequested += OnSettingsRequested;
    }

    private async void OnSettingsRequested(object? sender, EventArgs e)
    {
        var dialog = new SettingsWindow(_viewModel.Settings);
        var result = await dialog.ShowDialog<BroomSettings?>(this);
        if (result is not null)
        {
            _viewModel.ApplySettings(result);
        }
    }
}