using System;
using System.IO;
using System.Text;
using Avalonia.Controls;
using Avalonia.Input.Platform;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using broom.Services;
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

    private async void CopyReport_Click(object? sender, RoutedEventArgs e)
    {
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is null)
        {
            _viewModel.StatusText = "当前环境不支持剪贴板,无法复制报告。";
            return;
        }

        await clipboard.SetTextAsync(_viewModel.ReportText);
        _viewModel.StatusText = "清理报告已复制到剪贴板。";
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
            Title = "导出扫描结果",
            SuggestedFileName = $"broom-scan-{DateTime.Now:yyyyMMdd-HHmm}",
            DefaultExtension = "csv",
            FileTypeChoices =
            [
                new FilePickerFileType("CSV 文件(Excel)") { Patterns = ["*.csv"] },
                new FilePickerFileType("文本文件(制表符分隔)") { Patterns = ["*.txt"] },
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

            _viewModel.StatusText = $"已导出扫描结果:{file.Name}。";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _viewModel.StatusText = $"导出失败:{ex.Message}";
        }
    }
}