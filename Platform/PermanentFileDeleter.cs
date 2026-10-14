namespace broom.Platform;

/// <summary>永久删除(不经过回收站);开启安全擦除时先随机覆写文件内容再删除。</summary>
public sealed class PermanentFileDeleter : IFileDeleter
{
    private readonly int _overwritePasses;

    /// <param name="overwritePasses">删除前的随机覆写次数;0 表示不覆写。</param>
    public PermanentFileDeleter(int overwritePasses = 0) => _overwritePasses = overwritePasses;

    public string Name => _overwritePasses > 0 ? $"永久删除(覆写 {_overwritePasses} 次)" : "永久删除";

    public int Delete(IReadOnlyList<string> paths, IDictionary<string, string> failures, CancellationToken ct = default)
    {
        var deleted = 0;
        foreach (var path in paths)
        {
            if (ct.IsCancellationRequested)
            {
                break;
            }

            try
            {
                if (_overwritePasses > 0)
                {
                    // 覆写失败时不删除:宁可留下文件,也不无声跳过"不可恢复"的承诺
                    if (File.Exists(path))
                    {
                        SecureErase.OverwriteAndDelete(path, _overwritePasses);
                    }
                }
                else
                {
                    // File.Delete 对不存在的文件不抛异常,视为已清理
                    File.Delete(path);
                }

                deleted++;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                failures[path] = ex.Message;
            }
        }

        return deleted;
    }
}
