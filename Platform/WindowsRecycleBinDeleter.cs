using System.Runtime.Versioning;

using broom.Localization;
namespace broom.Platform;

/// <summary>
/// 把文件移入回收站(可恢复)。整批调用 Shell,失败时逐文件重试以定位失败原因。
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsRecycleBinDeleter : IFileDeleter
{
    private const int BatchSize = 512;

    public string Name => Strings.T("回收站");

    public int Delete(IReadOnlyList<string> paths, IDictionary<string, string> failures, CancellationToken ct = default)
    {
        if (paths.Count == 0)
        {
            return 0;
        }

        return WindowsShell.RunSta(() =>
        {
            var deleted = 0;
            for (var offset = 0; offset < paths.Count; offset += BatchSize)
            {
                if (ct.IsCancellationRequested)
                {
                    break;
                }

                var chunk = paths.Skip(offset).Take(BatchSize).ToList();
                deleted += DeleteChunk(chunk, failures);
            }

            return deleted;
        });
    }

    private static int DeleteChunk(List<string> chunk, IDictionary<string, string> failures)
    {
        if (WindowsShell.DeleteToRecycleBin(chunk, out _))
        {
            return chunk.Count;
        }

        // 整批失败(例如个别文件被占用)→ 逐个重试,区分"已被整批删除"与真正的失败项
        var deleted = 0;
        foreach (var path in chunk)
        {
            if (!File.Exists(path))
            {
                deleted++;
                continue;
            }

            if (WindowsShell.DeleteToRecycleBin([path], out var error))
            {
                deleted++;
            }
            else
            {
                failures[path] = error;
            }
        }

        return deleted;
    }
}
