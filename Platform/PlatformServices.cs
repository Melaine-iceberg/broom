using broom.Core;

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

    public static IRestorePointService CreateRestorePointService()
    {
        if (OperatingSystem.IsWindows())
        {
            return new WindowsRestorePointService();
        }

        return new UnsupportedRestorePointService();
    }

    public static ICleanupActionService CreateCleanupActionService()
    {
        if (OperatingSystem.IsWindows())
        {
            return new WindowsCleanupActionService();
        }

        return new UnsupportedCleanupActionService();
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

/// <summary>非 Windows 平台:不支持系统还原点。</summary>
public sealed class UnsupportedRestorePointService : IRestorePointService
{
    public bool TryCreateRestorePoint(string description, out string error)
    {
        error = "当前平台暂不支持系统还原点。";
        return false;
    }
}

/// <summary>非 Windows 平台:动作型清理暂不支持。</summary>
public sealed class UnsupportedCleanupActionService : ICleanupActionService
{
    public bool IsSupported(CleanupAction action) => false;

    public CleanupActionResult Execute(CleanupAction action, IProgress<string>? progress = null, CancellationToken ct = default)
        => new() { Success = false, Error = "当前平台暂不支持该清理动作。" };
}
