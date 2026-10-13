using System.Collections.ObjectModel;
using broom.Core;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace broom.ViewModels;

/// <summary>设置页状态:自定义目录、全局排除路径与其他默认选项。</summary>
public partial class SettingsViewModel : ObservableObject
{
    public SettingsViewModel(BroomSettings settings)
    {
        CustomRules = new ObservableCollection<CustomRuleViewModel>(
            settings.CustomRules.Select(rule => CreateRule(rule)));
        ExcludedPathsText = string.Join(Environment.NewLine, settings.ExcludedPaths);
        DefaultPermanentDelete = settings.DefaultPermanentDelete;
        ShowHighRiskRules = settings.ShowHighRiskRules;
    }

    /// <summary>保存结果已就绪时触发(参数为 null 表示取消),窗口据此关闭。</summary>
    public event Action<BroomSettings?>? CloseRequested;

    public ObservableCollection<CustomRuleViewModel> CustomRules { get; }

    [ObservableProperty]
    private string _excludedPathsText;

    [ObservableProperty]
    private bool _defaultPermanentDelete;

    [ObservableProperty]
    private bool _showHighRiskRules;

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
            DefaultPermanentDelete = DefaultPermanentDelete,
            ShowHighRiskRules = ShowHighRiskRules,
        };
        error = "";
        return true;
    }

    private CustomRuleViewModel CreateRule(CustomRule rule) => new(rule, RemoveCustomRule);

    private void RemoveCustomRule(CustomRuleViewModel rule) => CustomRules.Remove(rule);

    private static List<string> ParseLines(string text) =>
        text.Split(['\r', '\n', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
}
