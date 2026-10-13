using broom.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace broom.ViewModels;

/// <summary>界面上的一个规则分组(例如"开发者缓存"),含分组小计与分组级勾选。</summary>
public class RuleGroupViewModel : ObservableObject
{
    public RuleGroupViewModel(string title, IReadOnlyList<RuleViewModel> items)
    {
        Title = title;
        Items = items;
        UpdateTotals();
    }

    public string Title { get; }

    /// <summary>该分组当前可见的规则(已按筛选条件过滤)。</summary>
    public IReadOnlyList<RuleViewModel> Items { get; }

    /// <summary>分组小计,例如 "3.2 GB"。</summary>
    public string SizeText { get; private set; } = "";

    /// <summary>分组内的规则条数,例如 "9 项"。</summary>
    public string CountText { get; private set; } = "";

    /// <summary>分组内所有规则是否都已勾选(复选框绑定用)。</summary>
    public bool IsSelected
    {
        get => Items.Count > 0 && Items.All(item => item.IsSelected);
        set
        {
            foreach (var item in Items)
            {
                item.IsSelected = value;
            }
        }
    }

    /// <summary>规则勾选状态变化后由外部调用,刷新小计与勾选态显示。</summary>
    public void Refresh()
    {
        UpdateTotals();
        OnPropertyChanged(new System.ComponentModel.PropertyChangedEventArgs(nameof(IsSelected)));
    }

    private void UpdateTotals()
    {
        SizeText = Formatting.FormatBytes(Items.Sum(item => item.SizeBytes));
        CountText = $"{Items.Count} 项";
    }
}
