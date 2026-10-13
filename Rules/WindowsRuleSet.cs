using broom.Core;

namespace broom.Rules;

/// <summary>
/// Windows 首批清理规则集(安全项 A 级 + 谨慎项 B 级)。
/// 规则是纯数据:将来支持 macOS / Linux 时,只需提供新的规则集,扫描与删除引擎不用改动。
/// </summary>
public static class WindowsRuleSet
{
    private const string DevHint = "下次构建或安装依赖时需要重新下载 / 重新编译。";

    private static readonly CleanupRule[] BuiltInRules =
    [
        // ── A 级:可放心清理 ───────────────────────────────
        new CleanupRule
        {
            Id = "user-temp",
            Category = "系统临时与日志",
            DisplayName = "用户临时文件",
            Description = "当前用户的临时目录,程序正在使用的文件会自动跳过。",
            Paths = [@"%TEMP%"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "system-temp",
            Category = "系统临时与日志",
            DisplayName = "系统临时文件",
            Description = @"C:\Windows\Temp 中的临时文件。",
            Paths = [@"%SystemRoot%\Temp"],
            RequiresAdmin = true,
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "user-crash-dumps",
            Category = "系统临时与日志",
            DisplayName = "应用崩溃转储",
            Description = "程序崩溃时生成的转储文件,仅用于事后诊断。",
            Paths = [@"%LOCALAPPDATA%\CrashDumps"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "system-crash-dumps",
            Category = "系统临时与日志",
            DisplayName = "系统内存转储",
            Description = "系统蓝屏转储与内存转储文件,通常体积很大。",
            Paths = [@"%SystemRoot%\Minidump", @"%SystemRoot%\MEMORY.DMP"],
            RequiresAdmin = true,
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "user-wer",
            Category = "系统临时与日志",
            DisplayName = "Windows 错误报告(用户)",
            Description = "应用程序错误报告归档。",
            Paths = [@"%LOCALAPPDATA%\Microsoft\Windows\WER"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "system-wer",
            Category = "系统临时与日志",
            DisplayName = "Windows 错误报告(系统)",
            Description = "系统级错误报告归档,与用户级互相独立。",
            Paths = [@"%ProgramData%\Microsoft\Windows\WER"],
            RequiresAdmin = true,
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "inet-cache",
            Category = "系统缓存",
            DisplayName = "Internet 临时文件",
            Description = "系统 Internet 临时文件缓存。",
            Paths = [@"%LOCALAPPDATA%\Microsoft\Windows\INetCache"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "thumbnail-cache",
            Category = "系统缓存",
            DisplayName = "缩略图与图标缓存",
            Description = "资源管理器缩略图与图标缓存,删除后会自动重建。",
            Paths = [@"%LOCALAPPDATA%\Microsoft\Windows\Explorer"],
            IncludePatterns = ["thumbcache_*.db", "iconcache_*.db"],
            Recommended = true,
        },

        // ── B 级:需谨慎,默认不勾选 ────────────────────────
        new CleanupRule
        {
            Id = "windows-update-cache",
            Category = "系统缓存",
            DisplayName = "Windows 更新下载缓存",
            Description = "已下载的更新安装包缓存,删除后更新时可能需要重新下载。",
            Paths = [@"%SystemRoot%\SoftwareDistribution\Download"],
            Risk = RiskLevel.Caution,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "recycle-bin",
            Category = "回收站",
            DisplayName = "回收站",
            Description = "清空回收站,清空后其中的文件将无法恢复。",
            Kind = RuleKind.RecycleBin,
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "browser-cache",
            Category = "浏览器缓存",
            DisplayName = "浏览器网页缓存",
            Description = "Chrome / Edge / Firefox 的网页缓存,不涉及密码、Cookie 与书签。",
            Paths =
            [
                @"%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache",
                @"%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache",
                @"%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache",
                @"%LOCALAPPDATA%\Google\Chrome\User Data\*\ShaderCache",
                @"%LOCALAPPDATA%\Google\Chrome\User Data\*\GrShaderCache",
                @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache",
                @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache",
                @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache",
                @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\ShaderCache",
                @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GrShaderCache",
                @"%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2",
            ],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "windows-old",
            Category = "系统备份",
            DisplayName = "旧系统备份与升级残留",
            Description = "Windows.old 等升级残留,删除后无法回滚到升级前的系统。",
            Paths = [@"%SystemDrive%\Windows.old", @"%SystemDrive%\$WINDOWS.~BT", @"%SystemDrive%\$WINDOWS.~WS"],
            Risk = RiskLevel.High,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "windows-logs",
            Category = "系统临时与日志",
            DisplayName = "Windows 组件日志",
            Description = "更新与组件安装过程产生的日志文件。",
            Paths =
            [
                @"%SystemRoot%\Logs\CBS",
                @"%SystemRoot%\Logs\DISM",
                @"%SystemRoot%\Logs\SIH",
                @"%SystemRoot%\Logs\WindowsUpdate",
            ],
            Risk = RiskLevel.Caution,
            RequiresAdmin = true,
        },

        // ── 开发者缓存:可重建,但代价是重新下载 ────────────
        new CleanupRule
        {
            Id = "dev-nuget",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · NuGet",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.nuget\packages"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-npm",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · npm",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\npm-cache"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-pip",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · pip",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\pip\Cache"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-yarn",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Yarn",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\Yarn\Cache"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-pnpm",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · pnpm",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\pnpm\store"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-gradle",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Gradle",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.gradle\caches"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-maven",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Maven",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.m2\repository"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-go",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Go 构建缓存",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\go-build"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-cargo",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Cargo",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.cargo\registry\cache"],
            Risk = RiskLevel.Caution,
        },
    ];

    /// <summary>内置规则 + 用户自定义规则(设置页维护)。</summary>
    public static IReadOnlyList<CleanupRule> Create(BroomSettings? settings = null)
    {
        if (settings is null || settings.CustomRules.Count == 0)
        {
            return BuiltInRules;
        }

        var rules = new List<CleanupRule>(BuiltInRules);
        foreach (var custom in settings.CustomRules)
        {
            rules.Add(ToCleanupRule(custom));
        }

        return rules;
    }

    private static CleanupRule ToCleanupRule(CustomRule custom) => new()
    {
        Id = $"custom-{custom.Path}",
        Category = "自定义目录",
        DisplayName = string.IsNullOrWhiteSpace(custom.Name) ? $"自定义:{custom.Path}" : custom.Name,
        Description = "来自设置的自定义目录。",
        Paths = [custom.Path],
        IncludePatterns = custom.IncludePatterns.Count > 0 ? [.. custom.IncludePatterns] : ["*"],
        ExcludePatterns = [.. custom.ExcludePatterns],
        Risk = custom.Risk,
        Recommended = custom.Recommended,
    };
}
