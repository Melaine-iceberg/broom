using System.ComponentModel;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace broom.Platform;

/// <summary>
/// Windows Shell 互操作:移入回收站、清空回收站、登记重启后删除。
/// Shell API 约定在 STA 线程上调用,这里统一通过 <see cref="RunSta{T}"/> 切换到专用 STA 线程。
/// </summary>
[SupportedOSPlatform("windows")]
internal static class WindowsShell
{
    private const uint FO_DELETE = 0x0003;

    private const ushort FOF_SILENT = 0x0004;
    private const ushort FOF_NOCONFIRMATION = 0x0010;
    private const ushort FOF_ALLOWUNDO = 0x0040;
    private const ushort FOF_NOERRORUI = 0x0400;

    private const uint SHERB_NOCONFIRMATION = 0x00000001;
    private const uint SHERB_NOPROGRESSUI = 0x00000002;
    private const uint SHERB_NOSOUND = 0x00000004;

    private const uint MOVEFILE_DELAY_UNTIL_REBOOT = 0x00000004;

    public static bool DeleteToRecycleBin(IReadOnlyList<string> paths, out string error)
    {
        var op = new SHFILEOPSTRUCTW
        {
            wFunc = FO_DELETE,
            // pFrom 是以双 null 结尾的路径列表
            pFrom = string.Join('\0', paths) + '\0',
            fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT,
        };

        var hr = SHFileOperationW(ref op);
        if (hr != 0)
        {
            error = $"Shell 错误码 0x{hr:X8}";
            return false;
        }

        if (op.fAnyOperationsAborted)
        {
            error = "部分文件被占用,操作被中止";
            return false;
        }

        error = "";
        return true;
    }

    public static bool EmptyRecycleBin(out string error)
    {
        var hr = SHEmptyRecycleBinW(IntPtr.Zero, null, SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND);
        if (hr < 0)
        {
            error = $"Shell 错误码 0x{hr:X8}";
            return false;
        }

        error = "";
        return true;
    }

    /// <summary>
    /// 登记文件在下次重启时删除(写入注册表 PendingFileRenameOperations)。
    /// 需要管理员权限;重启前文件不会被删除,也不释放空间。
    /// </summary>
    public static bool TryScheduleDeleteOnReboot(string path, out string error)
    {
        if (MoveFileExW(path, null, MOVEFILE_DELAY_UNTIL_REBOOT))
        {
            error = "";
            return true;
        }

        error = new Win32Exception(Marshal.GetLastPInvokeError()).Message;
        return false;
    }

    public static T RunSta<T>(Func<T> action)
    {
        T result = default!;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                result = action();
            }
            catch (Exception ex)
            {
                failure = ex;
            }
        })
        {
            IsBackground = true,
        };

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        if (failure is not null)
        {
            ExceptionDispatchInfo.Capture(failure).Throw();
        }

        return result;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCTW
    {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string? pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperationW(ref SHFILEOPSTRUCTW lpFileOp);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHEmptyRecycleBinW(IntPtr hwnd, string? pszRootPath, uint dwFlags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileExW(string lpExistingFileName, string? lpNewFileName, uint dwFlags);
}
