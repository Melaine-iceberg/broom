using System.Text;
using broom.Core;

using broom.Localization;
namespace broom.Services;

/// <summary>
/// 清理报告文本的共用骨架:摘要行 + 盘符前后对比 + 调用方注记 + 逐条规则明细 + 空目录回收 + 未执行规则 + 脚注。
/// GUI 报告卡片与命令行 --report 输出共用,避免两套格式漂移。
/// </summary>
public static class ReportTextBuilder
{
    /// <param name="summaryLine">首行摘要(删除器名称、条目数与总大小)。</param>
    /// <param name="notes">盘符对比与逐条规则之间的注记(还原点、平台降级、安全擦除提示等),按给定顺序输出。</param>
    /// <param name="footer">明细之后的脚注(如“可提权重试”提示)。</param>
    public static string Build(
        CleanupReport report,
        string summaryLine,
        IReadOnlyList<string>? notes = null,
        string? footer = null,
        int maxFailuresPerRule = 10)
    {
        var sb = new StringBuilder();
        sb.AppendLine(summaryLine);

        // 计入的字节数与磁盘实际释放可能不一致(回收站仍占用、覆写 / 稀疏等),用盘符前后对比说话
        foreach (var delta in report.DriveSpace)
        {
            var change = delta.FreedBytes >= 0
                ? Strings.M($"本次释放 +{Formatting.FormatBytes(delta.FreedBytes)}")
                : Strings.M($"可用不增反减 {Formatting.FormatBytes(-delta.FreedBytes)},可能受其他程序活动影响");
            sb.AppendLine(Strings.M($"· 磁盘 {delta.Drive.TrimEnd('\\', '/')} 可用空间:{Formatting.FormatBytes(delta.FreeBefore)} → {Formatting.FormatBytes(delta.FreeAfter)}({change})"));
        }

        if (notes is not null)
        {
            foreach (var note in notes)
            {
                if (note.Length > 0)
                {
                    sb.AppendLine(note);
                }
            }
        }

        foreach (var result in report.Results)
        {
            if (result.DeletedCount == 0 && result.Failures.Count == 0 && result.Summary.Length == 0)
            {
                continue;
            }

            // 动作型规则没有逐个删除的文件,用执行摘要代替计数
            var summary = result.Summary.Length > 0
                ? result.Summary
                : Strings.M($"{result.DeletedCount:N0} 项 / {Formatting.FormatBytes(result.BytesRemoved)}");
            sb.AppendLine($"· {result.Rule.DisplayName}:{summary}");
            foreach (var failure in result.Failures.Take(maxFailuresPerRule))
            {
                sb.AppendLine($"    ✗ {failure.Path}({failure.Reason})");
            }

            if (result.Failures.Count > maxFailuresPerRule)
            {
                sb.AppendLine(Strings.M($"    …其余 {result.Failures.Count - maxFailuresPerRule} 项失败未列出"));
            }
        }

        if (report.EmptyDirectoriesRemoved > 0)
        {
            sb.AppendLine(Strings.M($"· 另回收空目录 {report.EmptyDirectoriesRemoved:N0} 个。"));
        }

        if (report.SkippedRules.Count > 0)
        {
            sb.AppendLine(Strings.M($"· 未执行的规则:{string.Join("、", report.SkippedRules.Select(r => r.DisplayName))}"));
        }

        if (!string.IsNullOrEmpty(footer))
        {
            sb.AppendLine(footer);
        }

        return sb.ToString().TrimEnd();
    }
}
