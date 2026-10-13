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
