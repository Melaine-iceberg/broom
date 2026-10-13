using Avalonia.Controls;
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
    }
}