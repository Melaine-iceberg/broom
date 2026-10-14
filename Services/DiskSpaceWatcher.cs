using broom.Core;

using broom.Localization;
namespace broom.Services;

/// <summary>低磁盘空间提醒。</summary>
public readonly record struct LowDiskAlert(string Drive, long FreeBytes, long ThresholdBytes)
{
    public string Message =>
        Strings.M($"磁盘 {Drive.TrimEnd('\\', '/')} 可用空间仅剩 {Formatting.FormatBytes(FreeBytes)}(低于阈值 {Formatting.FormatBytes(ThresholdBytes)})");
}

/// <summary>
/// 磁盘空间看门狗:固定磁盘可用空间低于阈值(设置项)时提醒;
/// 每块盘只提醒一次,空间恢复到阈值以上后重新武装,再次跌破会再提醒。
/// </summary>
public sealed class DiskSpaceWatcher : IDisposable
{
    private static readonly TimeSpan DefaultCheckInterval = TimeSpan.FromMinutes(10);

    private readonly Func<BroomSettings> _settingsProvider;
    private readonly Action<LowDiskAlert> _onAlert;
    private readonly Func<string, long?>? _probe;
    private readonly HashSet<string> _alerted = new(StringComparer.OrdinalIgnoreCase);
    private readonly Timer _timer;
    private readonly object _gate = new();

    public DiskSpaceWatcher(
        Func<BroomSettings> settingsProvider,
        Action<LowDiskAlert> onAlert,
        Func<string, long?>? probe = null,
        TimeSpan? checkInterval = null)
    {
        _settingsProvider = settingsProvider;
        _onAlert = onAlert;
        _probe = probe;
        _timer = new Timer(_ => CheckNow(), null, TimeSpan.FromSeconds(5), checkInterval ?? DefaultCheckInterval);
    }

    /// <summary>低于阈值的盘(纯计算,便于测试)。</summary>
    public static List<LowDiskAlert> FindLowDisks(IReadOnlyList<KeyValuePair<string, long?>> driveSpace, long thresholdBytes)
    {
        var alerts = new List<LowDiskAlert>();
        foreach (var (drive, freeBytes) in driveSpace)
        {
            if (freeBytes is { } free && free < thresholdBytes)
            {
                alerts.Add(new LowDiskAlert(drive, free, thresholdBytes));
            }
        }

        return alerts;
    }

    /// <summary>立即检查一次(定时器之外的手动入口)。</summary>
    public void CheckNow()
    {
        try
        {
            var settings = _settingsProvider();
            if (settings.LowDiskThresholdGb <= 0)
            {
                return;
            }

            var thresholdBytes = settings.LowDiskThresholdGb * 1024L * 1024L * 1024L;
            var drives = ListFixedDrives();
            var alerts = FindLowDisks(drives, thresholdBytes);

            lock (_gate)
            {
                // 恢复到阈值以上的盘重新武装,之后跌破阈值会再次提醒
                foreach (var (drive, _) in drives)
                {
                    if (alerts.All(a => !string.Equals(a.Drive.TrimEnd('\\', '/'), drive.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase)))
                    {
                        _alerted.Remove(drive.TrimEnd('\\', '/'));
                    }
                }

                foreach (var alert in alerts.Where(a => _alerted.Add(a.Drive.TrimEnd('\\', '/'))))
                {
                    _onAlert(alert);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            // 检查失败(如光驱 / 网络盘抖动)不影响应用,留待下一个周期
        }
    }

    private List<KeyValuePair<string, long?>> ListFixedDrives()
    {
        if (_probe is not null)
        {
            return ProbeAll(DriveInfo.GetDrives().Select(d => d.Name));
        }

        var result = new List<KeyValuePair<string, long?>>();
        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (drive.DriveType == DriveType.Fixed && drive.IsReady)
                {
                    result.Add(new KeyValuePair<string, long?>(drive.Name, drive.AvailableFreeSpace));
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
            {
                result.Add(new KeyValuePair<string, long?>(drive.Name, null));
            }
        }

        return result;
    }

    private List<KeyValuePair<string, long?>> ProbeAll(IEnumerable<string> driveNames)
        => driveNames.Select(name => new KeyValuePair<string, long?>(name, _probe!(name))).ToList();

    public void Dispose() => _timer.Dispose();
}
