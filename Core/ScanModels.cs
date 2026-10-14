namespace broom.Core;

/// <summary>扫描发现的一个文件及其大小。</summary>
public readonly record struct ScannedFile(string Path, long Size);

/// <summary>清理前后某个盘符的可用空间对比。</summary>
/// <param name="Drive">盘符根目录,例如 "C:\"。</param>
public readonly record struct DriveSpaceDelta(string Drive, long FreeBefore, long FreeAfter)
{
    /// <summary>本次清理释放的空间(可能为负:其他程序同时在写盘)。</summary>
    public long FreedBytes => FreeAfter - FreeBefore;
}

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
public sealed record CleanProgress(int RuleIndex, int RuleCount, string RuleName, string Detail = "");

/// <summary>单个文件的删除失败记录。</summary>
public sealed record DeleteFailure(string Path, string Reason);

/// <summary>单条规则的清理结果。</summary>
public sealed class RuleCleanResult
{
    public required CleanupRule Rule { get; init; }

    public long BytesRemoved { get; set; }

    public int DeletedCount { get; set; }

    /// <summary>动作型规则的执行摘要,例如“已清空 12 个事件日志”;按文件清理的规则为空。</summary>
    public string Summary { get; set; } = "";

    public List<DeleteFailure> Failures { get; } = [];
}

/// <summary>一次清理操作的报告。被取消时为已完成的部分。</summary>
public sealed class CleanupReport
{
    public List<RuleCleanResult> Results { get; } = [];

    /// <summary>因取消而未执行的规则(保持选中顺序)。</summary>
    public List<CleanupRule> SkippedRules { get; } = [];

    /// <summary>清理是否被用户取消(剩余规则未执行)。</summary>
    public bool WasCancelled { get; set; }

    public int TotalDeleted => Results.Sum(r => r.DeletedCount);

    public long TotalBytesRemoved => Results.Sum(r => r.BytesRemoved);

    public int TotalFailures => Results.Sum(r => r.Failures.Count);

    /// <summary>清理前后各盘可用空间对比(只含本次清理涉及、且读取成功的盘符)。</summary>
    public List<DriveSpaceDelta> DriveSpace { get; } = [];

    /// <summary>顺带回收的空目录数量(仅在开启“清理后移除空目录”或整目录规则时统计)。</summary>
    public int EmptyDirectoriesRemoved { get; set; }
}
