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
