using System.Text;
using broom.Core;
using broom.Platform;
using broom.Services;

using broom.Localization;
namespace broom.Cli;

/// <summary>
/// 无人值守执行:命令行模式的扫描 / 清理,输出到标准输出与可选报告文件,返回约定退出码。
/// 与 GUI 共用 <see cref="CleanupWorkflow"/>,排除、时间过滤、隔离区、还原点等行为保持一致。
/// </summary>
public static class CliRunner
{
    /// <summary>成功。</summary>
    public const int ExitOk = 0;

    /// <summary>运行错误或清理存在失败项。</summary>
    public const int ExitRuntimeError = 1;

    /// <summary>参数错误(未知参数、缺动作、--report 缺路径等)。</summary>
    public const int ExitUsage = 2;

    /// <summary>未确认(确认提示被拒绝)或被取消(Ctrl+C)。</summary>
    public const int ExitCancelled = 3;

    public static int Run(string[] args, TextWriter output, TextWriter error, Func<string, bool>? confirm = null, CancellationToken ct = default)
        => RunAsync(args, output, error, confirm, ct).GetAwaiter().GetResult();

    public static async Task<int> RunAsync(string[] args, TextWriter output, TextWriter error, Func<string, bool>? confirm = null, CancellationToken ct = default)
    {
        var parsed = CommandLineParser.Parse(args);
        if (parsed.Options is null)
        {
            if (parsed.ShowHelp && parsed.Error is null)
            {
                output.WriteLine(CommandLineParser.Usage);
                return ExitOk;
            }

            error.WriteLine(parsed.Error);
            error.WriteLine();
            error.WriteLine(CommandLineParser.Usage);
            return ExitUsage;
        }

        return await ExecuteAsync(parsed.Options, output, error, confirm ?? ConsoleConfirm, ct);
    }

    private static async Task<int> ExecuteAsync(CliOptions options, TextWriter output, TextWriter error, Func<string, bool> confirm, CancellationToken ct)
    {
        var settings = new SettingsService().Load();
        var workflow = new CleanupWorkflow();
        var history = new CleanupHistoryService();
        var isElevated = PlatformServices.CreateElevationService().IsElevated;

        // 扫描看全量;清理按范围收窄:--clean safe 仅安全项,--clean all 含谨慎与高风险项
        var rules = CleanupWorkflow.CreateRules(settings, includeHighRisk: options.Action == CliAction.Scan || options.Scope == CliScope.All);
        if (options.Action == CliAction.Clean && options.Scope == CliScope.Safe)
        {
            rules = rules.Where(r => r.Risk == RiskLevel.Safe).ToList();
        }

        var scopeText = options.Action == CliAction.Scan
            ? Strings.T("全部规则(只读)")
            : options.Scope == CliScope.Safe ? Strings.T("仅安全项") : Strings.T("全部规则(含高风险)");
        output.WriteLine(Strings.M($"broom 命令行 · {DateTime.Now:yyyy-MM-dd HH:mm} · {rules.Count} 条规则 · {scopeText}"));

        IReadOnlyList<RuleScanResult> scan;
        try
        {
            var progress = new Progress<ScanProgress>(p =>
            {
                if (p.CurrentPath.Length == 0)
                {
                    output.WriteLine(Strings.M($"[{p.RuleIndex + 1}/{p.RuleCount}] 扫描 {p.RuleName}"));
                }
            });
            scan = await workflow.ScanAsync(rules, settings, progress, ct);
        }
        catch (OperationCanceledException)
        {
            error.WriteLine(Strings.T("已取消。"));
            return ExitCancelled;
        }
        catch (Exception ex)
        {
            error.WriteLine(Strings.M($"扫描失败:{ex.Message}"));
            return ExitRuntimeError;
        }

        if (options.Action == CliAction.Scan || options.DryRun)
        {
            var scanReport = BuildScanReport(scan);
            output.WriteLine(scanReport);
            return WriteReportFile(options.ReportPath, scanReport, error) ? ExitRuntimeError : ExitOk;
        }

        var totalItems = scan.Sum(r => r.ItemCount);
        var totalBytes = scan.Sum(r => r.TotalBytes);
        var hasActions = scan.Any(r => r.Rule.Kind == RuleKind.Action);
        if (!options.AssumeYes)
        {
            var question = Strings.M($"即将清理 {totalItems:N0} 项 · {Formatting.FormatBytes(totalBytes)}{(hasActions ? Strings.T(",含动作型规则(不可逆)") : "")},是否继续?");
            if (!confirm(question))
            {
                error.WriteLine(Strings.T("已取消:未确认清理(无人值守请加 --yes)。"));
                return ExitCancelled;
            }
        }

        CleanupOutcome outcome;
        try
        {
            var request = new CleanupRequest { Settings = settings, PermanentDelete = settings.DefaultPermanentDelete, IsElevated = isElevated };
            var progress = new Progress<CleanProgress>(p => output.WriteLine(Strings.M($"[{p.RuleIndex + 1}/{p.RuleCount}] 清理 {p.RuleName}")));
            outcome = await workflow.CleanAsync(scan, request, progress, ct);
        }
        catch (OperationCanceledException)
        {
            error.WriteLine(Strings.T("已取消。"));
            return ExitCancelled;
        }
        catch (Exception ex)
        {
            error.WriteLine(Strings.M($"清理失败:{ex.Message}"));
            return ExitRuntimeError;
        }

        var report = outcome.Report;
        try
        {
            history.Append(CleanupHistoryEntry.FromReport(report, CleanupHistoryEntry.SourceCli));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            error.WriteLine(Strings.M($"清理历史写入失败:{ex.Message}(不影响本次清理结果)"));
        }

        var notes = new List<string>();
        if (outcome.RestorePointNote is not null)
        {
            notes.Add(outcome.RestorePointNote);
        }

        if (report.WasCancelled)
        {
            notes.Add(Strings.T("清理已取消,以上为已完成的部分。"));
        }

        if (outcome.Warning is not null)
        {
            notes.Add(outcome.Warning);
        }

        var cleanReport = ReportTextBuilder.Build(
            report,
            Strings.M($"清理完成:删除 {report.TotalDeleted:N0} 项,共 {Formatting.FormatBytes(report.TotalBytesRemoved)}。"),
            notes);
        output.WriteLine(cleanReport);

        if (WriteReportFile(options.ReportPath, cleanReport, error))
        {
            return ExitRuntimeError;
        }

        return report.WasCancelled
            ? ExitCancelled
            : report.TotalFailures > 0 ? ExitRuntimeError : ExitOk;
    }

    private static string BuildScanReport(IReadOnlyList<RuleScanResult> scan)
    {
        var sb = new StringBuilder();
        sb.AppendLine(Strings.M($"broom 扫描报告 · {DateTime.Now:yyyy-MM-dd HH:mm} · 只读,未删除任何文件"));
        foreach (var result in scan)
        {
            if (result.ItemCount > 0)
            {
                sb.AppendLine(Strings.M($"· {result.Rule.DisplayName}:{result.ItemCount:N0} 项 · {Formatting.FormatBytes(result.TotalBytes)}"));
            }
        }

        var actions = scan.Where(r => r.Rule.Kind == RuleKind.Action).ToList();
        if (actions.Count > 0)
        {
            sb.AppendLine(Strings.M($"· 动作型规则 {actions.Count} 条:{string.Join("、", actions.Select(r => r.Rule.DisplayName))}(执行时生效,不计大小)"));
        }

        foreach (var result in scan.Where(r => r.Errors.Count > 0))
        {
            sb.AppendLine(Strings.M($"    ✗ {result.Rule.DisplayName}:{result.Errors.Count} 处无法访问"));
        }

        sb.AppendLine(Strings.M($"合计:可清理 {scan.Sum(r => r.ItemCount):N0} 项 · {Formatting.FormatBytes(scan.Sum(r => r.TotalBytes))}({scan.Count} 条规则)"));
        return sb.ToString().TrimEnd();
    }

    /// <summary>把报告另存为文本文件;返回是否写入失败。</summary>
    private static bool WriteReportFile(string? path, string text, TextWriter error)
    {
        if (path is null)
        {
            return false;
        }

        try
        {
            var fullPath = Path.GetFullPath(path);
            var directory = Path.GetDirectoryName(fullPath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(fullPath, text + Environment.NewLine, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
            return false;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            error.WriteLine(Strings.M($"报告写入失败:{ex.Message}"));
            return true;
        }
    }

    private static bool ConsoleConfirm(string question)
    {
        Console.Error.Write($"{question} [y/N] ");
        var line = Console.In.ReadLine();
        return line is not null && line.Trim().Equals("y", StringComparison.OrdinalIgnoreCase);
    }
}
