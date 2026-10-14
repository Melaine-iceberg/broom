using System.Text;
using System.Text.Json;
using broom.Core;

using broom.Localization;
namespace broom.Platform;

/// <summary>
/// 一次清理的隔离会话:文件移动到 &lt;隔离区根&gt;\&lt;时间戳&gt;\&lt;卷标&gt;\&lt;原路径&gt;,
/// 清单(<c>manifest.json</c>)记录原位置以便还原。还原只移回原位置,不覆盖已存在的同名文件。
/// </summary>
public sealed class QuarantineSession
{
    private const string ManifestFileName = "manifest.json";

    /// <summary>路径比较方式(Windows 不区分大小写),与应用其余部分的判定保持一致。</summary>
    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;

    private readonly List<QuarantineEntry> _entries = [];
    private readonly string _manifestPath;

    internal QuarantineSession(string rootPath, string name, DateTimeOffset createdAt)
    {
        CreatedAt = createdAt;
        SessionDirectory = Path.Combine(rootPath, name);
        _manifestPath = Path.Combine(SessionDirectory, ManifestFileName);
    }

    public DateTimeOffset CreatedAt { get; }

    public string SessionDirectory { get; }

    public IReadOnlyList<QuarantineEntry> Entries => _entries;

    /// <summary>可还原的条目(登记"重启后删除"的副本不能还原)。</summary>
    public IEnumerable<QuarantineEntry> RestorableEntries => _entries.Where(entry => !entry.PendingReboot);

    public int RestorableCount => _entries.Count(entry => !entry.PendingReboot);

    /// <summary>把文件移入隔离区;文件已不存在视为已清理(与永久删除的行为一致)。</summary>
    public bool TryQuarantine(string path, out string error)
    {
        error = "";
        if (!File.Exists(path))
        {
            return true;
        }

        long size;
        var target = BuildStoredPath(path);
        try
        {
            size = new FileInfo(path).Length;
            System.IO.Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Move(path, target);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            error = ex.Message;
            return false;
        }

        _entries.Add(new QuarantineEntry { OriginalPath = path, QuarantinePath = target, Size = size });
        return true;
    }

    /// <summary>登记"重启后删除"前保留副本:移动会与登记冲突,因此这里复制。</summary>
    public bool TryCopyForPendingReboot(string path, out string error)
    {
        error = "";
        if (!File.Exists(path))
        {
            error = Strings.T("文件不存在");
            return false;
        }

        // 已经复制过(例如上次登记因权限不足失败,提权后重试):直接视为已保留
        var copied = _entries.FirstOrDefault(entry =>
            entry.PendingReboot && PathComparer.Equals(entry.OriginalPath, path) && File.Exists(entry.QuarantinePath));
        if (copied is not null)
        {
            return true;
        }

        var target = BuildStoredPath(path);
        try
        {
            System.IO.Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(path, target);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            error = ex.Message;
            return false;
        }

        _entries.Add(new QuarantineEntry
        {
            OriginalPath = path,
            QuarantinePath = target,
            Size = new FileInfo(target).Length,
            PendingReboot = true,
        });

        Flush();
        return true;
    }

    /// <summary>把条目移回原位置并写入清单;原位置已有同名文件时不覆盖。</summary>
    public bool TryRestore(QuarantineEntry entry, out string error)
    {
        if (entry.PendingReboot)
        {
            error = Strings.T("已登记重启后删除,无法在原位置还原;如需保留请从隔离区复制副本。");
            return false;
        }

        if (!File.Exists(entry.QuarantinePath))
        {
            error = Strings.T("隔离区中的副本已不存在(可能已被清理)。");
            return false;
        }

        if (File.Exists(entry.OriginalPath))
        {
            error = Strings.T("原位置已存在同名文件,未覆盖。");
            return false;
        }

        try
        {
            var parent = Path.GetDirectoryName(entry.OriginalPath);
            if (!string.IsNullOrEmpty(parent))
            {
                System.IO.Directory.CreateDirectory(parent);
            }

            File.Move(entry.QuarantinePath, entry.OriginalPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            error = ex.Message;
            return false;
        }

        _entries.Remove(entry);
        Compact();
        error = "";
        return true;
    }

    /// <summary>把当前条目写入清单;写入失败不影响隔离本身(文件仍按原路径存放,可人工找回)。</summary>
    public void Flush()
    {
        if (_entries.Count == 0)
        {
            return;
        }

        try
        {
            System.IO.Directory.CreateDirectory(SessionDirectory);
            var manifest = new QuarantineManifest { CreatedAt = CreatedAt, Entries = [.. _entries] };
            File.WriteAllText(
                _manifestPath,
                JsonSerializer.Serialize(manifest, QuarantineJsonContext.Default.QuarantineManifest));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
        }
    }

    /// <summary>还原后移除空目录;全部还原完成后会话目录与清单一起消失。</summary>
    private void Compact()
    {
        try
        {
            if (!System.IO.Directory.Exists(SessionDirectory))
            {
                return;
            }

            RemoveEmptySubdirectories(SessionDirectory);
            if (_entries.Count > 0)
            {
                Flush();
                return;
            }

            if (File.Exists(_manifestPath))
            {
                File.Delete(_manifestPath);
            }

            if (!System.IO.Directory.EnumerateFileSystemEntries(SessionDirectory).Any())
            {
                System.IO.Directory.Delete(SessionDirectory);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static void RemoveEmptySubdirectories(string root)
    {
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        try
        {
            // 由深到浅处理,子目录删除后父目录才可能变为空
            foreach (var directory in System.IO.Directory.EnumerateDirectories(root, "*", options)
                         .OrderByDescending(d => d.Count(c => c is '\\' or '/')))
            {
                try
                {
                    if (!System.IO.Directory.EnumerateFileSystemEntries(directory).Any())
                    {
                        System.IO.Directory.Delete(directory);
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

    /// <summary>隔离位置 = 会话目录 / 卷标 / 原路径其余部分,便于人工辨认。</summary>
    private string BuildStoredPath(string originalPath)
    {
        var root = Path.GetPathRoot(originalPath) ?? "";
        var relative = originalPath[root.Length..].TrimStart('\\', '/');
        var volume = SanitizeVolumeLabel(root);
        return relative.Length == 0
            ? Path.Combine(SessionDirectory, volume)
            : Path.Combine(SessionDirectory, volume, relative);
    }

    /// <summary>把卷标变成合法目录名:"C:\" → "C","\\server\share\" → "server_share"。</summary>
    private static string SanitizeVolumeLabel(string root)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var builder = new StringBuilder(root.Length);
        foreach (var c in root)
        {
            builder.Append(Array.IndexOf(invalid, c) >= 0 ? '_' : c);
        }

        var label = builder.ToString().Trim('_', '.', ' ');
        return label.Length == 0 ? "_" : label;
    }
}
