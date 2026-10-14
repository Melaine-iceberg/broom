using System;
using System.IO;
using System.Text;
using Avalonia.Controls;
using Avalonia.Input.Platform;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using broom.Services;
using broom.ViewModels;

using broom.Localization;
namespace broom;

public partial class MainWindow : Window
{
    private readonly MainWindowViewModel _viewModel;

    /// <summary>托盘菜单“退出”或提权重启请求退出时置位:关闭窗口不再被拦截。</summary>
    public bool ExitRequested { get; set; }

    public MainWindowViewModel ViewModel => _viewModel;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = new MainWindowViewModel();
        DataContext = _viewModel;

        // 新实例已以管理员身份启动,退出当前实例完成“重启”
        _viewModel.RestartRequested += (_, _) =>
        {
            ExitRequested = true;
            Close();
        };
    }

    /// <summary>关闭主窗口时按设置最小化到托盘(保持后台定时清理与磁盘提醒)。</summary>
    protected override void OnClosing(WindowClosingEventArgs e)
    {
        if (!ExitRequested && _viewModel.Settings.CloseToTray)
        {
            e.Cancel = true;
            Hide();
            return;
        }

        base.OnClosing(e);
    }

    private async void CopyReport_Click(object? sender, RoutedEventArgs e)
    {
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is null)
        {
            _viewModel.StatusText = Strings.T("当前环境不支持剪贴板,无法复制报告。");
            return;
        }

        await clipboard.SetTextAsync(_viewModel.ReportText);
        _viewModel.StatusText = Strings.T("清理报告已复制到剪贴板。");
    }

    private async void ExportScan_Click(object? sender, RoutedEventArgs e)
    {
        if (_viewModel.IsBusy || !_viewModel.HasScanned)
        {
            return;
        }

        var topLevel = TopLevel.GetTopLevel(this);
        if (topLevel is null)
        {
            return;
        }

        var file = await topLevel.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = Strings.T("导出扫描结果"),
            SuggestedFileName = $"broom-scan-{DateTime.Now:yyyyMMdd-HHmm}",
            DefaultExtension = "csv",
            FileTypeChoices =
            [
                new FilePickerFileType(Strings.T("CSV 文件(Excel)")) { Patterns = ["*.csv"] },
                new FilePickerFileType(Strings.T("文本文件(制表符分隔)")) { Patterns = ["*.txt"] },
            ],
        });
        if (file is null)
        {
            return;
        }

        try
        {
            var format = file.Name.EndsWith(".txt", StringComparison.OrdinalIgnoreCase)
                ? ScanExportFormat.Txt
                : ScanExportFormat.Csv;
            await using var stream = await file.OpenWriteAsync();
            stream.SetLength(0);
            using (var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true)))
            {
                ScanExportWriter.Write(writer, _viewModel.LastScanResults, format);
            }

            _viewModel.StatusText = Strings.M($"已导出扫描结果:{file.Name}。");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _viewModel.StatusText = Strings.M($"导出失败:{ex.Message}");
        }
    }
}