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
    private readonly SettingsService _settingsService = new();
    private readonly IElevationService _elevation = PlatformServices.CreateElevationService();
    private readonly IRebootDeleteService _rebootDeletes = PlatformServices.CreateRebootDeleteService();
    private readonly List<DeleteFailure> _pendingRebootDeletes = [];
    private IReadOnlyList<RuleScanResult>? _lastScan;
    private CancellationTokenSource? _cts;

    public MainWindowViewModel()
    {
        Settings = _settingsService.Load();
        IsElevated = _elevation.IsElevated;
        PermanentDelete = Settings.DefaultPermanentDelete;

        Rules = new ObservableCollection<RuleViewModel>();
        RebuildRules();
        UpdateSummary();
    }

    /// <summary>提权重启已成功启动新实例,视图收到后应退出当前进程。</summary>
    public event EventHandler? RestartRequested;

    /// <summary>请求打开设置窗口(保存后由视图调用 <see cref="ApplySettings"/>)。</summary>
    public event EventHandler? SettingsRequested;

    public ObservableCollection<RuleViewModel> Rules { get; }

    /// <summary>当前生效的设置(设置页保存后整体替换)。</summary>
    public BroomSettings Settings { get; private set; }

    /// <summary>当前进程是否以管理员身份运行(进程生命周期内不变)。</summary>
    public bool IsElevated { get; }

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

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ScheduleRebootDeleteCommand))]
    [NotifyPropertyChangedFor(nameof(HasPendingRebootDeletes))]
    [NotifyPropertyChangedFor(nameof(ScheduleRebootDeleteText))]
    private int _pendingRebootCount;

    public bool CanClean => HasScanned && !IsBusy;

    public bool HasReport => ReportText.Length > 0;

    /// <summary>清理报告中是否存在可登记“重启后删除”的失败项。</summary>
    public bool HasPendingRebootDeletes => PendingRebootCount > 0;

    public bool CanScheduleRebootDelete => PendingRebootCount > 0 && IsElevated && _rebootDeletes.IsSupported;

    public string ScheduleRebootDeleteText => $"安排重启后删除({PendingRebootCount})";

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
    private void RestartElevated()
    {
        if (IsBusy)
        {
            return;
        }

        if (!_elevation.TryRestartElevated(out var error))
        {
            StatusText = error ?? "提权重启失败。";
            return;
        }

        RestartRequested?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void OpenSettings()
    {
        if (IsBusy)
        {
            return;
        }

        SettingsRequested?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>把清理报告中可登记的失败项交给系统重启队列(不静默堆积,由用户显式触发)。</summary>
    [RelayCommand(CanExecute = nameof(CanScheduleRebootDelete))]
    private void ScheduleRebootDelete()
    {
        if (IsBusy || _pendingRebootDeletes.Count == 0)
        {
            return;
        }

        var scheduled = 0;
        var failures = new List<DeleteFailure>();
        foreach (var item in _pendingRebootDeletes)
        {
            if (_rebootDeletes.TrySchedule(item.Path, out var error))
            {
                scheduled++;
            }
            else
            {
                failures.Add(new DeleteFailure(item.Path, error));
            }
        }

        _pendingRebootDeletes.Clear();
        _pendingRebootDeletes.AddRange(failures);
        PendingRebootCount = _pendingRebootDeletes.Count;

        if (failures.Count == 0)
        {
            StatusText = $"已安排 {scheduled} 项重启后删除,重启后生效。";
        }
        else if (scheduled == 0)
        {
            StatusText = "安排重启后删除失败,请确认已以管理员身份运行。";
        }
        else
        {
            StatusText = $"已安排 {scheduled} 项,{failures.Count} 项安排失败。";
        }

        if (scheduled > 0)
        {
            ReportText = $"{ReportText}{Environment.NewLine}✔ 已安排 {scheduled} 项重启后删除(重启后生效,重启前文件仍占用空间)。";
        }
    }

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
            SetPendingRebootDeletes(report);
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

            var results = await _scanner.ScanAsync(Rules.Select(r => r.Rule).ToList(), Settings.ExcludedPaths, progress, cts.Token);
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

    private void SetPendingRebootDeletes(CleanupReport report)
    {
        _pendingRebootDeletes.Clear();
        foreach (var failure in report.Results.SelectMany(r => r.Failures))
        {
            // 只有真实文件路径可以登记重启后删除(跳过“<回收站>”等伪路径)
            if (Path.IsPathFullyQualified(failure.Path))
            {
                _pendingRebootDeletes.Add(failure);
            }
        }

        PendingRebootCount = _pendingRebootDeletes.Count;
    }

    /// <summary>应用设置页保存的结果:持久化,并在规则集或排除项变化时要求重新扫描。</summary>
    public void ApplySettings(BroomSettings settings)
    {
        var ruleSetChanged = Settings.ShowHighRiskRules != settings.ShowHighRiskRules
            || !CustomRulesEqual(Settings.CustomRules, settings.CustomRules);
        var excludesChanged = !Settings.ExcludedPaths.SequenceEqual(settings.ExcludedPaths);

        Settings = settings;
        PermanentDelete = settings.DefaultPermanentDelete;

        string? saveError = null;
        try
        {
            _settingsService.Save(settings);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            saveError = ex.Message;
        }

        if (ruleSetChanged)
        {
            RebuildRules();
        }

        if (ruleSetChanged || excludesChanged)
        {
            ResetScanState();
            StatusText = saveError is null
                ? "设置已保存,请重新扫描。"
                : $"设置保存失败:{saveError}(本次会话内仍生效)。";
        }
        else
        {
            StatusText = saveError is null ? "设置已保存。" : $"设置保存失败:{saveError}";
        }
    }

    private void ResetScanState()
    {
        _lastScan = null;
        HasScanned = false;
        foreach (var rule in Rules)
        {
            rule.SizeBytes = 0;
            rule.HasFailures = false;
            rule.StatusText = "尚未扫描";
        }

        UpdateSummary();
    }

    private static bool CustomRulesEqual(List<CustomRule> a, List<CustomRule> b)
        => a.Count == b.Count && a.Zip(b).All(pair => SameRule(pair.First, pair.Second));

    private static bool SameRule(CustomRule x, CustomRule y)
        => x.Name == y.Name
            && x.Path == y.Path
            && x.Risk == y.Risk
            && x.Recommended == y.Recommended
            && x.IncludePatterns.SequenceEqual(y.IncludePatterns)
            && x.ExcludePatterns.SequenceEqual(y.ExcludePatterns);

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

    private string BuildReport(CleanupReport report, IFileDeleter deleter, string? warning)
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

        if (!IsElevated && report.Results.Any(r => r.Rule.RequiresAdmin && r.Failures.Count > 0))
        {
            sb.AppendLine("部分失败可通过提权重试 —— 点击右上角“以管理员身份重启”。");
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

    private void RebuildRules()
    {
        Rules.Clear();
        foreach (var rule in CreateRules())
        {
            var viewModel = new RuleViewModel(rule);
            viewModel.PropertyChanged += (_, _) => UpdateSummary();
            Rules.Add(viewModel);
        }
    }

    private IReadOnlyList<CleanupRule> CreateRules()
    {
        var rules = WindowsRuleSet.Create(Settings).AsEnumerable();
        if (!Settings.ShowHighRiskRules)
        {
            rules = rules.Where(r => r.Risk != RiskLevel.High);
        }

        return rules.ToList();
    }
}
