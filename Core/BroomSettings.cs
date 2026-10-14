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
internal sealed partial class BroomJsonContext : JsonSerializerContext
{
}
