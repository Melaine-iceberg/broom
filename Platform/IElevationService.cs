namespace broom.Platform;

/// <summary>
/// 管理员提权抽象:检测当前进程是否已提权,并可请求以管理员身份重启。
/// 非 Windows 平台由 <see cref="UnsupportedElevationService"/> 报告不支持。
/// </summary>
public interface IElevationService
{
    /// <summary>当前进程是否以管理员身份运行。</summary>
    bool IsElevated { get; }

    /// <summary>
    /// 以管理员身份重启应用。成功时新实例已启动(调用方应退出当前进程);
    /// 用户拒绝 UAC 时返回 false 并给出原因,当前进程继续运行。
    /// </summary>
    bool TryRestartElevated(out string? error);
}
