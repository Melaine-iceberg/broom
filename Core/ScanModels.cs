namespace broom.Core;

/// <summary>扫描发现的一个文件及其大小。</summary>
public readonly record struct ScannedFile(string Path, long Size);

/// <summary>单条规则的扫描结果。</summary>
public sealed class RuleScanResult
{
    public required CleanupRule Rule { get; init; }

    /// <summary>匹配到的文件(回收站规则为空,删除通过 Shell API 完成)。</summary>
    public List<ScannedFile> Files { get; } = [];

    /// <summary>实际展开并扫描的根目录,用于清理后的空目录回收。</summary>
    public List<string> Roots { get; } = [];

    /// <summary>无法访问的路径及原因,用于向用户解释"为什么没清干净"。</summary>
    public List<string> Errors { get; } = [];

    public long TotalBytes { get; set; }

    public int ItemCount { get; set; }
}

/// <summary>扫描进度:当前正在处理的规则与路径。</summary>
public sealed record ScanProgress(int RuleIndex, int RuleCount, string RuleName, string CurrentPath);

/// <summary>清理进度:当前正在处理的规则。</summary>
public sealed record CleanProgress(int RuleIndex, int RuleCount, string RuleName);

/// <summary>单个文件的删除失败记录。</summary>
public sealed record DeleteFailure(string Path, string Reason);

/// <summary>单条规则的清理结果。</summary>
public sealed class RuleCleanResult
{
    public required CleanupRule Rule { get; init; }

    public long BytesRemoved { get; set; }

    public int DeletedCount { get; set; }

    public List<DeleteFailure> Failures { get; } = [];
}

/// <summary>一次清理操作的完整报告。</summary>
public sealed class CleanupReport
{
    public List<RuleCleanResult> Results { get; } = [];

    public int TotalDeleted => Results.Sum(r => r.DeletedCount);

    public long TotalBytesRemoved => Results.Sum(r => r.BytesRemoved);

    public int TotalFailures => Results.Sum(r => r.Failures.Count);
}
