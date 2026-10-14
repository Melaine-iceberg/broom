using broom.Localization;

namespace broom.Cli;

/// <summary>命令行要执行的动作。</summary>
public enum CliAction
{
    /// <summary>只扫描并输出可清理内容。</summary>
    Scan,

    Clean,
}

/// <summary>命令行清理的项目范围。</summary>
public enum CliScope
{
    /// <summary>仅安全项(默认);与界面「仅安全」语义一致。</summary>
    Safe,

    /// <summary>全部规则,含谨慎与高风险项(不可逆类目也会执行)。</summary>
    All,
}

/// <summary>解析后的命令行选项。</summary>
public sealed record CliOptions
{
    public required CliAction Action { get; init; }

    public CliScope Scope { get; init; } = CliScope.Safe;

    /// <summary>只输出报告不删除(可与 --clean 连用做预演)。</summary>
    public bool DryRun { get; init; }

    /// <summary>报告另存路径;留空只输出到标准输出。</summary>
    public string? ReportPath { get; init; }

    /// <summary>无人值守:跳过交互确认。</summary>
    public bool AssumeYes { get; init; }
}

/// <summary>解析结果:选项、错误与是否显示帮助。</summary>
public sealed record CliParseResult(CliOptions? Options, string? Error, bool ShowHelp)
{
    public static CliParseResult Help() => new(null, null, true);

    public static CliParseResult Fail(string error) => new(null, error, true);

    public static CliParseResult Ok(CliOptions options) => new(options, null, false);
}

/// <summary>命令行参数解析:无第三方依赖,未知参数一律报错(避免无人值守静默跑偏)。</summary>
public static class CommandLineParser
{
    /// <summary>用法说明(多行文案,用稳定键存放在资源里)。</summary>
    public static string Usage => Strings.T("cli.usage");

    private static readonly string[] CliFlags = ["--scan", "--clean", "--dry-run", "--report", "--yes", "--help", "-h", "/?"];

    /// <summary>判断参数是否要进入命令行模式(其余参数继续走 GUI 启动路径)。</summary>
    public static bool LooksLikeCliRequest(IReadOnlyList<string> args) =>
        args.Any(arg => CliFlags.Contains(arg, StringComparer.OrdinalIgnoreCase));

    public static CliParseResult Parse(IReadOnlyList<string> args)
    {
        CliAction? action = null;
        var scope = CliScope.Safe;
        var dryRun = false;
        string? reportPath = null;
        var assumeYes = false;

        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            switch (arg.ToLowerInvariant())
            {
                case "--help":
                case "-h":
                case "/?":
                    return CliParseResult.Help();
                case "--scan":
                    if (action is not null)
                    {
                        return CliParseResult.Fail(Strings.T("--scan 与 --clean 只能指定一个。"));
                    }

                    action = CliAction.Scan;
                    break;
                case "--clean":
                    if (action is not null)
                    {
                        return CliParseResult.Fail(Strings.T("--scan 与 --clean 只能指定一个。"));
                    }

                    action = CliAction.Clean;
                    if (i + 1 < args.Count && !args[i + 1].StartsWith('-'))
                    {
                        var value = args[++i];
                        if (value.Equals("safe", StringComparison.OrdinalIgnoreCase))
                        {
                            scope = CliScope.Safe;
                        }
                        else if (value.Equals("all", StringComparison.OrdinalIgnoreCase))
                        {
                            scope = CliScope.All;
                        }
                        else
                        {
                            return CliParseResult.Fail(Strings.M($"无法识别的清理范围:{value}(仅支持 safe 或 all)。"));
                        }
                    }

                    break;
                case "--dry-run":
                    dryRun = true;
                    break;
                case "--yes":
                    assumeYes = true;
                    break;
                case "--report":
                    if (i + 1 >= args.Count || args[i + 1].StartsWith('-'))
                    {
                        return CliParseResult.Fail(Strings.T("--report 需要指定报告文件路径。"));
                    }

                    reportPath = args[++i];
                    break;
                default:
                    return CliParseResult.Fail(Strings.M($"未知参数:{arg}"));
            }
        }

        if (action is null)
        {
            return CliParseResult.Fail(Strings.T("请指定 --scan 或 --clean。"));
        }

        return CliParseResult.Ok(new CliOptions
        {
            Action = action.Value,
            Scope = scope,
            DryRun = dryRun,
            ReportPath = reportPath,
            AssumeYes = assumeYes,
        });
    }
}
