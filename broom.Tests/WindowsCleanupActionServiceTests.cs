using System.Runtime.Versioning;
using broom.Core;
using broom.Platform;

namespace broom.Tests;

[SupportedOSPlatform("windows")]
public class WindowsCleanupActionServiceTests
{
    /// <summary>同步进度收集器:<see cref="Progress{T}"/> 的回调是异步的,测试里会读写竞态。</summary>
    private sealed class SyncProgress : IProgress<string>
    {
        private readonly List<string> _lines = [];

        public void Report(string value)
        {
            lock (_lines)
            {
                _lines.Add(value);
            }
        }

        public List<string> Lines
        {
            get
            {
                lock (_lines)
                {
                    return [.. _lines];
                }
            }
        }
    }

    [Fact]
    public void RunProcess_Success_ReturnsSummaryAndForwardsOutput()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var progress = new SyncProgress();
        var result = WindowsCleanupActionService.RunProcess(
            "cmd.exe", "/c echo hello-from-broom", "测试动作", progress, CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal("测试动作完成", result.Summary);
        Assert.Contains(progress.Lines, l => l.Contains("hello-from-broom"));
    }

    [Fact]
    public void RunProcess_NonZeroExit_ReportsExitCode()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var result = WindowsCleanupActionService.RunProcess(
            "cmd.exe", "/c exit 5", "测试动作", null, CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("退出码 5", result.Error);
    }

    [Fact]
    public async Task RunProcess_Cancelled_KillsProcessAndThrows()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var cts = new CancellationTokenSource();
        var run = Task.Run(() => WindowsCleanupActionService.RunProcess(
            "cmd.exe", "/c ping -n 30 127.0.0.1 > nul", "测试动作", null, cts.Token));

        cts.CancelAfter(300);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
    }

    [Fact]
    public void IsSupported_KnownActions()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var service = new WindowsCleanupActionService();

        Assert.True(service.IsSupported(CleanupAction.FlushDnsCache));
        Assert.True(service.IsSupported(CleanupAction.ClearEventLogs));
        Assert.True(service.IsSupported(CleanupAction.DeleteShadowCopies));
        Assert.True(service.IsSupported(CleanupAction.CleanComponentStore));
    }

    [Fact]
    public void CountShadowCopies_CountsPerShadowDeviceOnce()
    {
        // 模拟 vssadmin list shadows 输出:卷 GUID({})不得被计数,只有 HarddiskVolumeShadowCopy 设备名计数
        const string output = """
            卷影副本 ID: {11111111-2222-3333-4444-555555555555}
               原始卷: (C:)\\?\Volume{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}\
               卷影副本卷: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy7
            卷影副本 ID: {99999999-2222-3333-4444-555555555555}
               原始卷: (C:)\\?\Volume{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}\
               卷影副本卷: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy12
            """;

        Assert.Equal(2, WindowsCleanupActionService.CountShadowCopies(output));
    }

    [Fact]
    public void CountShadowCopies_EmptyOutput_IsZero()
    {
        Assert.Equal(0, WindowsCleanupActionService.CountShadowCopies("No items found that satisfy the query."));
    }

    [Fact]
    public void TryRunCapture_Success_CapturesOutput()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var ok = WindowsCleanupActionService.TryRunCapture(
            "cmd.exe", "/c echo captured-line", out var output, out var error, CancellationToken.None);

        Assert.True(ok);
        Assert.Contains("captured-line", output);
        Assert.Equal("", error);
    }

    [Fact]
    public void TryRunCapture_NonZeroExit_ReportsExitCode()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var ok = WindowsCleanupActionService.TryRunCapture(
            "cmd.exe", "/c exit 7", out _, out var error, CancellationToken.None);

        Assert.False(ok);
        Assert.Contains("退出码 7", error);
    }
}
