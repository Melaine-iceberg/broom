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
        IProgress<ScanProgress>? progress = null,
        CancellationToken ct = default)
        => Task.Run<IReadOnlyList<RuleScanResult>>(() => Scan(rules, progress, ct), ct);

    private static List<RuleScanResult> Scan(
        IReadOnlyList<CleanupRule> rules,
        IProgress<ScanProgress>? progress,
        CancellationToken ct)
    {
        var results = new List<RuleScanResult>(rules.Count);
        for (var i = 0; i < rules.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var rule = rules[i];
            progress?.Report(new ScanProgress(i, rules.Count, rule.DisplayName, ""));

            results.Add(rule.Kind == RuleKind.RecycleBin
                ? ScanRecycleBin(rule, i, rules.Count, progress, ct)
                : ScanPaths(rule, i, rules.Count, progress, ct));
        }

        return results;
    }

    private static RuleScanResult ScanPaths(
        CleanupRule rule,
        int index,
        int count,
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
                if (result.Roots.Contains(path))
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
}
