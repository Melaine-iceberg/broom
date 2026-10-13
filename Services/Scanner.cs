using System.IO.Enumeration;
using broom.Core;

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
        IProgress<ScanProgress>? progress = null,
        CancellationToken ct = default)
        => Task.Run<IReadOnlyList<RuleScanResult>>(() => Scan(rules, excludedPaths, progress, ct), ct);

    private static List<RuleScanResult> Scan(
        IReadOnlyList<CleanupRule> rules,
        IReadOnlyList<string>? excludedPaths,
        IProgress<ScanProgress>? progress,
        CancellationToken ct)
    {
        var excluded = NormalizeExcludedPaths(excludedPaths);
        var results = new List<RuleScanResult>(rules.Count);
        for (var i = 0; i < rules.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var rule = rules[i];
            progress?.Report(new ScanProgress(i, rules.Count, rule.DisplayName, ""));

            results.Add(rule.Kind == RuleKind.RecycleBin
                ? ScanRecycleBin(rule, i, rules.Count, excluded, progress, ct)
                : ScanPaths(rule, i, rules.Count, excluded, progress, ct));
        }

        return results;
    }

    private static RuleScanResult ScanPaths(
        CleanupRule rule,
        int index,
        int count,
        List<string> excluded,
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
                    AddFile(result, path);
                    continue;
                }

                try
                {
                    foreach (var file in Directory.EnumerateFiles(path, "*", options))
                    {
                        ct.ThrowIfCancellationRequested();
                        if (IsExcluded(file, excluded))
                        {
                            continue;
                        }

                        var name = Path.GetFileName(file);
                        if (!MatchesInclude(rule, name) || MatchesAny(rule.ExcludePatterns, name))
                        {
                            continue;
                        }

                        AddFile(result, file);
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

    private static RuleScanResult ScanRecycleBin(
        CleanupRule rule,
        int index,
        int count,
        List<string> excluded,
        IProgress<ScanProgress>? progress,
        CancellationToken ct)
    {
        var result = new RuleScanResult { Rule = rule };
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        foreach (var drive in DriveInfo.GetDrives())
        {
            if (!drive.IsReady || drive.DriveType is not (DriveType.Fixed or DriveType.Removable))
            {
                continue;
            }

            var binRoot = Path.Combine(drive.RootDirectory.FullName, "$Recycle.Bin");
            if (!Directory.Exists(binRoot))
            {
                continue;
            }

            result.Roots.Add(binRoot);
            progress?.Report(new ScanProgress(index, count, rule.DisplayName, binRoot));

            try
            {
                foreach (var item in Directory.EnumerateFileSystemEntries(binRoot, "*", options))
                {
                    ct.ThrowIfCancellationRequested();
                    try
                    {
                        if (IsExcluded(item, excluded))
                        {
                            continue;
                        }

                        if ((File.GetAttributes(item) & FileAttributes.Directory) != 0)
                        {
                            continue;
                        }

                        result.TotalBytes += new FileInfo(item).Length;
                        result.ItemCount++;
                        if (result.ItemCount % ProgressInterval == 0)
                        {
                            progress?.Report(new ScanProgress(index, count, rule.DisplayName, item));
                        }
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                result.Errors.Add($"{binRoot}: {ex.Message}");
            }
        }

        return result;
    }

    private static void AddFile(RuleScanResult result, string path)
    {
        try
        {
            var size = new FileInfo(path).Length;
            result.Files.Add(new ScannedFile(path, size));
            result.TotalBytes += size;
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
}
