using broom.Core;

namespace broom.Platform;

/// <summary>动作型清理项的执行结果。</summary>
public sealed class CleanupActionResult
{
    /// <summary>整体是否成功;部分失败时仍可为 true(逐项原因进 <see cref="Failures"/>)。</summary>
    public required bool Success { get; init; }

    /// <summary>整体失败原因;成功时为 null。</summary>
    public string? Error { get; init; }

    /// <summary>受影响的条目数(事件日志条数 / 卷影副本个数);无法计量时为 0。</summary>
    public int ItemsAffected { get; init; }

    /// <summary>释放的字节数;无法计量时为 0(实际释放看清理报告的磁盘对比)。</summary>
    public long BytesFreed { get; init; }

    /// <summary>面向用户的执行摘要,例如“已清空 12 个事件日志”。</summary>
    public string Summary { get; init; } = "";

    /// <summary>逐项失败原因。</summary>
    public List<DeleteFailure> Failures { get; } = [];
}

/// <summary>执行「动作型」清理项:不逐个删文件,而是调用系统能力完成一次清理动作。</summary>
public interface ICleanupActionService
{
    /// <summary>当前平台是否支持该动作。</summary>
    bool IsSupported(CleanupAction action);

    /// <summary>
    /// 执行清理动作。长耗时动作应通过 <paramref name="progress"/> 汇报阶段文本;
    /// <paramref name="ct"/> 取消时应尽快终止并抛出 <see cref="OperationCanceledException"/>。
    /// </summary>
    CleanupActionResult Execute(CleanupAction action, IProgress<string>? progress = null, CancellationToken ct = default);
}
