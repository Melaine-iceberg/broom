using System.Runtime.Versioning;
using System.Security.Principal;

namespace broom.Platform;

/// <summary>
/// 清空回收站 —— 这是不可逆操作,调用后文件无法再恢复。
/// 顺带清除 Shell 已不再管理的孤立残留($I/$R 缺少配对的条目):它们不出现在资源管理器里,
/// SHEmptyRecycleBin 也不会删除,只能由清理工具处理。
/// </summary>
[SupportedOSPlatform("windows")]
public static class RecycleBinOps
{
    /// <summary>孤立残留至少存在这么久才会被清除,避免误删刚删除、$I/$R 尚未配对完成的条目。</summary>
    private static readonly TimeSpan OrphanMinAge = TimeSpan.FromHours(1);

    /// <summary>清空回收站并清除孤立残留;返回实际清除的项数与字节数,失败原因写入 <paramref name="error"/>。</summary>
    public static bool TryPurge(out int itemsRemoved, out long bytesFreed, out string error)
    {
        var shellItems = 0;
        var shellBytes = 0L;
        var message = "";
        var ok = WindowsShell.RunSta(() => WindowsShell.EmptyRecycleBin(out shellItems, out shellBytes, out message));

        var (orphanItems, orphanBytes) = PurgeOrphans();
        itemsRemoved = shellItems + orphanItems;
        bytesFreed = shellBytes + orphanBytes;
        error = message;
        return ok;
    }

    /// <summary>查询回收站(Shell 视角)的占用空间与项数。</summary>
    public static bool TryQuery(out long size, out long itemCount, out string error)
    {
        long queriedSize = 0;
        long queriedCount = 0;
        var message = "";
        var ok = WindowsShell.RunSta(() => WindowsShell.TryQueryRecycleBin(out queriedSize, out queriedCount, out message));

        size = queriedSize;
        itemCount = queriedCount;
        error = message;
        return ok;
    }

    /// <summary>删除当前用户各盘回收站里缺少配对文件的孤立 $I / $R 条目。</summary>
    private static (int Items, long Bytes) PurgeOrphans()
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value;
        if (userSid is null)
        {
            return (0, 0);
        }

        var cutoff = DateTime.UtcNow - OrphanMinAge;
        var items = 0;
        var bytes = 0L;

        foreach (var drive in DriveInfo.GetDrives())
        {
            if (!drive.IsReady || drive.DriveType is not (DriveType.Fixed or DriveType.Removable))
            {
                continue;
            }

            var userBin = Path.Combine(drive.RootDirectory.FullName, "$Recycle.Bin", userSid);
            if (!Directory.Exists(userBin))
            {
                continue;
            }

            var options = new EnumerationOptions
            {
                RecurseSubdirectories = false,
                IgnoreInaccessible = true,
                // $I/$R 通常是隐藏/系统属性,必须显式声明不跳过,否则枚举不到
                AttributesToSkip = FileAttributes.None,
            };

            try
            {
                foreach (var entry in Directory.EnumerateFileSystemEntries(userBin, "*", options))
                {
                    var name = Path.GetFileName(entry);
                    if (name.Length < 2 || name[0] != '$')
                    {
                        continue;
                    }

                    var prefix = char.ToUpperInvariant(name[1]);
                    if (prefix is not ('I' or 'R'))
                    {
                        continue;
                    }

                    var counterpart = Path.Combine(userBin, (prefix == 'I' ? "$R" : "$I") + name[2..]);
                    if (File.Exists(counterpart) || Directory.Exists(counterpart))
                    {
                        continue;
                    }

                    try
                    {
                        var isDirectory = (File.GetAttributes(entry) & FileAttributes.Directory) != 0;
                        var lastWrite = isDirectory ? Directory.GetLastWriteTimeUtc(entry) : File.GetLastWriteTimeUtc(entry);
                        if (lastWrite > cutoff)
                        {
                            continue;
                        }

                        var size = isDirectory ? GetDirectorySize(entry) : new FileInfo(entry).Length;
                        if (isDirectory)
                        {
                            Directory.Delete(entry, recursive: true);
                        }
                        else
                        {
                            File.Delete(entry);
                        }

                        items++;
                        bytes += size;
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        // 单个孤立残留删除失败不影响整体清理(可能正被占用)
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }

        return (items, bytes);
    }

    private static long GetDirectorySize(string path)
    {
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        try
        {
            return Directory.EnumerateFiles(path, "*", options).Sum(f => new FileInfo(f).Length);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return 0;
        }
    }
}
