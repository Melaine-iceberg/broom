using System.Runtime.Versioning;

namespace broom.Platform;

/// <summary>Windows 实现:通过 MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT) 登记重启后删除。</summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsRebootDeleteService : IRebootDeleteService
{
    public bool IsSupported => true;

    public bool TrySchedule(string path, out string error) => WindowsShell.TryScheduleDeleteOnReboot(path, out error);
}
