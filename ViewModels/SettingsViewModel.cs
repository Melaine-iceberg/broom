using System.Collections.ObjectModel;
using broom.Core;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace broom.ViewModels;

/// <summary>设置页状态:自定义目录、全局排除路径与其他默认选项。</summary>
public partial class SettingsViewModel : ObservableObject
{
    private readonly Func<string> _purgeQuarantine;
    private readonly Func<string> _openQuarantine;
    private readonly List<string>? _selectedRuleIds;

    public SettingsViewModel(BroomSettings settings, Func<string> purgeQuarantine, Func<string> openQuarantine)
    {
        _purgeQuarantine = purgeQuarantine;
        _openQuarantine = openQuarantine;
        _selectedRuleIds = settings.SelectedRuleIds;
        CustomRules = new ObservableCollection<CustomRuleViewModel>(
            settings.CustomRules.Select(rule => CreateRule(rule)));
        ExcludedPathsText = string.Join(Environment.NewLine, settings.ExcludedPaths);
        ExcludedFilesText = string.Join(Environment.NewLine, settings.ExcludedFiles);
        DefaultPermanentDelete = settings.DefaultPermanentDelete;
        ShowHighRiskRules = settings.ShowHighRiskRules;
        QuarantineEnabled = settings.QuarantineEnabled;
        SelectedQuarantineRetention = QuarantineRetentionOptions.FirstOrDefault(o => o.Days == settings.QuarantineRetentionDays)
            ?? QuarantineRetentionOptions[0];
        SelectedSkipRecent = SkipRecentOptions.FirstOrDefault(o => o.Days == settings.SkipRecentDays)
            ?? SkipRecentOptions[0];
        SelectedSecureErase = SecureEraseOptions.FirstOrDefault(o => o.Passes == settings.SecureErasePasses)
            ?? SecureEraseOptions[0];
        CreateRestorePointBeforeClean = settings.CreateRestorePointBeforeClean;
        RemoveEmptyDirectories = settings.RemoveEmptyDirectories;
    }

    /// <summary>保存结果已就绪时触发(参数为 null 表示取消),窗口据此关闭。</summary>
    public event Action<BroomSettings?>? CloseRequested;

    public ObservableCollection<CustomRuleViewModel> CustomRules { get; }

    [ObservableProperty]
    private string _excludedPathsText;

    [ObservableProperty]
    private string _excludedFilesText;

    [ObservableProperty]
    private bool _defaultPermanentDelete;

    [ObservableProperty]
    private bool _showHighRiskRules;

    /// <summary>隔离区保留天数选项(0 表示永久保留)。</summary>
    public IReadOnlyList<RetentionOption> QuarantineRetentionOptions { get; } =
    [
        new(7, "7 天"),
        new(1, "1 天"),
        new(3, "3 天"),
        new(14, "14 天"),
        new(30, "30 天"),
        new(0, "永久保留"),
    ];

    /// <summary>「跳过最近修改的文件」天数选项(0 表示不启用)。</summary>
    public IReadOnlyList<DayOption> SkipRecentOptions { get; } =
    [
        new(0, "不启用"),
        new(1, "1 天"),
        new(3, "3 天"),
        new(7, "7 天"),
        new(14, "14 天"),
        new(30, "30 天"),
    ];

    [ObservableProperty]
    private DayOption _selectedSkipRecent;

    /// <summary>安全擦除的覆写次数选项(0 表示不覆写)。</summary>
    public IReadOnlyList<SecureEraseOption> SecureEraseOptions { get; } =
    [
        new(0, "不覆写"),
        new(1, "覆写 1 次"),
        new(3, "覆写 3 次"),
    ];

    [ObservableProperty]
    private SecureEraseOption _selectedSecureErase;

    [ObservableProperty]
    private bool _createRestorePointBeforeClean;

    [ObservableProperty]
    private bool _removeEmptyDirectories;

    [ObservableProperty]
    private bool _quarantineEnabled;

    [ObservableProperty]
    private RetentionOption _selectedQuarantineRetention;

    /// <summary>隔离区操作(打开 / 清空 / 当前用量)的结果文案。</summary>
    [ObservableProperty]
    private string _quarantineStatusText = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PurgeQuarantineText))]
    private bool _purgeConfirmed;

    public string PurgeQuarantineText => PurgeConfirmed ? "确认清空(不可恢复)" : "清空隔离区";

    [RelayCommand]
    private void OpenQuarantine() => QuarantineStatusText = _openQuarantine();

    /// <summary>两步确认,避免误点把隔离区里的恢复副本一并删掉。</summary>
    [RelayCommand]
    private void PurgeQuarantine()
    {
        if (!PurgeConfirmed)
        {
            PurgeConfirmed = true;
            QuarantineStatusText = "再次点击确认清空 —— 该操作不可恢复。";
            return;
        }

        PurgeConfirmed = false;
        QuarantineStatusText = _purgeQuarantine();
    }

    [ObservableProperty]
    private string _errorText = "";

    /// <summary>保存时的非错误提示(如合并了重复排除项),由主窗口并入状态栏。</summary>
    public string SaveNotice { get; private set; } = "";

    [RelayCommand]
    private void AddCustomRule() => CustomRules.Add(CreateRule(new CustomRule()));

    [RelayCommand]
    private void Save()
    {
        // 重复行合并后回写文本框,规范化结果直接可见
        var (paths, mergedPaths) = Dedupe(ParseLines(ExcludedPathsText));
        var (files, mergedFiles) = Dedupe(ParseLines(ExcludedFilesText));
        ExcludedPathsText = string.Join(Environment.NewLine, paths);
        ExcludedFilesText = string.Join(Environment.NewLine, files);

        if (!TryBuild(out var settings, out var error))
        {
            ErrorText = error;
            SaveNotice = "";
            return;
        }

        var merged = mergedPaths + mergedFiles;
        SaveNotice = merged == 0 ? "" : $"本次合并了 {merged} 个重复排除项。";
        ErrorText = "";
        CloseRequested?.Invoke(settings);
    }

    [RelayCommand]
    private void Cancel() => CloseRequested?.Invoke(null);

    public bool TryBuild(out BroomSettings settings, out string error)
    {
        var rules = new List<CustomRule>(CustomRules.Count);
        foreach (var item in CustomRules)
        {
            var rule = item.ToModel();
            if (rule.Path.Length == 0)
            {
                settings = new BroomSettings();
                error = "每个自定义目录都需要填写路径。";
                return false;
            }

            rules.Add(rule);
        }

        var (excludedPaths, _) = Dedupe(ParseLines(ExcludedPathsText));
        var (excludedFiles, _) = Dedupe(ParseLines(ExcludedFilesText));
        var invalid = excludedPaths.Concat(excludedFiles).Where(line => !IsValidExclusion(line)).ToList();
        if (invalid.Count > 0)
        {
            settings = new BroomSettings();
            var shown = string.Join("、", invalid.Take(3));
            error = invalid.Count > 3
                ? $"排除项必须是绝对路径或包含 %环境变量%:{shown} 等 {invalid.Count} 项。"
                : $"排除项必须是绝对路径或包含 %环境变量%:{shown}。";
            return false;
        }

        settings = new BroomSettings
        {
            CustomRules = rules,
            ExcludedPaths = excludedPaths,
            ExcludedFiles = excludedFiles,
            DefaultPermanentDelete = DefaultPermanentDelete,
            ShowHighRiskRules = ShowHighRiskRules,
            QuarantineEnabled = QuarantineEnabled,
            QuarantineRetentionDays = SelectedQuarantineRetention.Days,
            SkipRecentDays = SelectedSkipRecent.Days,
            SecureErasePasses = SelectedSecureErase.Passes,
            CreateRestorePointBeforeClean = CreateRestorePointBeforeClean,
            SelectedRuleIds = _selectedRuleIds,
            RemoveEmptyDirectories = RemoveEmptyDirectories,
        };
        error = "";
        return true;
    }

    /// <summary>清理页排除文件后同步文本框,避免稍后保存设置时覆盖掉该排除项。</summary>
    public void AppendExcludedFile(string path)
    {
        var text = ExcludedFilesText.TrimEnd();
        ExcludedFilesText = text.Length == 0 ? path : $"{text}{Environment.NewLine}{path}";
    }

    /// <summary>清理页排除目录后同步文本框,避免稍后保存设置时覆盖掉该排除项。</summary>
    public void AppendExcludedPath(string path)
    {
        var text = ExcludedPathsText.TrimEnd();
        ExcludedPathsText = text.Length == 0 ? path : $"{text}{Environment.NewLine}{path}";
    }

    private CustomRuleViewModel CreateRule(CustomRule rule) => new(rule, RemoveCustomRule);

    private void RemoveCustomRule(CustomRuleViewModel rule) => CustomRules.Remove(rule);

    private static List<string> ParseLines(string text) =>
        text.Split(['\r', '\n', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

    /// <summary>路径去重,比较方式与扫描器一致(Windows 不区分大小写);返回去重结果与合并数量。</summary>
    private static (List<string> Items, int Duplicates) Dedupe(List<string> lines)
    {
        var items = new List<string>(lines.Count);
        foreach (var line in lines)
        {
            if (!items.Contains(line, PathComparer))
            {
                items.Add(line);
            }
        }

        return (items, lines.Count - items.Count);
    }

    /// <summary>排除项校验:必须是绝对路径或包含 %环境变量%,避免拼错的相对路径"保存成功却永远匹配不上"。</summary>
    private static bool IsValidExclusion(string line) => Path.IsPathFullyQualified(line) || line.Contains('%');

    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;
}

/// <summary>隔离区保留天数下拉项。</summary>
public sealed record RetentionOption(int Days, string Label);

/// <summary>「跳过最近修改的文件」天数下拉项。</summary>
public sealed record DayOption(int Days, string Label);

/// <summary>安全擦除的覆写次数下拉项。</summary>
public sealed record SecureEraseOption(int Passes, string Label);
