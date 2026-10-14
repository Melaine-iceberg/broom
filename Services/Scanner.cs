using System.IO.Enumeration;
using broom.Core;
using broom.Platform;

namespace broom.Services;

/// <summary>
/// 只读扫描:按规则展开路径并统计可清理的文件与大小。不修改任何文件。
/// </summary>
public sealed class Scanner
{
    private const int ProgressInterval = 256;

    public Task<IReadOnlyList<RuleScanResult>> ScanAsync(
        IReadOnlyList<CleanupRule> rules,
        IReadOnlyList<string>? excludedPaths = null,
        IReadOnlyList<string>? excludedFiles = null,
        IProgress<ScanProgress>? progress = null,
        CancellationToken ct = default,
        int skipRecentDays = 0)
        => Task.Run<IReadOnlyList<RuleScanResult>>(() => Scan(rules, excludedPaths, excludedFiles, skipRecentDays, progress, ct), ct);

    private static List<RuleScanResult> Scan(
        IReadOnlyList<CleanupRule> rules,
        IReadOnlyList<string>? excludedPaths,
        IReadOnlyList<string>? excludedFiles,
        int skipRecentDays,
        IProgress<ScanProgress>? progress,
        CancellationToken ct)
    {
        var excluded = NormalizeExcludedPaths(excludedPaths);
        var excludedFileSet = NormalizeExcludedFiles(excludedFiles);
        var protectModifiedAfter = skipRecentDays > 0 ? DateTime.UtcNow.AddDays(-skipRecentDays) : (DateTime?)null;
        var results = new List<RuleScanResult>(rules.Count);
        for (var i = 0; i < rules.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var rule = rules[i];
            progress?.Report(new ScanProgress(i, rules.Count, rule.DisplayName, ""));

            results.Add(rule.Kind switch
            {
                RuleKind.RecycleBin => ScanRecycleBin(rule, i, rules.Count, progress, ct),
                RuleKind.Action => ScanAction(rule, i, rules.Count, progress, ct),
                _ => ScanPaths(rule, i, rules.Count, excluded, excludedFileSet, protectModifiedAfter, progress, ct),
            });
        }

        return results;
    }

    private static RuleScanResult ScanPaths(
        CleanupRule rule,
        int index,
        int count,
        List<string> excluded,
        HashSet<string> excludedFiles,
        DateTime? protectModifiedAfter,
        IProgress<ScanProgress>? progress,
        CancellationToken ct)
    {
        var result = new RuleScanResult { Rule = rule };
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            // 跳过符号链接/联接点,避免循环与重复计数
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        foreach (var template in rule.Paths)
        {
            ct.ThrowIfCancellationRequested();
            foreach (var path in PathExpander.Expand(template))
            {
                if (result.Roots.Contains(path) || IsExcluded(path, excluded))
                {
                    continue;
                }

                result.Roots.Add(path);
                progress?.Report(new ScanProgress(index, count, rule.DisplayName, path));

                if (File.Exists(path))
                {
                    if (!excludedFiles.Contains(path))
                    {
                        AddFile(result, path, protectModifiedAfter);
                    }

                    continue;
                }

                try
                {
                    foreach (var file in Directory.EnumerateFiles(path, "*", options))
                    {
                        ct.ThrowIfCancellationRequested();
                        if (IsExcluded(file, excluded) || excludedFiles.Contains(file))
                        {
                            continue;
                        }

                        var name = Path.GetFileName(file);
                        if (!MatchesInclude(rule, name) || MatchesAny(rule.ExcludePatterns, name))
                        {
                            continue;
                        }

                        AddFile(result, file, protectModifiedAfter);
                        if (result.ItemCount % ProgressInterval == 0)
                        {
                            progress?.Report(new ScanProgress(index, count, rule.DisplayName, file));
                        }
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    result.Errors.Add($"{path}: {ex.Message}");
                }
            }
        }

        return result;
    }

    /// <summary>
    /// 回收站改为向 Shell 查询,而不是遍历 $Recycle.Bin 目录:
    /// 目录里除了 Shell 管理的条目,还堆着它不再承认的孤立残留($I 元数据等),
    /// 直接数文件会让界面数字与资源管理器不一致,清空操作也永远清不掉它们。
    /// </summary>
    /// <summary>动作型规则没有可枚举的文件:扫描只登记规则,释放量在执行后由报告的磁盘对比体现。</summary>
    private static RuleScanResult ScanAction(
        CleanupRule rule,
        int index,
        int count,
        IProgress<ScanProgress>? progress,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        progress?.Report(new ScanProgress(index, count, rule.DisplayName, ""));
        return new RuleScanResult { Rule = rule };
    }

    private static RuleScanResult ScanRecycleBin(
        CleanupRule rule,
        int index,
        int count,
        IProgress<ScanProgress>? progress,
        CancellationToken ct)
    {
        var result = new RuleScanResult { Rule = rule };
        ct.ThrowIfCancellationRequested();
        progress?.Report(new ScanProgress(index, count, rule.DisplayName, ""));

        if (!OperatingSystem.IsWindows())
        {
            result.Errors.Add("当前平台暂不支持扫描回收站");
            return result;
        }

        if (RecycleBinOps.TryQuery(out var size, out var itemCount, out var error))
        {
            result.TotalBytes = size;
            result.ItemCount = (int)Math.Min(itemCount, int.MaxValue);
        }
        else
        {
            result.Errors.Add($"<回收站>: {error}");
        }

        return result;
    }

    private static void AddFile(RuleScanResult result, string path, DateTime? protectModifiedAfter)
    {
        try
        {
            var info = new FileInfo(path);
            if (protectModifiedAfter is not null && info.LastWriteTimeUtc > protectModifiedAfter.Value)
            {
                return;
            }

            result.Files.Add(new ScannedFile(path, info.Length));
            result.TotalBytes += info.Length;
            result.ItemCount++;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static bool MatchesInclude(CleanupRule rule, string fileName)
        => rule.IsWholeDirectory || MatchesAny(rule.IncludePatterns, fileName);

    private static bool MatchesAny(string[] patterns, string fileName)
    {
        foreach (var pattern in patterns)
        {
            if (FileSystemName.MatchesSimpleExpression(pattern, fileName, ignoreCase: true))
            {
                return true;
            }
        }

        return false;
    }

    private static List<string> NormalizeExcludedPaths(IReadOnlyList<string>? excludedPaths)
    {
        var normalized = new List<string>();
        if (excludedPaths is null)
        {
            return normalized;
        }

        foreach (var raw in excludedPaths)
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                continue;
            }

            var expanded = Environment.ExpandEnvironmentVariables(raw.Trim()).TrimEnd('\\', '/');
            if (expanded.Length > 0)
            {
                normalized.Add(expanded);
            }
        }

        return normalized;
    }

    /// <summary>排除的文件按完整路径与扫描结果比较;环境变量在此展开,与排除目录保持一致的写法。</summary>
    private static HashSet<string> NormalizeExcludedFiles(IReadOnlyList<string>? excludedFiles)
    {
        var normalized = new HashSet<string>(PathComparer);
        if (excludedFiles is null)
        {
            return normalized;
        }

        foreach (var raw in excludedFiles)
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                continue;
            }

            var expanded = Environment.ExpandEnvironmentVariables(raw.Trim());
            if (expanded.Length > 0)
            {
                normalized.Add(expanded);
            }
        }

        return normalized;
    }

    /// <summary>路径前缀匹配:排除项自身及其子项(按目录段边界比较,避免 C:\Temp 误伤 C:\Temp2)。</summary>
    private static bool IsExcluded(string path, List<string> prefixes)
    {
        foreach (var prefix in prefixes)
        {
            if (path.Equals(prefix, PathComparison) ||
                (path.Length > prefix.Length
                    && path.StartsWith(prefix, PathComparison)
                    && path[prefix.Length] is '\\' or '/'))
            {
                return true;
            }
        }

        return false;
    }

    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;

    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;
}
