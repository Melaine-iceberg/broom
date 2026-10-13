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

    public SettingsViewModel(BroomSettings settings, Func<string> purgeQuarantine, Func<string> openQuarantine)
    {
        _purgeQuarantine = purgeQuarantine;
        _openQuarantine = openQuarantine;
        CustomRules = new ObservableCollection<CustomRuleViewModel>(
            settings.CustomRules.Select(rule => CreateRule(rule)));
        ExcludedPathsText = string.Join(Environment.NewLine, settings.ExcludedPaths);
        ExcludedFilesText = string.Join(Environment.NewLine, settings.ExcludedFiles);
        DefaultPermanentDelete = settings.DefaultPermanentDelete;
        ShowHighRiskRules = settings.ShowHighRiskRules;
        QuarantineEnabled = settings.QuarantineEnabled;
        SelectedQuarantineRetention = QuarantineRetentionOptions.FirstOrDefault(o => o.Days == settings.QuarantineRetentionDays)
            ?? QuarantineRetentionOptions[0];
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

    [RelayCommand]
    private void AddCustomRule() => CustomRules.Add(CreateRule(new CustomRule()));

    [RelayCommand]
    private void Save()
    {
        if (!TryBuild(out var settings, out var error))
        {
            ErrorText = error;
            return;
        }

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

        settings = new BroomSettings
        {
            CustomRules = rules,
            ExcludedPaths = ParseLines(ExcludedPathsText),
            ExcludedFiles = ParseLines(ExcludedFilesText),
            DefaultPermanentDelete = DefaultPermanentDelete,
            ShowHighRiskRules = ShowHighRiskRules,
            QuarantineEnabled = QuarantineEnabled,
            QuarantineRetentionDays = SelectedQuarantineRetention.Days,
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

    private CustomRuleViewModel CreateRule(CustomRule rule) => new(rule, RemoveCustomRule);

    private void RemoveCustomRule(CustomRuleViewModel rule) => CustomRules.Remove(rule);

    private static List<string> ParseLines(string text) =>
        text.Split(['\r', '\n', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
}

/// <summary>隔离区保留天数下拉项。</summary>
public sealed record RetentionOption(int Days, string Label);
