using broom.Core;
using broom.Platform;

namespace broom.Services;

/// <summary>
/// 执行清理:通过 <see cref="IFileDeleter"/> 删除扫描结果,并给出逐条失败原因。
/// 对"整目录"规则,删除文件后顺带回收空目录(不删除扫描根目录本身)。
/// 取消时停止处理并返回已完成的部分,未执行的规则记录在 <see cref="CleanupReport.SkippedRules"/>。
/// </summary>
public sealed class Cleaner
{
    public Task<CleanupReport> CleanAsync(
        IReadOnlyList<RuleScanResult> targets,
        IFileDeleter deleter,
        IProgress<CleanProgress>? progress = null,
        CancellationToken ct = default,
        int skipRecentDays = 0,
        Func<string, long?>? getFreeBytes = null)
        => Task.Run(() => Clean(targets, deleter, skipRecentDays, progress, ct, getFreeBytes), ct);

    private static CleanupReport Clean(
        IReadOnlyList<RuleScanResult> targets,
        IFileDeleter deleter,
        int skipRecentDays,
        IProgress<CleanProgress>? progress,
        CancellationToken ct,
        Func<string, long?>? getFreeBytes)
    {
        var report = new CleanupReport();
        var probe = getFreeBytes ?? ProbeFreeBytes;
        var drives = CollectDrives(targets);
        var freeBefore = SnapshotFreeSpace(drives, probe);
        var protectModifiedAfter = skipRecentDays > 0 ? DateTime.UtcNow.AddDays(-skipRecentDays) : (DateTime?)null;
        for (var i = 0; i < targets.Count; i++)
        {
            if (ct.IsCancellationRequested)
            {
                MarkCancelled(report, targets, i);
                break;
            }

            var target = targets[i];
            progress?.Report(new CleanProgress(i, targets.Count, target.Rule.DisplayName));

            var result = new RuleCleanResult { Rule = target.Rule };
            if (target.Rule.Kind == RuleKind.RecycleBin)
            {
                EmptyRecycleBin(result);
            }
            else
            {
                DeleteFiles(target, deleter, result, protectModifiedAfter, ct);
                if (target.Rule.IsWholeDirectory)
                {
                    RemoveEmptyDirectories(target.Roots, ct);
                }
            }

            report.Results.Add(result);

            // 在规则处理过程中取消(含最后一条规则):已删项照常汇报,剩余规则标记为未执行
            if (ct.IsCancellationRequested)
            {
                MarkCancelled(report, targets, i + 1);
                break;
            }
        }

        // 清理前后对比:即使取消,已完成部分的实际效果同样给出
        CaptureDiskSpace(report, drives, probe, freeBefore);
        return report;
    }

    private static void MarkCancelled(CleanupReport report, IReadOnlyList<RuleScanResult> targets, int fromIndex)
    {
        report.WasCancelled = true;
        for (var i = fromIndex; i < targets.Count; i++)
        {
            report.SkippedRules.Add(targets[i].Rule);
        }
    }

    /// <summary>默认的盘符可用空间探针;读取失败返回 null,该盘不进入对比。</summary>
    private static long? ProbeFreeBytes(string driveRoot)
    {
        try
        {
            return new DriveInfo(driveRoot).AvailableFreeSpace;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
        {
            return null;
        }
    }

    /// <summary>收集本次清理涉及的盘符:按被删文件所在盘;含回收站规则时覆盖全部就绪的固定磁盘。</summary>
    private static List<string> CollectDrives(IReadOnlyList<RuleScanResult> targets)
    {
        var drives = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var target in targets)
        {
            if (target.Rule.Kind == RuleKind.RecycleBin)
            {
                AddFixedDrives(drives);
                continue;
            }

            foreach (var path in target.Files.Select(f => f.Path).Concat(target.Roots))
            {
                var root = Path.GetPathRoot(path);
                if (!string.IsNullOrEmpty(root))
                {
                    drives.Add(root);
                }
            }
        }

        return [.. drives.OrderBy(d => d, StringComparer.OrdinalIgnoreCase)];
    }

    private static void AddFixedDrives(HashSet<string> drives)
    {
        try
        {
            foreach (var drive in DriveInfo.GetDrives())
            {
                if (drive.DriveType == DriveType.Fixed && drive.IsReady)
                {
                    drives.Add(drive.Name);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
        }
    }

    private static Dictionary<string, long> SnapshotFreeSpace(List<string> drives, Func<string, long?> probe)
    {
        var snapshot = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var drive in drives)
        {
            if (probe(drive) is { } free)
            {
                snapshot[drive] = free;
            }
        }

        return snapshot;
    }

    private static void CaptureDiskSpace(CleanupReport report, List<string> drives, Func<string, long?> probe, Dictionary<string, long> freeBefore)
    {
        foreach (var drive in drives)
        {
            if (freeBefore.TryGetValue(drive, out var before) && probe(drive) is { } after)
            {
                report.DriveSpace.Add(new DriveSpaceDelta(drive, before, after));
            }
        }
    }

    private static void EmptyRecycleBin(RuleCleanResult result)
    {
        if (!OperatingSystem.IsWindows())
        {
            result.Failures.Add(new DeleteFailure("<回收站>", "当前平台暂不支持清空回收站"));
            return;
        }

        var ok = RecycleBinOps.TryPurge(out var itemsRemoved, out var bytesFreed, out var error);

        // 以实际清除量为准:Shell 管理的条目 + 孤立残留;被占用而清不掉的部分不计入
        result.DeletedCount = itemsRemoved;
        result.BytesRemoved = bytesFreed;

        if (!ok)
        {
            result.Failures.Add(new DeleteFailure("<回收站>", error));
        }
    }

    private static void DeleteFiles(RuleScanResult target, IFileDeleter deleter, RuleCleanResult result, DateTime? protectModifiedAfter, CancellationToken ct)
    {
        if (target.Files.Count == 0)
        {
            return;
        }

        // 删除前复核:扫描之后被重新写入的文件同样跳过,"跳过最近修改"的承诺在删除时刻依然成立
        var candidates = new List<ScannedFile>(target.Files.Count);
        foreach (var file in target.Files)
        {
            if (protectModifiedAfter is not null && File.GetLastWriteTimeUtc(file.Path) > protectModifiedAfter.Value)
            {
                continue;
            }

            candidates.Add(file);
        }

        var paths = new List<string>(candidates.Count);
        foreach (var file in candidates)
        {
            paths.Add(file.Path);
        }

        var failures = new Dictionary<string, string>();
        result.DeletedCount = deleter.Delete(paths, failures, ct);
        foreach (var (path, reason) in failures)
        {
            result.Failures.Add(new DeleteFailure(path, reason));
        }

        // 只统计真正处理过的文件体积:取消时删除器停止处理,未处理的尾部不计入释放量
        // (IFileDeleter 按传入顺序执行、取消即停,已处理的是 candidates 的前缀)
        var processed = result.DeletedCount + failures.Count;
        result.BytesRemoved = candidates.Take(processed)
            .Where(f => !failures.ContainsKey(f.Path))
            .Sum(f => f.Size);
    }

    private static void RemoveEmptyDirectories(IEnumerable<string> roots, CancellationToken ct)
    {
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        foreach (var root in roots)
        {
            if (ct.IsCancellationRequested)
            {
                return;
            }

            try
            {
                // 由深到浅处理,子目录删除后父目录才可能变为空
                var directories = Directory.EnumerateDirectories(root, "*", options)
                    .OrderByDescending(d => d.Count(c => c == Path.DirectorySeparatorChar));
                foreach (var directory in directories)
                {
                    if (ct.IsCancellationRequested)
                    {
                        return;
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
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
    }
}
