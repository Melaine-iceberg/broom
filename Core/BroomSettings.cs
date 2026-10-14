using System.Text.Json.Serialization;

namespace broom.Core;

/// <summary>
/// 用户设置:自定义目录、全局排除路径与默认行为,持久化为 %APPDATA%\broom\settings.json。
/// </summary>
public sealed class BroomSettings
{
    /// <summary>自定义清理目录,启动时与内置规则合并。</summary>
    public List<CustomRule> CustomRules { get; set; } = [];

    /// <summary>全局排除路径:命中的文件在任何规则下都会被跳过。</summary>
    public List<string> ExcludedPaths { get; set; } = [];

    /// <summary>全局排除文件:命中的单个文件在任何规则下都会被跳过。</summary>
    public List<string> ExcludedFiles { get; set; } = [];

    /// <summary>工具栏“永久删除”的初始状态。</summary>
    public bool DefaultPermanentDelete { get; set; }

    /// <summary>是否显示高风险类目。</summary>
    public bool ShowHighRiskRules { get; set; } = true;

    /// <summary>永久删除时先移入隔离区(可还原),而不是直接删除。</summary>
    public bool QuarantineEnabled { get; set; } = true;

    /// <summary>隔离区的保留天数(0 表示永久保留);超过保留天数的内容自动清理。</summary>
    public int QuarantineRetentionDays { get; set; } = 7;

    /// <summary>跳过最近 N 天内修改过的文件(0 = 不启用);按最后写入时间判断,扫描与删除前都会校验。</summary>
    public int SkipRecentDays { get; set; }

    /// <summary>安全擦除:真正永久删除前的随机覆写次数(0 = 不覆写,可选 1 / 3)。</summary>
    public int SecureErasePasses { get; set; }

    /// <summary>清理前尝试创建 Windows 系统还原点(需要管理员权限与已开启的系统保护)。</summary>
    public bool CreateRestorePointBeforeClean { get; set; }

    /// <summary>上次勾选的规则 Id 集合;null 表示从未保存过,恢复规则默认勾选。</summary>
    public List<string>? SelectedRuleIds { get; set; }

    /// <summary>清理后移除扫描根下的空目录(默认关闭;可能删除用户有意保留的空目录结构)。</summary>
    public bool RemoveEmptyDirectories { get; set; }

    /// <summary>自动清理频率(Off = 关闭)。</summary>
    public AutoCleanFrequency AutoCleanFrequency { get; set; } = AutoCleanFrequency.Off;

    /// <summary>自动清理的执行时刻(本地时间,0–23 点)。</summary>
    public int AutoCleanHour { get; set; } = 2;

    /// <summary>每周自动清理的星期几(0 = 周日 … 6 = 周六),仅 <see cref="AutoCleanFrequency.Weekly"/> 生效。</summary>
    public int AutoCleanDayOfWeek { get; set; } = 1;

    /// <summary>每月自动清理的日期(1–28),仅 <see cref="AutoCleanFrequency.Monthly"/> 生效。</summary>
    public int AutoCleanDayOfMonth { get; set; } = 1;

    /// <summary>自动清理的范围:仅安全项(默认)或上次勾选的项目。</summary>
    public AutoCleanScope AutoCleanScope { get; set; } = AutoCleanScope.SafeOnly;

    /// <summary>关闭主窗口时最小化到托盘(保持后台定时清理与磁盘空间提醒);托盘菜单可真正退出。</summary>
    public bool CloseToTray { get; set; } = true;

    /// <summary>固定磁盘可用空间低于该阈值(GB)时提醒;0 = 不提醒。</summary>
    public int LowDiskThresholdGb { get; set; } = 20;
}

/// <summary>自动清理的执行频率。</summary>
public enum AutoCleanFrequency
{
    /// <summary>不自动清理。</summary>
    Off,

    Daily,

    Weekly,

    Monthly,
}

/// <summary>自动清理的项目范围。</summary>
public enum AutoCleanScope
{
    /// <summary>只清理风险等级为“安全”的规则(默认,自动删除可预期)。</summary>
    SafeOnly,

    /// <summary>清理上次勾选的规则(从未保存过勾选时按规则默认勾选)。</summary>
    SelectedRules,
}

/// <summary>用户自定义的清理目录。</summary>
public sealed class CustomRule
{
    /// <summary>显示名称;留空时用路径生成。</summary>
    public string Name { get; set; } = "";

    /// <summary>目录路径,支持 %ENV% 环境变量与目录级通配符。</summary>
    public string Path { get; set; } = "";

    /// <summary>文件名包含模式;留空表示目录下全部内容。</summary>
    public List<string> IncludePatterns { get; set; } = [];

    /// <summary>文件名排除模式。</summary>
    public List<string> ExcludePatterns { get; set; } = [];

    public RiskLevel Risk { get; set; } = RiskLevel.Caution;

    /// <summary>是否默认勾选。</summary>
    public bool Recommended { get; set; }
}

/// <summary>设置的 JSON 源生成上下文(裁剪 / AOT 友好)。</summary>
[JsonSourceGenerationOptions(
    WriteIndented = true,
    UseStringEnumConverter = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(BroomSettings))]
[JsonSerializable(typeof(List<CleanupHistoryEntry>))]
internal sealed partial class BroomJsonContext : JsonSerializerContext
{
}
