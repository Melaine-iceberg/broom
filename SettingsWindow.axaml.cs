using Avalonia.Controls;
using broom.Core;
using broom.ViewModels;

namespace broom;

public partial class SettingsWindow : Window
{
    public SettingsWindow() : this(new BroomSettings())
    {
    }

    public SettingsWindow(BroomSettings settings)
    {
        InitializeComponent();
        ViewModel = new SettingsViewModel(settings);
        DataContext = ViewModel;

        // 保存 → Close(设置);取消或直接关窗 → Close(null)
        ViewModel.CloseRequested += result => Close(result);
    }

    public SettingsViewModel ViewModel { get; }
}
