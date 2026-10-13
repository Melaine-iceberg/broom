using System.Globalization;

namespace broom.Platform;

/// <summary>
/// 隔离区存储:%LOCALAPPDATA%\broom\quarantine。每次清理建一个时间戳会话目录,文件按原路径暂存在其中,
/// 这里负责会话创建、用量统计、过期清理与整体清空;会话内的移动 / 还原见 <see cref="QuarantineSession"/>。
/// </summary>
public sealed class QuarantineService
{
    private readonly string _rootPath;

    /// <param name="rootPath">隔离区根目录;留空时使用 %LOCALAPPDATA%\broom\quarantine。</param>
    public QuarantineService(string? rootPath = null)
    {
        _rootPath = rootPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "broom", "quarantine");
    }

    public string RootPath => _rootPath;

    public QuarantineSession CreateSession(DateTimeOffset? now = null)
    {
        var timestamp = now ?? DateTimeOffset.Now;
        return new QuarantineSession(
            _rootPath,
            timestamp.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture),
            timestamp);
    }

    /// <summary>当前隔离区中的文件数与占用字节数。</summary>
    public (int ItemCount, long Bytes) GetUsage() => GetUsage(_rootPath, recursive: true);

    /// <summary>删除超过保留天数的会话(0 表示永久保留),返回清理掉的文件数。</summary>
    public int PurgeExpired(int retentionDays)
    {
        if (retentionDays <= 0 || !Directory.Exists(_rootPath))
        {
            return 0;
        }

        var cutoff = DateTimeOffset.Now.AddDays(-retentionDays);
        var removed = 0;
        foreach (var directory in EnumerateSessions())
        {
            if (GetCreatedAt(directory) >= cutoff)
            {
                continue;
            }

            var items = GetUsage(directory, recursive: true).ItemCount;
            try
            {
                Directory.Delete(directory, recursive: true);
                removed += items;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }

        return removed;
    }

    /// <summary>清空隔离区(不可恢复),返回清掉的项数与字节数。</summary>
    public bool TryPurgeAll(out int itemsRemoved, out long bytesReleased, out string error)
    {
        itemsRemoved = 0;
        bytesReleased = 0;
        error = "";
        if (!Directory.Exists(_rootPath))
        {
            return true;
        }

        var failed = false;
        foreach (var directory in EnumerateSessions())
        {
            var (items, bytes) = GetUsage(directory, recursive: true);
            try
            {
                Directory.Delete(directory, recursive: true);
                itemsRemoved += items;
                bytesReleased += bytes;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 单个会话删除失败不阻塞其余会话;失败原因回报给用户
                failed = true;
                error = ex.Message;
            }
        }

        return !failed;
    }

    private IEnumerable<string> EnumerateSessions()
    {
        try
        {
            return Directory.EnumerateDirectories(_rootPath).ToList();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static (int ItemCount, long Bytes) GetUsage(string directory, bool recursive)
    {
        if (!Directory.Exists(directory))
        {
            return (0, 0);
        }

        var items = 0;
        long bytes = 0;
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = recursive,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        try
        {
            foreach (var file in new DirectoryInfo(directory).EnumerateFiles("*", options))
            {
                items++;
                bytes += file.Length;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }

        return (items, bytes);
    }

    /// <summary>会话目录名即创建时间;名字不合规范时退回目录的写入时间。</summary>
    private static DateTimeOffset GetCreatedAt(string directory)
    {
        var name = Path.GetFileName(directory);
        if (DateTimeOffset.TryParseExact(
                name,
                "yyyyMMdd-HHmmss",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal,
                out var parsed))
        {
            return parsed;
        }

        try
        {
            return Directory.GetLastWriteTimeUtc(directory);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return DateTimeOffset.MaxValue;
        }
    }
}
