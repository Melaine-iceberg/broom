using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace broom.Platform;

/// <summary>
/// Windows 系统还原点:通过 srclient.dll 的 SRSetRestorePointW 创建,
/// 与「系统属性 → 系统保护 → 创建」走同一条 API。需要管理员权限与已开启的系统保护。
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsRestorePointService : IRestorePointService
{
    private const int BeginSystemChange = 100;
    private const int ModifySettings = 12;

    /// <summary>szDescription 为 256 个字符(含结尾空字符),有效描述最长 255。</summary>
    private const int MaxDescriptionLength = 255;

    public bool TryCreateRestorePoint(string description, out string error)
    {
        var spec = new RestorePointInfo
        {
            EventType = BeginSystemChange,
            RestorePtType = ModifySettings,
            SequenceNumber = 0,
            Description = Truncate(description),
        };
        var status = new StateManagerStatus();

        var ok = SRSetRestorePointW(ref spec, ref status);
        var code = status.Status != 0 ? status.Status : (ok ? 0 : Marshal.GetLastPInvokeError());
        if (ok && code == 0)
        {
            error = "";
            return true;
        }

        error = code switch
        {
            5 => "需要管理员权限。",
            1058 => "系统保护未开启(可在「系统属性 → 系统保护」中为系统盘启用)。",
            _ => $"系统返回错误码 {code}。",
        };
        return false;
    }

    private static string Truncate(string description) =>
        description.Length <= MaxDescriptionLength ? description : description[..MaxDescriptionLength];

    /// <summary>RESTOREPOINTINFOW。</summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct RestorePointInfo
    {
        public int EventType;
        public int RestorePtType;
        public long SequenceNumber;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MaxDescriptionLength + 1)]
        public string Description;
    }

    /// <summary>STATEMGRSTATUS。</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct StateManagerStatus
    {
        public int Status;
        public long SequenceNumber;
    }

    [DllImport("srclient.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SRSetRestorePointW(ref RestorePointInfo pRestorePtSpec, ref StateManagerStatus pSMStatus);
}
