namespace broom.Platform;

/// <summary>平台服务工厂:按当前操作系统选择合适的实现。</summary>
public static class PlatformServices
{
    public static IElevationService CreateElevationService()
    {
        if (OperatingSystem.IsWindows())
        {
            return new WindowsElevationService();
        }

        return new UnsupportedElevationService();
    }

    public static IRebootDeleteService CreateRebootDeleteService()
    {
        if (OperatingSystem.IsWindows())
        {
            return new WindowsRebootDeleteService();
        }

        return new UnsupportedRebootDeleteService();
    }
}

/// <summary>非 Windows 平台:不支持管理员提权。</summary>
public sealed class UnsupportedElevationService : IElevationService
{
    public bool IsElevated => false;

    public bool TryRestartElevated(out string? error)
    {
        error = "当前平台暂不支持以管理员身份重启。";
        return false;
    }
}

/// <summary>非 Windows 平台:不支持重启后删除。</summary>
public sealed class UnsupportedRebootDeleteService : IRebootDeleteService
{
    public bool IsSupported => false;

    public bool TrySchedule(string path, out string error)
    {
        error = "当前平台暂不支持重启后删除。";
        return false;
    }
}
