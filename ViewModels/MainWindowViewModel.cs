using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text;
using broom.Core;
using broom.Platform;
using broom.Rules;
using broom.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using broom.Localization;
namespace broom.ViewModels;

public partial class MainWindowViewModel : ObservableObject
{
    private readonly SettingsService _settingsService = new();
    private readonly IElevationService _elevation = PlatformServices.CreateElevationService();
    private readonly IRebootDeleteService _rebootDeletes = PlatformServices.CreateRebootDeleteService();
    private readonly QuarantineService _quarantine = new();
    private readonly CleanupWorkflow _workflow;
    private readonly CleanupHistoryService _historyService = new();
    private readonly List<DeleteFailure> _pendingRebootDeletes = [];
    private IReadOnlyList<RuleScanResult>? _lastScan;
    private QuarantineSession? _lastQuarantineSession;
    private CancellationTokenSource? _cts;
    private bool _suspendSelectionPersist;

    /// <summary>文件路径比较方式(Windows 不区分大小写),与扫描器的排除判定保持一致。</summary>
    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;

    public MainWindowViewModel()
    {
        _workflow = new CleanupWorkflow(_quarantine);
        Settings = _settingsService.Load();
        IsElevated = _elevation.IsElevated;
        PermanentDelete = Settings.DefaultPermanentDelete;

        Rules = new ObservableCollection<RuleViewModel>();
        RebuildRules();
        ResetSettingsEditor();
        UpdateSummary();
        RefreshHistory();
        PurgeExpiredQuarantine(Settings.QuarantineRetentionDays);
    }

    /// <summary>提权重启已成功启动新实例,视图收到后应退出当前进程。</summary>
    public event EventHandler? RestartRequested;

    /// <summary>内嵌设置页状态(保存 / 放弃更改由 <see cref="SettingsViewModel"/> 触发)。</summary>
    public SettingsViewModel SettingsEditor { get; private set; } = null!;

    public ObservableCollection<RuleViewModel> Rules { get; }

    /// <summary>当前可见的规则,按类别分组(受搜索与风险筛选影响)。</summary>
    public ObservableCollection<RuleGroupViewModel> RuleGroups { get; } = [];

    /// <summary>当前生效的设置(设置页保存后整体替换)。</summary>
    public BroomSettings Settings { get; private set; }

    /// <summary>当前进程是否以管理员身份运行(进程生命周期内不变)。</summary>
    public bool IsElevated { get; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanClean))]
    private bool _isBusy;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanClean))]
    [NotifyPropertyChangedFor(nameof(TotalSizeText))]
    [NotifyPropertyChangedFor(nameof(ScanButtonText))]
    private bool _hasScanned;

    [ObservableProperty]
    private string _statusText = Strings.T("点击“开始扫描”,分析磁盘上可以清理的内容。");

    [ObservableProperty]
    private double _progressValue;

    [ObservableProperty]
    private bool _isProgressVisible;

    /// <summary>风险等级筛选选项(Level 为 null 表示不过滤)。</summary>
    public IReadOnlyList<RiskFilterOption> RiskFilters => RiskFilterOptions;

    /// <summary>规则排序选项。</summary>
    public IReadOnlyList<SortOption> SortOptions => SortOptionList;

    private static readonly RiskFilterOption[] RiskFilterOptions =
    [
        new(null, Strings.T("全部等级")),
        new(RiskLevel.Safe, Strings.T("安全")),
        new(RiskLevel.Caution, Strings.T("谨慎")),
        new(RiskLevel.High, Strings.T("高风险")),
    ];

    private static readonly SortOption[] SortOptionList =
    [
        new(RuleSort.SizeDescending, Strings.T("按大小从大到小")),
        new(RuleSort.SizeAscending, Strings.T("按大小从小到大")),
        new(RuleSort.Name, Strings.T("按名称")),
    ];

    [ObservableProperty]
    private RiskFilterOption _selectedRiskFilter = RiskFilterOptions[0];

    [ObservableProperty]
    private SortOption _selectedSortOption = SortOptionList[0];

    [ObservableProperty]
    private string _searchText = "";

    /// <summary>当前处于"清理"页还是"设置"页。</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsSettingsPage))]
    private bool _isCleanPage = true;

    public bool IsSettingsPage => !IsCleanPage;

    /// <summary>扫描到的总量,界面上的大数字(尚未扫描时为占位符)。</summary>
    public string TotalSizeText => HasScanned ? Formatting.FormatBytes(Rules.Sum(r => r.SizeBytes)) : "—";

    /// <summary>已勾选的规则数与预计释放空间。</summary>
    [ObservableProperty]
    private string _selectedSummaryText = Strings.T("尚未扫描");

    [ObservableProperty]
    private string _visibleCountText = "";

    [ObservableProperty]
    private bool _hasVisibleRules = true;

    public string ScanButtonText => HasScanned ? Strings.T("重新扫描") : Strings.T("开始扫描");

    public string CleanButtonText => Strings.M($"清理选中({Rules.Count(r => r.IsSelected)})");

    partial void OnSearchTextChanged(string value) => RefreshGroups();

    partial void OnSelectedRiskFilterChanged(RiskFilterOption value) => RefreshGroups();

    partial void OnSelectedSortOptionChanged(SortOption value) => RefreshGroups();

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

    /// <summary>本次清理移入隔离区、可还原的条目数。</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasQuarantineEntries))]
    [NotifyPropertyChangedFor(nameof(RestoreQuarantineText))]
    private int _quarantineCount;

    public bool HasQuarantineEntries => QuarantineCount > 0;

    public string RestoreQuarantineText => Strings.M($"还原本次隔离的 {QuarantineCount} 项");

    /// <summary>清理报告中是否存在可登记“重启后删除”的失败项。</summary>
    public bool HasPendingRebootDeletes => PendingRebootCount > 0;

    public bool CanScheduleRebootDelete => PendingRebootCount > 0 && IsElevated && _rebootDeletes.IsSupported;

    public string ScheduleRebootDeleteText => Strings.M($"安排重启后删除({PendingRebootCount})");

    /// <summary>「本次释放 / 累计释放」摘要;历史为空且本次未清理时为占位文案。</summary>
    [ObservableProperty]
    private string _historySummaryText = Strings.T("暂无清理历史");

    /// <summary>最近的清理记录(新的在前)。</summary>
    public ObservableCollection<HistoryItemViewModel> HistoryItems { get; } = [];

    /// <summary>本会话内清理释放的累计字节数(重启应用后归零;累计值看历史)。</summary>
    private long _sessionFreedBytes;

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
            StatusText = error ?? Strings.T("提权重启失败。");
            return;
        }

        RestartRequested?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void ShowClean() => IsCleanPage = true;

    [RelayCommand]
    private void ShowSettings()
    {
        if (IsBusy)
        {
            return;
        }

        IsCleanPage = false;
        _ = RefreshQuarantineUsageAsync();
    }

    /// <summary>勾选当前筛选后可见的全部规则。</summary>
    [RelayCommand]
    private void SelectAllVisible() => SetVisibleSelection(true);

    /// <summary>取消勾选当前筛选后可见的规则。</summary>
    [RelayCommand]
    private void SelectNoneVisible() => SetVisibleSelection(false);

    /// <summary>只勾选安全项(推荐的清理范围)。</summary>
    [RelayCommand]
    private void SelectSafeOnly()
    {
        _suspendSelectionPersist = true;
        try
        {
            foreach (var rule in Rules)
            {
                rule.IsSelected = rule.IsSafe && MatchesFilter(rule);
            }
        }
        finally
        {
            _suspendSelectionPersist = false;
        }

        UpdateSummary();
        PersistSelection();
    }

    private void SetVisibleSelection(bool selected)
    {
        _suspendSelectionPersist = true;
        try
        {
            foreach (var rule in Rules)
            {
                if (MatchesFilter(rule))
                {
                    rule.IsSelected = selected;
                }
            }
        }
        finally
        {
            _suspendSelectionPersist = false;
        }

        UpdateSummary();
        PersistSelection();
    }

    /// <summary>把文件加入排除名单:持久化,并立即从当前扫描结果与界面中移除。</summary>
    private void ExcludeFile(string path)
    {
        if (IsBusy)
        {
            StatusText = Strings.T("请等待当前操作完成后再排除文件。");
            return;
        }

        string? saveError = null;
        if (!Settings.ExcludedFiles.Contains(path, PathComparer))
        {
            Settings.ExcludedFiles.Add(path);
            SettingsEditor.AppendExcludedFile(path);
            try
            {
                _settingsService.Save(Settings);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                saveError = ex.Message;
            }
        }

        RemoveFileFromScan(path);

        StatusText = saveError is null
            ? Strings.M($"已排除:{path}(可在设置页恢复)")
            : Strings.M($"已排除:{path},但设置保存失败:{saveError}(可在设置页恢复)");
    }

    /// <summary>把文件所在目录加入全局排除名单:持久化,并立即从当前扫描结果中移除该目录下的所有文件。</summary>
    private void ExcludeDirectory(string directory)
    {
        if (IsBusy)
        {
            StatusText = Strings.T("请等待当前操作完成后再排除文件夹。");
            return;
        }

        var normalized = directory.TrimEnd('\\', '/');
        if (normalized.Length == 0)
        {
            StatusText = Strings.T("无法排除该文件所在的目录。");
            return;
        }

        string? saveError = null;
        if (!Settings.ExcludedPaths.Contains(normalized, PathComparer))
        {
            Settings.ExcludedPaths.Add(normalized);
            SettingsEditor.AppendExcludedPath(normalized);
            try
            {
                _settingsService.Save(Settings);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                saveError = ex.Message;
            }
        }

        RemoveDirectoryFromScan(normalized);

        StatusText = saveError is null
            ? Strings.M($"已排除目录:{normalized}(可在设置页恢复)")
            : Strings.M($"已排除目录:{normalized},但设置保存失败:{saveError}(可在设置页恢复)");
    }

    /// <summary>在资源管理器中定位文件。</summary>
    private void RevealFile(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            StatusText = Strings.T("当前平台暂不支持打开文件位置。");
            return;
        }

        if (!WindowsShell.TryRevealInExplorer(path, out var error))
        {
            StatusText = Strings.M($"无法打开文件位置:{error}");
        }
    }

    /// <summary>从当前扫描数据与规则明细中移除已排除的文件(同一路径可能同时命中多条规则)。</summary>
    private void RemoveFileFromScan(string path) => RemoveFromScan(file => PathComparer.Equals(file, path));

    /// <summary>目录排除按目录段边界匹配,与扫描器的前缀排除一致(避免 C:\Temp 误伤 C:\Temp2)。</summary>
    private void RemoveDirectoryFromScan(string directory) =>
        RemoveFromScan(file => file.Length > directory.Length
            && PathComparer.Equals(file[..directory.Length], directory)
            && (file[directory.Length] == '\\' || file[directory.Length] == '/'));

    private void RemoveFromScan(Func<string, bool> shouldRemove)
    {
        if (_lastScan is null)
        {
            return;
        }

        foreach (var result in _lastScan)
        {
            var removed = result.Files.RemoveAll(f => shouldRemove(f.Path));
            if (removed == 0)
            {
                continue;
            }

            result.TotalBytes = result.Files.Sum(f => f.Size);
            result.ItemCount = result.Files.Count;

            var rule = Rules.FirstOrDefault(r => r.Rule == result.Rule);
            if (rule is not null)
            {
                rule.SizeBytes = result.TotalBytes;
                rule.StatusText = result.ItemCount == 0
                    ? Strings.T("没有可清理的内容")
                    : Strings.M($"{result.ItemCount:N0} 个文件");
                rule.RefreshFiles();
            }
        }

        UpdateSummary();
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
        var copies = 0;
        var failures = new List<DeleteFailure>();

        // 登记重启后删除后原文件会消失:隔离区开启时先复制一份副本(移动会与登记冲突)
        var session = Settings.QuarantineEnabled ? _lastQuarantineSession ??= _quarantine.CreateSession() : null;
        foreach (var item in _pendingRebootDeletes)
        {
            if (session is not null)
            {
                if (session.TryCopyForPendingReboot(item.Path, out var copyError))
                {
                    copies++;
                }
                else
                {
                    failures.Add(new DeleteFailure(item.Path, Strings.M($"未能复制到隔离区:{copyError}")));
                    continue;
                }
            }

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
            StatusText = copies > 0
                ? Strings.M($"已安排 {scheduled} 项重启后删除,隔离区已保留副本,重启后生效。")
                : Strings.M($"已安排 {scheduled} 项重启后删除,重启后生效。");
        }
        else if (scheduled == 0)
        {
            StatusText = failures[0].Reason.StartsWith(Strings.T("未能复制到隔离区"))
                ? Strings.M($"未能安排重启后删除:{failures[0].Reason}")
                : Strings.T("安排重启后删除失败,请确认已以管理员身份运行。");
        }
        else
        {
            StatusText = Strings.M($"已安排 {scheduled} 项,{failures.Count} 项安排失败。");
        }

        if (scheduled > 0)
        {
            var copyNote = copies > 0 ? Strings.M($",隔离区已保留 {copies} 份副本") : "";
            ReportText = Strings.M($"{ReportText}{Environment.NewLine}✔ 已安排 {scheduled} 项重启后删除(重启后生效,重启前文件仍占用空间{copyNote})。");
        }
    }

    /// <summary>把本次清理移入隔离区的文件移回原位置(原位置已有同名文件时跳过并给出原因)。</summary>
    [RelayCommand]
    private async Task RestoreQuarantineAsync()
    {
        if (IsBusy || _lastQuarantineSession is not { } session || QuarantineCount == 0)
        {
            return;
        }

        IsBusy = true;
        IsProgressVisible = true;
        ProgressValue = 0;
        var cts = new CancellationTokenSource();
        _cts = cts;
        var restored = 0;
        var failures = new List<DeleteFailure>();
        var cancelled = false;
        try
        {
            var total = Math.Max(1, session.RestorableCount);
            var progress = new Progress<int>(done =>
            {
                ProgressValue = done * 100.0 / total;
                StatusText = Strings.M($"正在还原:{done}/{total}");
            });

            (restored, failures, cancelled) = await Task.Run(() => RestoreEntries(session, progress, cts.Token));
        }
        finally
        {
            _cts = null;
            cts.Dispose();
            IsBusy = false;
            IsProgressVisible = false;
        }

        QuarantineCount = session.RestorableCount;
        if (cancelled)
        {
            StatusText = Strings.M($"已取消还原,已还原 {restored} 项。");
            return;
        }

        var sb = new StringBuilder();
        if (restored > 0)
        {
            sb.AppendLine(Strings.M($"✔ 已还原 {restored} 项到原位置(可重新扫描以刷新列表)。"));
        }

        foreach (var failure in failures.Take(5))
        {
            sb.AppendLine(Strings.M($"    ✗ 未还原 {failure.Path}({failure.Reason})"));
        }

        if (failures.Count > 5)
        {
            sb.AppendLine(Strings.M($"    …其余 {failures.Count - 5} 项未还原"));
        }

        if (sb.Length > 0)
        {
            ReportText = $"{ReportText}{Environment.NewLine}{sb.ToString().TrimEnd()}";
        }

        StatusText = failures.Count == 0
            ? Strings.M($"已还原 {restored} 项到原位置,可重新扫描以刷新列表。")
            : Strings.M($"已还原 {restored} 项,{failures.Count} 项失败:{failures[0].Reason}");
    }

    private static (int Restored, List<DeleteFailure> Failures, bool Cancelled) RestoreEntries(
        QuarantineSession session,
        IProgress<int> progress,
        CancellationToken ct)
    {
        var restored = 0;
        var failures = new List<DeleteFailure>();
        foreach (var entry in session.RestorableEntries.ToList())
        {
            if (ct.IsCancellationRequested)
            {
                return (restored, failures, true);
            }

            if (session.TryRestore(entry, out var error))
            {
                restored++;
            }
            else
            {
                failures.Add(new DeleteFailure(entry.OriginalPath, error));
            }

            progress.Report(restored + failures.Count);
        }

        return (restored, failures, false);
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
            StatusText = Strings.T("没有勾选可清理的内容 —— 请先扫描并选择要清理的项目。");
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
            // 还原点创建在工作流内部完成;失败(未提权 / 系统保护未开启)只提示,不阻塞清理
            if (Settings.CreateRestorePointBeforeClean)
            {
                StatusText = Strings.T("正在创建系统还原点…");
            }

            var request = new CleanupRequest { Settings = Settings, PermanentDelete = PermanentDelete, IsElevated = IsElevated };
            var progress = new Progress<CleanProgress>(p =>
            {
                ProgressValue = p.RuleCount == 0 ? 0 : p.RuleIndex * 100.0 / p.RuleCount;
                StatusText = p.Detail.Length > 0
                    ? Strings.M($"正在清理:{p.RuleName} — {p.Detail}")
                    : Strings.M($"正在清理:{p.RuleName}");
            });

            var outcome = await _workflow.CleanAsync(selected, request, progress, cts.Token);
            _lastQuarantineSession = outcome.QuarantineSession;
            ReportText = BuildReport(outcome);
            SetPendingRebootDeletes(outcome.Report);
            QuarantineCount = _lastQuarantineSession?.RestorableCount ?? 0;
            RecordCleanup(outcome.Report, CleanupHistoryEntry.SourceManual);
            cancelled = outcome.Report.WasCancelled;
            StatusText = cancelled ? Strings.T("已取消清理,报告中为已完成的部分。") : Strings.T("清理完成。");
        }
        catch (OperationCanceledException)
        {
            cancelled = true;
            StatusText = Strings.T("已取消清理。");
        }
        catch (Exception ex)
        {
            StatusText = Strings.M($"清理失败:{ex.Message}");
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
                rule.StatusText = Strings.T("扫描中…");
                rule.HasFailures = false;
            }

            var progress = new Progress<ScanProgress>(p =>
            {
                ProgressValue = p.RuleCount == 0 ? 0 : p.RuleIndex * 100.0 / p.RuleCount;
                StatusText = p.CurrentPath.Length > 0
                    ? Strings.M($"正在扫描:{p.RuleName} — {p.CurrentPath}")
                    : Strings.M($"正在扫描:{p.RuleName}");
            });

            var results = await _workflow.ScanAsync(Rules.Select(r => r.Rule).ToList(), Settings, progress, cts.Token);
            _lastScan = results;
            ApplyScanResults(results);

            HasScanned = true;
            ProgressValue = 100;
            StatusText = Strings.T("扫描完成。");
        }
        catch (OperationCanceledException)
        {
            // 丢弃半成品结果,恢复上一次完整结果(若有)
            StatusText = _lastScan is null ? Strings.T("已取消扫描。") : Strings.T("已取消扫描,保留上一次的扫描结果。");
            if (_lastScan is not null)
            {
                ApplyScanResults(_lastScan);
            }
            else
            {
                foreach (var rule in Rules)
                {
                    rule.StatusText = Strings.T("尚未扫描");
                }
            }
        }
        catch (Exception ex)
        {
            StatusText = Strings.M($"扫描失败:{ex.Message}");
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
            rule.StatusText = rule.Rule.Kind == RuleKind.Action
                ? Strings.T("执行时生效(释放量在清理后统计)")
                : result.ItemCount == 0
                    ? Strings.T("没有可清理的内容")
                    : Strings.M($"{result.ItemCount:N0} 个文件");
            rule.AttachScanResult(result);
        }

        UpdateSummary();
        RefreshGroups();
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
        var excludesChanged = !Settings.ExcludedPaths.SequenceEqual(settings.ExcludedPaths)
            || !Settings.ExcludedFiles.SequenceEqual(settings.ExcludedFiles);
        var filterChanged = Settings.SkipRecentDays != settings.SkipRecentDays;
        var retentionChanged = Settings.QuarantineRetentionDays != settings.QuarantineRetentionDays;

        Settings = settings;
        PermanentDelete = settings.DefaultPermanentDelete;

        if (retentionChanged)
        {
            PurgeExpiredQuarantine(settings.QuarantineRetentionDays);
        }

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

        if (ruleSetChanged || excludesChanged || filterChanged)
        {
            ResetScanState();
            StatusText = saveError is null
                ? Strings.T("设置已保存,请重新扫描。")
                : Strings.M($"设置保存失败:{saveError}(本次会话内仍生效)。");
        }
        else
        {
            StatusText = saveError is null ? Strings.T("设置已保存。") : Strings.M($"设置保存失败:{saveError}");
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
            rule.StatusText = Strings.T("尚未扫描");
            rule.AttachScanResult(null);
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

    /// <summary>最近一次完整扫描结果,供「导出明细」使用。</summary>
    public IReadOnlyList<RuleScanResult> LastScanResults => _lastScan ?? [];

    private List<RuleScanResult> GetSelectedResults()
    {
        if (_lastScan is null)
        {
            return [];
        }

        var selectedRules = Rules.Where(r => r.IsSelected).Select(r => r.Rule).ToHashSet();
        return _lastScan.Where(r => selectedRules.Contains(r.Rule)).ToList();
    }

    /// <summary>把一次清理计入历史,并刷新「本次释放 / 累计释放」与趋势列表;写历史失败不影响清理结果。</summary>
    private void RecordCleanup(CleanupReport report, string source)
    {
        _sessionFreedBytes += report.TotalBytesRemoved;
        try
        {
            _historyService.Append(CleanupHistoryEntry.FromReport(report, source));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }

        RefreshHistory();
    }

    /// <summary>重新读取清理历史(启动时、清理后与外部自动清理完成后调用)。</summary>
    public void RefreshHistory()
    {
        var entries = _historyService.Load();
        HistoryItems.Clear();
        foreach (var entry in entries.AsEnumerable().Reverse().Take(6))
        {
            HistoryItems.Add(new HistoryItemViewModel(entry));
        }

        var totalBytes = entries.Sum(e => e.BytesRemoved);
        var parts = new List<string>();
        if (_sessionFreedBytes > 0)
        {
            parts.Add(Strings.M($"本次释放 {Formatting.FormatBytes(_sessionFreedBytes)}"));
        }

        if (entries.Count > 0)
        {
            parts.Add(Strings.M($"累计释放 {Formatting.FormatBytes(totalBytes)}"));
            parts.Add(Strings.M($"共 {entries.Count:N0} 次清理"));
        }

        HistorySummaryText = parts.Count == 0 ? Strings.T("暂无清理历史") : string.Join(" · ", parts);
    }

    /// <summary>界面之外(自动清理 / 托盘“立即清理”)完成清理后同步历史与状态栏。</summary>
    public void NotifyExternalClean(string summary, CleanupReport? report, string source)
    {
        if (report is not null)
        {
            RecordCleanup(report, source);
        }
        else
        {
            RefreshHistory();
        }

        StatusText = summary;
    }

    private string BuildReport(CleanupOutcome outcome)
    {
        var report = outcome.Report;
        var deleter = outcome.Deleter;
        var notes = new List<string>();

        if (outcome.RestorePointNote is not null)
        {
            notes.Add(outcome.RestorePointNote);
        }

        if (report.WasCancelled)
        {
            notes.Add(Strings.T("清理已取消,以上为已完成的部分。"));
        }

        if (deleter is WindowsRecycleBinDeleter)
        {
            notes.Add(Strings.T("提示:移入回收站的文件仍占用磁盘空间,清空回收站后才会真正释放。"));
        }

        if (deleter is QuarantineFileDeleter quarantineDeleter && quarantineDeleter.Session.RestorableCount > 0)
        {
            notes.Add(Settings.QuarantineRetentionDays > 0
                ? Strings.M($"提示:隔离区中的文件仍占用磁盘空间,保留 {Settings.QuarantineRetentionDays} 天后自动删除;期间可在下方“还原”。")
                : Strings.T("提示:隔离区中的文件仍占用磁盘空间,会一直保留直到手动清空;期间可在下方“还原”。"));
        }

        if (Settings.SecureErasePasses > 0)
        {
            notes.Add(deleter switch
            {
                WindowsRecycleBinDeleter => Strings.T("提示:回收站删除不经过安全擦除;覆写只作用于永久删除与隔离区清理。"),
                QuarantineFileDeleter => Strings.M($"提示:安全擦除在隔离区清理时生效(覆写 {Settings.SecureErasePasses} 次后删除);移入隔离区本身不覆写。"),
                _ => Strings.M($"提示:本次删除前已覆写 {Settings.SecureErasePasses} 次;对 SSD / NVMe 与写时复制文件系统效果有限。"),
            });
        }

        if (outcome.Warning is not null)
        {
            notes.Add(outcome.Warning);
        }

        var footer = !IsElevated && report.Results.Any(r => r.Rule.RequiresAdmin && r.Failures.Count > 0)
            ? Strings.T("部分失败可通过提权重试 —— 点击右上角“以管理员身份重启”。")
            : null;

        return ReportTextBuilder.Build(
            report,
            Strings.M($"{deleter.Name}:清理 {report.TotalDeleted:N0} 项,共 {Formatting.FormatBytes(report.TotalBytesRemoved)}。"),
            notes,
            footer);
    }

    private void UpdateSummary()
    {
        var selectedCount = Rules.Count(r => r.IsSelected);
        var selectedBytes = Rules.Where(r => r.IsSelected).Sum(r => r.SizeBytes);
        SelectedSummaryText = HasScanned
            ? Strings.M($"已勾选 {selectedCount} 项 · 预计释放 {Formatting.FormatBytes(selectedBytes)}")
            : Strings.T("尚未扫描 —— 点击“开始扫描”分析可清理的内容");

        foreach (var group in RuleGroups)
        {
            group.Refresh();
        }

        OnPropertyChanged(nameof(TotalSizeText));
        OnPropertyChanged(nameof(CleanButtonText));
    }

    /// <summary>按当前搜索与风险筛选重建分组,排序也在这里应用。</summary>
    private void RefreshGroups()
    {
        var visible = Rules.Where(MatchesFilter).ToList();
        var ordered = SelectedSortOption.Value switch
        {
            RuleSort.SizeDescending => visible.OrderByDescending(r => r.SizeBytes),
            RuleSort.SizeAscending => visible.OrderBy(r => r.SizeBytes),
            _ => visible.OrderBy(r => r.DisplayName),
        };

        RuleGroups.Clear();
        foreach (var group in ordered.GroupBy(r => r.Rule.Category).OrderBy(g => CategoryRank(g.Key)))
        {
            RuleGroups.Add(new RuleGroupViewModel(group.Key, group.ToList()));
        }

        HasVisibleRules = visible.Count > 0;
        VisibleCountText = visible.Count == Rules.Count
            ? Strings.M($"共 {Rules.Count} 项")
            : Strings.M($"显示 {visible.Count} / {Rules.Count} 项");
    }

    private bool MatchesFilter(RuleViewModel rule)
    {
        if (SelectedRiskFilter.Level is { } risk && rule.Rule.Risk != risk)
        {
            return false;
        }

        var query = SearchText.Trim();
        if (query.Length == 0)
        {
            return true;
        }

        return rule.DisplayName.Contains(query, StringComparison.OrdinalIgnoreCase)
            || rule.Description.Contains(query, StringComparison.OrdinalIgnoreCase)
            || rule.Rule.Category.Contains(query, StringComparison.OrdinalIgnoreCase);
    }

    private static int CategoryRank(string category)
    {
        var index = Array.IndexOf(CategoryOrder, category);
        return index < 0 ? CategoryOrder.Length : index;
    }

    /// <summary>分组在界面上的先后顺序;不在名单里的类别排到最后。</summary>
    private static readonly string[] CategoryOrder =
    [
        Strings.T("系统临时与日志"), Strings.T("系统缓存"), Strings.T("使用痕迹"), Strings.T("浏览器缓存"), Strings.T("浏览器隐私"), Strings.T("应用缓存"), Strings.T("开发者缓存"), Strings.T("自定义目录"), Strings.T("回收站"), Strings.T("系统备份"), Strings.T("其他"),
    ];

    /// <summary>从当前设置重建设置页状态(放弃未保存的更改)。</summary>
    private void ResetSettingsEditor()
    {
        if (SettingsEditor is not null)
        {
            SettingsEditor.CloseRequested -= OnSettingsEditorCloseRequested;
        }

        SettingsEditor = new SettingsViewModel(Settings, PurgeQuarantine, OpenQuarantine);
        SettingsEditor.CloseRequested += OnSettingsEditorCloseRequested;
    }

    private void OnSettingsEditorCloseRequested(BroomSettings? settings)
    {
        if (settings is null)
        {
            ResetSettingsEditor();
            StatusText = Strings.T("已放弃未保存的设置更改。");
            return;
        }

        var notice = SettingsEditor.SaveNotice;
        ApplySettings(settings);
        if (notice.Length > 0)
        {
            StatusText = $"{StatusText}{notice}";
        }

        ResetSettingsEditor();
        IsCleanPage = true;
    }

    /// <summary>启动与保存设置时清理过期隔离内容;失败不影响应用运行。</summary>
    private void PurgeExpiredQuarantine(int retentionDays) =>
        Task.Run(() => _quarantine.PurgeExpired(retentionDays, Settings.SecureErasePasses));

    private string PurgeQuarantine()
    {
        if (!_quarantine.TryPurgeAll(out var items, out var bytes, out var error, Settings.SecureErasePasses))
        {
            return Strings.M($"清空隔离区未完成:{error}");
        }

        return items == 0
            ? Strings.T("隔离区本来就是空的。")
            : Strings.M($"已清空隔离区:{items:N0} 项 · {Formatting.FormatBytes(bytes)}。");
    }

    private string OpenQuarantine()
    {
        try
        {
            Directory.CreateDirectory(_quarantine.RootPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Strings.M($"无法创建隔离区目录:{ex.Message}");
        }

        if (!OperatingSystem.IsWindows())
        {
            return Strings.M($"当前平台暂不支持打开文件夹,隔离区位于:{_quarantine.RootPath}");
        }

        return WindowsShell.TryRevealInExplorer(_quarantine.RootPath, out var error)
            ? Strings.M($"已打开隔离区:{_quarantine.RootPath}")
            : Strings.M($"无法打开隔离区:{error}");
    }

    /// <summary>进入设置页时后台统计隔离区用量,避免大目录阻塞界面。</summary>
    private async Task RefreshQuarantineUsageAsync()
    {
        var editor = SettingsEditor;
        var (items, bytes) = await Task.Run(_quarantine.GetUsage);
        if (!ReferenceEquals(editor, SettingsEditor))
        {
            return;
        }

        editor.QuarantineStatusText = items == 0
            ? Strings.T("隔离区当前为空。")
            : Strings.M($"隔离区当前:{items:N0} 项 · {Formatting.FormatBytes(bytes)}。");
    }

    private void RebuildRules()
    {
        Rules.Clear();
        var saved = Settings.SelectedRuleIds;
        _suspendSelectionPersist = true;
        try
        {
            foreach (var rule in CreateRules())
            {
                var viewModel = new RuleViewModel(rule, ExcludeFile, ExcludeDirectory, RevealFile)
                {
                    IsSelected = ResolveSelection(saved, rule),
                };
                viewModel.PropertyChanged += OnRuleChanged;
                Rules.Add(viewModel);
            }
        }
        finally
        {
            _suspendSelectionPersist = false;
        }

        RefreshGroups();
    }

    /// <summary>勾选状态的恢复语义:从未保存过(null)回到规则默认,否则按保存的 Id 集合恢复。</summary>
    internal static bool ResolveSelection(IReadOnlyList<string>? savedIds, CleanupRule rule)
        => savedIds is null ? rule.Recommended : savedIds.Contains(rule.Id, StringComparer.OrdinalIgnoreCase);

    private void OnRuleChanged(object? sender, PropertyChangedEventArgs e)
    {
        UpdateSummary();
        if (e.PropertyName == nameof(RuleViewModel.IsSelected) && !_suspendSelectionPersist)
        {
            PersistSelection();
        }
    }

    /// <summary>
    /// 记住勾选:只更新当前规则集内的 Id,隐藏(如高风险)或暂未加载的 Id 保留原状态,
    /// 之后重新显示时仍按用户上次的选择恢复。
    /// </summary>
    private void PersistSelection()
    {
        var currentIds = Rules.Select(r => r.Rule.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var updated = Settings.SelectedRuleIds is { } saved
            ? saved.Where(id => !currentIds.Contains(id)).ToList()
            : [];
        updated.AddRange(Rules.Where(r => r.IsSelected).Select(r => r.Rule.Id));
        Settings.SelectedRuleIds = updated;

        try
        {
            _settingsService.Save(Settings);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 勾选记忆是便利功能:保存失败不影响本次会话的选择
        }
    }

    private IReadOnlyList<CleanupRule> CreateRules() => CleanupWorkflow.CreateRules(Settings);
}
