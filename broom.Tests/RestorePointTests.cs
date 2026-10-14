using System.Runtime.InteropServices;
using broom.Platform;

namespace broom.Tests;

public class RestorePointTests
{
    [Fact]
    public void RestorePointInfo_MatchesNativeLayout()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        // RESTOREPOINTINFOW:4 + 4 + 8 + 256*2 = 528 字节
        Assert.Equal(528, Marshal.SizeOf<WindowsRestorePointService.RestorePointInfo>());
    }

    [Fact]
    public void StateManagerStatus_MatchesNativeLayout()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        // STATEMGRSTATUS:4 + 对齐 + 8 = 16 字节
        Assert.Equal(16, Marshal.SizeOf<WindowsRestorePointService.StateManagerStatus>());
    }

    [Fact]
    public void UnsupportedService_ReportsNotSupported()
    {
        var ok = new UnsupportedRestorePointService().TryCreateRestorePoint("x", out var error);

        Assert.False(ok);
        Assert.NotEmpty(error);
    }

    [Fact]
    public void Factory_ReturnsWindowsImplementationOnWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        Assert.IsType<WindowsRestorePointService>(PlatformServices.CreateRestorePointService());
    }
}
