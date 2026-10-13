namespace broom.Core;

/// <summary>把规则里的路径模板(环境变量 + 目录名通配符)展开为真实存在的路径。</summary>
public static class PathExpander
{
    public static IEnumerable<string> Expand(string template)
    {
        var expanded = Environment.ExpandEnvironmentVariables(template);
        if (!expanded.Contains('*'))
        {
            if (Directory.Exists(expanded) || File.Exists(expanded))
            {
                yield return expanded;
            }

            yield break;
        }

        var root = Path.GetPathRoot(expanded) ?? "";
        var segments = expanded[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        var current = new List<string> { root };

        foreach (var segment in segments)
        {
            var next = new List<string>();
            foreach (var parent in current)
            {
                if (!segment.Contains('*'))
                {
                    var candidate = Path.Combine(parent, segment);
                    if (Directory.Exists(candidate))
                    {
                        next.Add(candidate);
                    }

                    continue;
                }

                try
                {
                    // 通配符展开需要看到隐藏/系统目录(例如 $WINDOWS.~BT),因此不跳过任何属性
                    next.AddRange(Directory.EnumerateDirectories(parent, segment, new EnumerationOptions { AttributesToSkip = 0 }));
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                {
                }
            }

            current = next;
            if (current.Count == 0)
            {
                yield break;
            }
        }

        foreach (var path in current)
        {
            yield return path;
        }
    }
}
