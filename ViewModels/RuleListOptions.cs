using broom.Core;

namespace broom.ViewModels;

/// <summary>风险等级筛选项,<see cref="Level"/> 为 null 表示不过滤。</summary>
public sealed record RiskFilterOption(RiskLevel? Level, string Label);

/// <summary>规则排序方式。</summary>
public enum RuleSort
{
    /// <summary>按占用空间从大到小。</summary>
    SizeDescending,

    /// <summary>按占用空间从小到大。</summary>
    SizeAscending,

    /// <summary>按显示名称。</summary>
    Name,
}

/// <summary>排序选项。</summary>
public sealed record SortOption(RuleSort Value, string Label);
