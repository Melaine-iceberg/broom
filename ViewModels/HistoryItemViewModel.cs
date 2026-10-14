using broom.Core;

using broom.Localization;
namespace broom.ViewModels;

/// <summary>清理历史条目:时间、释放量与来源的展示模型。</summary>
public sealed class HistoryItemViewModel
{
    public HistoryItemViewModel(CleanupHistoryEntry entry)
    {
        TimeText = entry.TimestampUtc.ToLocalTime().ToString("MM-dd HH:mm");
        SizeText = Formatting.FormatBytes(entry.BytesRemoved);
        SourceText = entry.Source switch
        {
            CleanupHistoryEntry.SourceScheduled => Strings.T("自动清理"),
            CleanupHistoryEntry.SourceCli => Strings.T("命令行"),
            _ => Strings.T("手动清理"),
        };

        var detail = Strings.M($"{entry.ItemCount:N0} 项 · {SourceText}");
        if (entry.WasCancelled)
        {
            detail += Strings.T(" · 已取消");
        }

        if (entry.FailureCount > 0)
        {
            detail += Strings.M($" · {entry.FailureCount:N0} 项失败");
        }

        DetailText = detail;
    }

    public string TimeText { get; }

    public string SizeText { get; }

    public string SourceText { get; }

    public string DetailText { get; }
}
