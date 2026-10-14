using broom.Core;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using broom.Localization;
namespace broom.ViewModels;

/// <summary>设置页中的一条自定义目录。</summary>
public partial class CustomRuleViewModel : ObservableObject
{
    private readonly Action<CustomRuleViewModel> _remove;

    public CustomRuleViewModel(CustomRule rule, Action<CustomRuleViewModel> remove)
    {
        _remove = remove;
        Name = rule.Name;
        Path = rule.Path;
        IncludePatternsText = string.Join(", ", rule.IncludePatterns);
        ExcludePatternsText = string.Join(", ", rule.ExcludePatterns);
        SelectedRisk = RiskOptions.FirstOrDefault(option => option.Level == rule.Risk) ?? RiskOptions[1];
        Recommended = rule.Recommended;
        RemoveCommand = new RelayCommand(() => _remove(this));
    }

    public IReadOnlyList<RiskOption> RiskOptions { get; } =
    [
        new(RiskLevel.Safe, Strings.T("安全")),
        new(RiskLevel.Caution, Strings.T("谨慎")),
        new(RiskLevel.High, Strings.T("高风险")),
    ];

    public IRelayCommand RemoveCommand { get; }

    [ObservableProperty]
    private string _name;

    [ObservableProperty]
    private string _path;

    [ObservableProperty]
    private string _includePatternsText;

    [ObservableProperty]
    private string _excludePatternsText;

    [ObservableProperty]
    private RiskOption _selectedRisk;

    [ObservableProperty]
    private bool _recommended;

    public CustomRule ToModel() => new()
    {
        Name = Name.Trim(),
        Path = Path.Trim(),
        IncludePatterns = ParsePatterns(IncludePatternsText),
        ExcludePatterns = ParsePatterns(ExcludePatternsText),
        Risk = SelectedRisk.Level,
        Recommended = Recommended,
    };

    private static List<string> ParsePatterns(string text) =>
        text.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
}

/// <summary>风险等级下拉项。</summary>
public sealed record RiskOption(RiskLevel Level, string Label);
