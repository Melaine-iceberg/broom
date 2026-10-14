using System.Globalization;
using broom.Core;

namespace broom.Platform;

/// <summary>
/// 隔离区存储:默认 %LOCALAPPDATA%\broom\quarantine(便携模式见 <see cref="AppPaths"/>:exe 同目录 data\quarantine)。
/// 每次清理建一个时间戳会话目录,文件按原路径暂存在其中,
/// 这里负责会话创建、用量统计、过期清理与整体清空;会话内的移动 / 还原见 <see cref="QuarantineSession"/>。
/// </summary>
public sealed class QuarantineService
{
    private readonly string _rootPath;

    /// <param name="rootPath">隔离区根目录;留空时使用 <see cref="AppPaths.QuarantineDirectory"/>。</param>
    public QuarantineService(string? rootPath = null)
    {
        _rootPath = rootPath ?? AppPaths.QuarantineDirectory;
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
    public int PurgeExpired(int retentionDays, int secureErasePasses = 0)
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

            var (items, _, _) = DeleteTree(directory, secureErasePasses);
            removed += items;
        }

        return removed;
    }

    /// <summary>清空隔离区(不可恢复),返回清掉的项数与字节数。</summary>
    public bool TryPurgeAll(out int itemsRemoved, out long bytesReleased, out string error, int secureErasePasses = 0)
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
            var (items, bytes, sessionError) = DeleteTree(directory, secureErasePasses);
            itemsRemoved += items;
            bytesReleased += bytes;
            if (sessionError is not null)
            {
                // 单个会话删除失败不阻塞其余会话;失败原因回报给用户
                failed = true;
                error = sessionError;
            }
        }

        return !failed;
    }

    /// <summary>
    /// 删除一个会话目录。开启安全擦除时逐文件「覆写后删除」再回收空目录;
    /// 覆写失败的文件保留原样,不整树强删 —— 不让"不可恢复"的承诺被静默跳过。
    /// </summary>
    private static (int ItemsRemoved, long BytesRemoved, string? Error) DeleteTree(string directory, int secureErasePasses)
    {
        if (secureErasePasses <= 0)
        {
            var (items, bytes) = GetUsage(directory, recursive: true);
            try
            {
                Directory.Delete(directory, recursive: true);
                return (items, bytes, null);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return (0, 0, ex.Message);
            }
        }

        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        var removed = 0;
        long removedBytes = 0;
        string? error = null;
        foreach (var file in new DirectoryInfo(directory).EnumerateFiles("*", options))
        {
            try
            {
                var length = file.Length;
                SecureErase.OverwriteAndDelete(file.FullName, secureErasePasses);
                removed++;
                removedBytes += length;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                error = ex.Message;
            }
        }

        // 只回收空目录;还留着覆写失败文件的目录会保留下来
        foreach (var sub in new DirectoryInfo(directory).EnumerateDirectories("*", options).OrderByDescending(d => d.FullName.Length))
        {
            try
            {
                if (!sub.EnumerateFileSystemInfos().Any())
                {
                    sub.Delete();
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }

        try
        {
            if (!Directory.EnumerateFileSystemEntries(directory).Any())
            {
                Directory.Delete(directory);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            error ??= ex.Message;
        }

        return (removed, removedBytes, error);
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
