using broom.Core;
using broom.Platform;

using broom.Localization;
namespace broom.Services;

/// <summary>自动 / 托盘触发的清理。</summary>
public enum AutoCleanTrigger
{
    /// <summary>按排期自动执行。</summary>
    Scheduled,

    /// <summary>托盘菜单「立即清理」。</summary>
    Manual,
}

/// <summary>一次自动清理的结果。</summary>
public sealed record AutoCleanResult(bool Success, string Summary, CleanupReport? Report, string Source);

/// <summary>
/// 自动清理的执行:范围可预期(仅安全项或上次勾选),一律走回收站(不永久删除),
/// 结果写入清理历史并给出摘要;由 <see cref="AutoCleanScheduler"/> 或托盘菜单触发。
/// </summary>
public sealed class AutoCleanService
{
    private readonly CleanupWorkflow _workflow;
    private readonly SettingsService _settingsService;
    private readonly CleanupHistoryService _historyService;
    private int _running;

    public AutoCleanService(
        CleanupWorkflow? workflow = null,
        SettingsService? settingsService = null,
        CleanupHistoryService? historyService = null)
    {
        _workflow = workflow ?? new CleanupWorkflow();
        _settingsService = settingsService ?? new SettingsService();
        _historyService = historyService ?? new CleanupHistoryService();
    }

    public bool IsRunning => Volatile.Read(ref _running) == 1;

    /// <summary>
    /// 按范围挑选规则(纯函数):仅安全项只取 <see cref="RiskLevel.Safe"/>;
    /// 上次勾选按持久化的勾选集合,从未保存过时回到规则默认勾选(与界面恢复语义一致)。
    /// </summary>
    public static List<CleanupRule> SelectRules(IEnumerable<CleanupRule> rules, AutoCleanScope scope, IReadOnlyList<string>? selectedRuleIds)
        => scope switch
        {
            AutoCleanScope.SafeOnly => rules.Where(r => r.Risk == RiskLevel.Safe).ToList(),
            AutoCleanScope.SelectedRules => rules.Where(r => ResolveSelection(selectedRuleIds, r)).ToList(),
            _ => [],
        };

    private static bool ResolveSelection(IReadOnlyList<string>? savedIds, CleanupRule rule)
        => savedIds is null
            ? rule.Recommended
            : savedIds.Contains(rule.Id, StringComparer.OrdinalIgnoreCase);

    public async Task<AutoCleanResult> RunAsync(AutoCleanTrigger trigger, CancellationToken ct = default)
    {
        var source = trigger == AutoCleanTrigger.Scheduled
            ? CleanupHistoryEntry.SourceScheduled
            : CleanupHistoryEntry.SourceManual;

        if (Interlocked.Exchange(ref _running, 1) == 1)
        {
            return new AutoCleanResult(false, Strings.T("已有清理正在进行,本次跳过。"), null, source);
        }

        try
        {
            var settings = _settingsService.Load();
            // 与界面一致:隐藏的高风险类目不进自动清理;范围过滤交给 SelectRules
            var rules = SelectRules(CleanupWorkflow.CreateRules(settings), settings.AutoCleanScope, settings.SelectedRuleIds);
            if (rules.Count == 0)
            {
                return new AutoCleanResult(true, Strings.T("自动清理:当前范围没有可清理的规则。"), null, source);
            }

            var scan = await _workflow.ScanAsync(rules, settings, null, ct);
            if (scan.Sum(r => r.ItemCount) == 0 && scan.All(r => r.Rule.Kind == RuleKind.Paths))
            {
                return new AutoCleanResult(true, Strings.T("自动清理:没有需要清理的内容。"), null, source);
            }

            // 自动删除必须可预期:一律走回收站,不因“默认永久删除”设置而销毁文件
            var request = new CleanupRequest
            {
                Settings = settings,
                PermanentDelete = false,
                IsElevated = PlatformServices.CreateElevationService().IsElevated,
            };
            var outcome = await _workflow.CleanAsync(scan, request, null, ct);
            var report = outcome.Report;

            try
            {
                _historyService.Append(CleanupHistoryEntry.FromReport(report, source));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 历史是统计功能:写入失败不影响清理结果
            }

            var summary = report.TotalDeleted == 0 && report.TotalBytesRemoved == 0
                ? Strings.T("自动清理完成:没有需要清理的内容。")
                : Strings.M($"自动清理完成:清理 {report.TotalDeleted:N0} 项 · 释放 {Formatting.FormatBytes(report.TotalBytesRemoved)}")
                  + (report.TotalFailures > 0 ? Strings.M($"({report.TotalFailures:N0} 项失败)") : "");
            return new AutoCleanResult(true, summary, report, source);
        }
        catch (OperationCanceledException)
        {
            return new AutoCleanResult(false, Strings.T("自动清理已取消。"), null, source);
        }
        catch (Exception ex)
        {
            return new AutoCleanResult(false, Strings.M($"自动清理失败:{ex.Message}"), null, source);
        }
        finally
        {
            Interlocked.Exchange(ref _running, 0);
        }
    }
}
