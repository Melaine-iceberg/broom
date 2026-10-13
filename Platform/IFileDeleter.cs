namespace broom.Platform;

/// <summary>
/// 删除策略抽象:Windows 上实现"移入回收站",其他平台将来可接入各自的回收站规范。
/// </summary>
public interface IFileDeleter
{
    /// <summary>删除方式的显示名称,例如 "回收站" / "永久删除"。</summary>
    string Name { get; }

    /// <summary>
    /// 删除给定文件,返回成功删除的数量;
    /// 每个失败的路径及原因写入 <paramref name="failures"/>。
    /// </summary>
    int Delete(IReadOnlyList<string> paths, IDictionary<string, string> failures, CancellationToken ct = default);
}
