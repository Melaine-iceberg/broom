using System.Collections.ObjectModel;
using System.Text;
using broom.Core;
using broom.Platform;
using broom.Rules;
using broom.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace broom.ViewModels;

public partial class MainWindowViewModel : ObservableObject
{
    private readonly Scanner _scanner = new();
    private readonly Cleaner _cleaner = new();
    private IReadOnlyList<RuleScanResult>? _lastScan;
    private CancellationTokenSource? _cts;

    public MainWindowViewModel()
    {
        Rules = new ObservableCollection<RuleViewModel>(WindowsRuleSet.Create().Select(rule => new RuleViewModel(rule)));
        foreach (var rule in Rules)
        {
            rule.PropertyChanged += (_, _) => UpdateSummary();
        }

        UpdateSummary();
    }

    public ObservableCollection<RuleViewModel> Rules { get; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanClean))]
    private bool _isBusy;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanClean))]
    private bool _hasScanned;

    [ObservableProperty]
    private string _statusText = "点击“开始扫描”,分析磁盘上可以清理的内容。";

    [ObservableProperty]
    private double _progressValue;

    [ObservableProperty]
    private bool _isProgressVisible;

    [ObservableProperty]
    private string _summaryText = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasReport))]
    private string _reportText = "";

    [ObservableProperty]
    private bool _permanentDelete;

    public bool CanClean => HasScanned && !IsBusy;

    public bool HasReport => ReportText.Length > 0;

    [RelayCommand]
    private async Task ScanAsync()
    {
        if (IsBusy)
        {
            return;
        }

        await ScanCoreAsync();
    }

    [RelayCommand]
    private void Cancel() => _cts?.Cancel();

    [RelayCommand]
    private async Task CleanAsync()
    {
        if (IsBusy)
        {
            return;
        }

        var selected = GetSelectedResults();
        if (selected.Count == 0)
        {
            StatusText = "没有勾选可清理的内容 —— 请先扫描并选择要清理的项目。";
            return;
        }

        IsBusy = true;
        IsProgressVisible = true;
        ProgressValue = 0;
        var cts = new CancellationTokenSource();
        _cts = cts;
        var cancelled = false;
        try
        {
            var (deleter, warning) = CreateDeleter();
            var progress = new Progress<CleanProgress>(p =>
            {
                ProgressValue = p.RuleCount == 0 ? 0 : p.RuleIndex * 100.0 / p.RuleCount;
                StatusText = $"正在清理:{p.RuleName}";
            });

            var report = await _cleaner.CleanAsync(selected, deleter, progress, cts.Token);
            ReportText = BuildReport(report, deleter, warning);
            cancelled = report.WasCancelled;
            StatusText = cancelled ? "已取消清理,报告中为已完成的部分。" : "清理完成。";
        }
        catch (OperationCanceledException)
        {
            cancelled = true;
            StatusText = "已取消清理。";
        }
        catch (Exception ex)
        {
            StatusText = $"清理失败:{ex.Message}";
        }
        finally
        {
            _cts = null;
            cts.Dispose();
            IsBusy = false;
            IsProgressVisible = false;
        }

        if (cancelled)
        {
            return;
        }

        // 清理后立即重扫,界面上的数字反映真实剩余(被占用 / 无权限的文件会重新出现)
        await ScanCoreAsync();
    }

    private async Task ScanCoreAsync()
    {
        IsBusy = true;
        IsProgressVisible = true;
        ProgressValue = 0;
        var cts = new CancellationTokenSource();
        _cts = cts;
        try
        {
            foreach (var rule in Rules)
            {
                rule.StatusText = "扫描中…";
                rule.HasFailures = false;
            }

            var progress = new Progress<ScanProgress>(p =>
            {
                ProgressValue = p.RuleCount == 0 ? 0 : p.RuleIndex * 100.0 / p.RuleCount;
                StatusText = p.CurrentPath.Length > 0
                    ? $"正在扫描:{p.RuleName} — {p.CurrentPath}"
                    : $"正在扫描:{p.RuleName}";
            });

            var results = await _scanner.ScanAsync(Rules.Select(r => r.Rule).ToList(), progress, cts.Token);
            _lastScan = results;
            ApplyScanResults(results);

            HasScanned = true;
            ProgressValue = 100;
            StatusText = "扫描完成。";
        }
        catch (OperationCanceledException)
        {
            // 丢弃半成品结果,恢复上一次完整结果(若有)
            StatusText = _lastScan is null ? "已取消扫描。" : "已取消扫描,保留上一次的扫描结果。";
            if (_lastScan is not null)
            {
                ApplyScanResults(_lastScan);
            }
            else
            {
                foreach (var rule in Rules)
                {
                    rule.StatusText = "尚未扫描";
                }
            }
        }
        catch (Exception ex)
        {
            StatusText = $"扫描失败:{ex.Message}";
        }
        finally
        {
            _cts = null;
            cts.Dispose();
            IsBusy = false;
            IsProgressVisible = false;
        }
    }

    private void ApplyScanResults(IReadOnlyList<RuleScanResult> results)
    {
        var byRule = results.ToDictionary(r => r.Rule);
        foreach (var rule in Rules)
        {
            if (!byRule.TryGetValue(rule.Rule, out var result))
            {
                continue;
            }

            rule.SizeBytes = result.TotalBytes;
            rule.HasFailures = result.Errors.Count > 0;
            rule.StatusText = result.ItemCount == 0
                ? "没有可清理的内容"
                : $"{result.ItemCount:N0} 个文件";
        }

        UpdateSummary();
    }

    private List<RuleScanResult> GetSelectedResults()
    {
        if (_lastScan is null)
        {
            return [];
        }

        var selectedRules = Rules.Where(r => r.IsSelected).Select(r => r.Rule).ToHashSet();
        return _lastScan.Where(r => selectedRules.Contains(r.Rule)).ToList();
    }

    private (IFileDeleter Deleter, string? Warning) CreateDeleter()
    {
        if (PermanentDelete)
        {
            return (new PermanentFileDeleter(), null);
        }

        if (OperatingSystem.IsWindows())
        {
            return (new WindowsRecycleBinDeleter(), null);
        }

        return (new PermanentFileDeleter(), "当前平台暂不支持回收站,本次改为永久删除。");
    }

    private static string BuildReport(CleanupReport report, IFileDeleter deleter, string? warning)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"{deleter.Name}:清理 {report.TotalDeleted:N0} 项,共 {Formatting.FormatBytes(report.TotalBytesRemoved)}。");
        if (report.WasCancelled)
        {
            sb.AppendLine("清理已取消,以上为已完成的部分。");
        }

        if (deleter is WindowsRecycleBinDeleter)
        {
            sb.AppendLine("提示:移入回收站的文件仍占用磁盘空间,清空回收站后才会真正释放。");
        }

        if (warning is not null)
        {
            sb.AppendLine(warning);
        }

        foreach (var result in report.Results)
        {
            if (result.DeletedCount == 0 && result.Failures.Count == 0)
            {
                continue;
            }

            sb.AppendLine($"· {result.Rule.DisplayName}:{result.DeletedCount:N0} 项 / {Formatting.FormatBytes(result.BytesRemoved)}");
            foreach (var failure in result.Failures.Take(10))
            {
                sb.AppendLine($"    ✗ {failure.Path}({failure.Reason})");
            }

            if (result.Failures.Count > 10)
            {
                sb.AppendLine($"    …其余 {result.Failures.Count - 10} 项失败未列出");
            }
        }

        if (report.SkippedRules.Count > 0)
        {
            sb.AppendLine($"· 未执行的规则:{string.Join("、", report.SkippedRules.Select(r => r.DisplayName))}");
        }

        return sb.ToString().TrimEnd();
    }

    private void UpdateSummary()
    {
        if (!HasScanned)
        {
            SummaryText = "尚未扫描";
            return;
        }

        var total = Rules.Sum(r => r.SizeBytes);
        var selected = Rules.Where(r => r.IsSelected).Sum(r => r.SizeBytes);
        SummaryText = $"共发现 {Formatting.FormatBytes(total)},已选择 {Formatting.FormatBytes(selected)}";
    }
}
