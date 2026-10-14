namespace broom.Core;

/// <summary>
/// 一次清理的历史记录,追加写入 %APPDATA%\broom\history.json;
/// 用于「本次释放 / 累计释放」统计与趋势列表。
/// </summary>
public sealed class CleanupHistoryEntry
{
    /// <summary>清理发生的时间(UTC)。</summary>
    public DateTime TimestampUtc { get; init; }

    /// <summary>触发来源:manual(界面手动)/ scheduled(自动清理)/ cli(命令行)。</summary>
    public string Source { get; init; } = SourceManual;

    public int ItemCount { get; init; }

    public long BytesRemoved { get; init; }

    public int FailureCount { get; init; }

    /// <summary>是否被取消(记录的是已完成部分的效果)。</summary>
    public bool WasCancelled { get; init; }

    /// <summary>逐条规则的清理量;动作型规则只记条目数与摘要所代表的量。</summary>
    public List<CleanupHistoryRule> Rules { get; init; } = [];

    public const string SourceManual = "manual";
    public const string SourceScheduled = "scheduled";
    public const string SourceCli = "cli";

    /// <summary>从一次清理报告生成历史记录(只记有实际效果的规则)。</summary>
    public static CleanupHistoryEntry FromReport(CleanupReport report, string source) => new()
    {
        TimestampUtc = DateTime.UtcNow,
        Source = source,
        ItemCount = report.TotalDeleted,
        BytesRemoved = report.TotalBytesRemoved,
        FailureCount = report.TotalFailures,
        WasCancelled = report.WasCancelled,
        Rules = report.Results
            .Where(r => r.DeletedCount > 0 || r.BytesRemoved > 0)
            .Select(r => new CleanupHistoryRule
            {
                RuleId = r.Rule.Id,
                RuleName = r.Rule.DisplayName,
                Items = r.DeletedCount,
                Bytes = r.BytesRemoved,
            })
            .ToList(),
    };
}

/// <summary>历史记录里单条规则的清理量。</summary>
public sealed class CleanupHistoryRule
{
    public string RuleId { get; init; } = "";

    public string RuleName { get; init; } = "";

    public int Items { get; init; }

    public long Bytes { get; init; }
}
