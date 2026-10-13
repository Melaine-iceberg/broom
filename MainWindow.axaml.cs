using Avalonia.Controls;
using broom.ViewModels;

namespace broom;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        DataContext = new MainWindowViewModel();
    }
}