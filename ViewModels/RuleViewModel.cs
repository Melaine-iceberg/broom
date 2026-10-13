using broom.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace broom.ViewModels;

/// <summary>单条清理规则在界面上的状态。</summary>
public partial class RuleViewModel : ObservableObject
{
    public RuleViewModel(CleanupRule rule)
    {
        Rule = rule;
        IsSelected = rule.Recommended;
    }

    public CleanupRule Rule { get; }

    [ObservableProperty]
    private bool _isSelected;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SizeText))]
    private long _sizeBytes;

    [ObservableProperty]
    private string _statusText = "尚未扫描";

    [ObservableProperty]
    private bool _hasFailures;

    public string DisplayName => Rule.DisplayName;

    public string Description => Rule.Description;

    public bool RequiresAdmin => Rule.RequiresAdmin;

    public bool IsSafe => Rule.Risk == RiskLevel.Safe;

    public bool IsCaution => Rule.Risk == RiskLevel.Caution;

    public bool IsHigh => Rule.Risk == RiskLevel.High;

    public string RiskText => Rule.Risk switch
    {
        RiskLevel.Safe => "安全",
        RiskLevel.Caution => "谨慎",
        _ => "高风险",
    };

    public string SizeText => Formatting.FormatBytes(SizeBytes);
}
