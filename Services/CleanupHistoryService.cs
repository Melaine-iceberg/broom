using System.Text.Json;
using broom.Core;

namespace broom.Services;

/// <summary>
/// 清理历史:每次清理向 history.json(目录见 <see cref="AppPaths.DataDirectory"/>)追加一条记录
/// (时间、来源、条目数、字节数、逐条规则)。
/// 文件损坏时改名为 history.bad.json 并从空历史重新开始,不影响清理本身。
/// 超过 <see cref="MaxEntries"/> 条时丢弃最旧的记录,避免文件无限增长。
/// </summary>
public sealed class CleanupHistoryService
{
    /// <summary>历史记录上限;超出后丢弃最旧记录。</summary>
    public const int MaxEntries = 500;

    private static readonly object FileLock = new();

    private readonly string _directory;
    private readonly string _filePath;

    /// <param name="directory">历史目录;留空时使用 <see cref="AppPaths.DataDirectory"/>(测试可注入临时目录隔离)。</param>
    public CleanupHistoryService(string? directory = null)
    {
        _directory = directory ?? AppPaths.DataDirectory;
        _filePath = Path.Combine(_directory, "history.json");
    }

    public string FilePath => _filePath;

    /// <summary>读取全部历史记录(按时间从旧到新);文件不存在时返回空列表。</summary>
    public List<CleanupHistoryEntry> Load()
    {
        lock (FileLock)
        {
            try
            {
                if (!File.Exists(_filePath))
                {
                    return [];
                }

                var json = File.ReadAllText(_filePath);
                return JsonSerializer.Deserialize(json, BroomJsonContext.Default.ListCleanupHistoryEntry) ?? [];
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
            {
                TryBackupCorruptedFile();
                return [];
            }
        }
    }

    /// <summary>追加一条记录并立即落盘;历史损坏时从空记录重新开始。</summary>
    public void Append(CleanupHistoryEntry entry)
    {
        lock (FileLock)
        {
            var entries = Load();
            entries.Add(entry);
            if (entries.Count > MaxEntries)
            {
                entries.RemoveRange(0, entries.Count - MaxEntries);
            }

            Directory.CreateDirectory(_directory);
            var json = JsonSerializer.Serialize(entries, BroomJsonContext.Default.ListCleanupHistoryEntry);
            File.WriteAllText(_filePath, json);
        }
    }

    /// <summary>累计统计:清理次数、累计释放字节数与累计删除条目数。</summary>
    public HistoryTotals GetTotals()
    {
        var entries = Load();
        return new HistoryTotals(entries.Count, entries.Sum(e => e.BytesRemoved), entries.Sum(e => e.ItemCount));
    }

    private void TryBackupCorruptedFile()
    {
        try
        {
            File.Move(_filePath, Path.Combine(_directory, "history.bad.json"), overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 备份失败不影响从空历史重新开始
        }
    }
}

/// <summary>历史累计统计。</summary>
public readonly record struct HistoryTotals(int CleanCount, long TotalBytes, int TotalItems);
