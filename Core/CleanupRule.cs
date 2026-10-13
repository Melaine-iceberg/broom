namespace broom.Core;

/// <summary>清理项的风险等级,决定 UI 上的提示与默认勾选策略。</summary>
public enum RiskLevel
{
    /// <summary>可以放心删除,删除代价几乎为零。</summary>
    Safe,

    /// <summary>删除后需要重建或重新下载,可能影响使用体验。</summary>
    Caution,

    /// <summary>删除后不可逆或影响系统回滚能力。</summary>
    High,
}

/// <summary>规则的执行方式。</summary>
public enum RuleKind
{
    /// <summary>扫描路径,逐个删除匹配的文件。</summary>
    Paths,

    /// <summary>清空回收站,通过 Shell API 完成,不逐个删除文件。</summary>
    RecycleBin,
}

/// <summary>
/// 声明式清理规则:把"什么是垃圾"的知识做成数据,扫描/删除引擎与平台无关。
/// 将来支持 macOS / Linux 时,只需要提供一组新的规则数据。
/// </summary>
public sealed record CleanupRule
{
    /// <summary>稳定标识,例如 "user-temp"。</summary>
    public required string Id { get; init; }

    /// <summary>显示名称,例如 "用户临时文件"。</summary>
    public required string DisplayName { get; init; }

    /// <summary>界面分组用的类别,例如 "系统临时与日志"。</summary>
    public string Category { get; init; } = "其他";

    /// <summary>面向用户的说明,包含删除后果提示。</summary>
    public string Description { get; init; } = "";

    public RuleKind Kind { get; init; } = RuleKind.Paths;

    /// <summary>路径模板,支持 %ENV% 环境变量与目录名通配符(仅在目录段生效)。</summary>
    public string[] Paths { get; init; } = [];

    /// <summary>文件名包含模式;["*"] 表示目录下的全部内容。</summary>
    public string[] IncludePatterns { get; init; } = ["*"];

    /// <summary>文件名排除模式,优先于包含模式。</summary>
    public string[] ExcludePatterns { get; init; } = [];

    public RiskLevel Risk { get; init; } = RiskLevel.Safe;

    /// <summary>删除该规则的目标通常需要管理员权限。</summary>
    public bool RequiresAdmin { get; init; }

    /// <summary>是否默认勾选(只对安全项置 true)。</summary>
    public bool Recommended { get; init; }

    /// <summary>适用平台标识,例如 "windows"。</summary>
    public string Platform { get; init; } = "windows";

    /// <summary>该规则是否等价于"清空整个目录内容"。</summary>
    public bool IsWholeDirectory => IncludePatterns.Length == 1 && IncludePatterns[0] == "*";
}
