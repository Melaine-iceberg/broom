namespace broom.Platform;

/// <summary>永久删除(不经过回收站)。</summary>
public sealed class PermanentFileDeleter : IFileDeleter
{
    public string Name => "永久删除";

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
                // File.Delete 对不存在的文件不抛异常,视为已清理
                File.Delete(path);
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
