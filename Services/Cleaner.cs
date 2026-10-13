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
        CancellationToken ct = default)
        => Task.Run(() => Clean(targets, deleter, progress, ct), ct);

    private static CleanupReport Clean(
        IReadOnlyList<RuleScanResult> targets,
        IFileDeleter deleter,
        IProgress<CleanProgress>? progress,
        CancellationToken ct)
    {
        var report = new CleanupReport();
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
                DeleteFiles(target, deleter, result, ct);
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

    private static void DeleteFiles(RuleScanResult target, IFileDeleter deleter, RuleCleanResult result, CancellationToken ct)
    {
        if (target.Files.Count == 0)
        {
            return;
        }

        var paths = new List<string>(target.Files.Count);
        foreach (var file in target.Files)
        {
            paths.Add(file.Path);
        }

        var failures = new Dictionary<string, string>();
        result.DeletedCount = deleter.Delete(paths, failures, ct);
        foreach (var (path, reason) in failures)
        {
            result.Failures.Add(new DeleteFailure(path, reason));
        }

        // 只统计真正删除成功的文件体积
        result.BytesRemoved = target.Files.Where(f => !failures.ContainsKey(f.Path)).Sum(f => f.Size);
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
