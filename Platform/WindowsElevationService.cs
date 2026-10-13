using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.Versioning;
using System.Security.Principal;

namespace broom.Platform;

/// <summary>Windows 实现:通过进程令牌判断提权状态,通过 Shell 的 runas 动词请求提权重启。</summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsElevationService : IElevationService
{
    public bool IsElevated
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    public bool TryRestartElevated(out string? error)
    {
        var processPath = Environment.ProcessPath;
        if (string.IsNullOrEmpty(processPath))
        {
            error = "提权重启失败:无法确定当前程序路径。";
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo(processPath)
            {
                UseShellExecute = true,
                Verb = "runas",
            });
            error = null;
            return true;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // 用户在 UAC 对话框中选择了“否”
            error = "已取消提权。";
            return false;
        }
        catch (Exception ex)
        {
            error = $"提权重启失败:{ex.Message}";
            return false;
        }
    }
}
