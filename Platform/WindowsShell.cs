using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace broom.Platform;

/// <summary>
/// Windows Shell 互操作:移入回收站、查询/清空回收站、登记重启后删除。
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

    /// <summary>回收站为空(或只剩 Shell 不管理的孤立残留)时 SHEmptyRecycleBin 的既定义返回值,不是错误。</summary>
    private const int E_UNEXPECTED = unchecked((int)0x8000FFFF);

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

    /// <summary>查询当前用户回收站的占用空间与项数 —— 与资源管理器展示的内容一致(不含孤立残留)。</summary>
    public static bool TryQueryRecycleBin(out long size, out long itemCount, out string error)
    {
        var info = new SHQUERYRBINFO { cbSize = Marshal.SizeOf<SHQUERYRBINFO>() };
        var hr = SHQueryRecycleBinW(null, ref info);
        if (hr < 0)
        {
            size = 0;
            itemCount = 0;
            error = $"Shell 错误码 0x{hr:X8}";
            return false;
        }

        size = info.i64Size;
        itemCount = info.i64NumItems;
        error = "";
        return true;
    }

    /// <summary>清空回收站,并通过前后查询得到实际清除的项数与字节数。</summary>
    public static bool EmptyRecycleBin(out int itemsRemoved, out long bytesFreed, out string error)
    {
        itemsRemoved = 0;
        bytesFreed = 0;

        if (!TryQueryRecycleBin(out var bytesBefore, out var itemsBefore, out var queryError))
        {
            error = queryError;
            return false;
        }

        // 查询为空时不再调用 SHEmptyRecycleBin,避免撞上 E_UNEXPECTED
        if (itemsBefore > 0)
        {
            var hr = SHEmptyRecycleBinW(IntPtr.Zero, null, SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND);
            if (hr < 0 && hr != E_UNEXPECTED)
            {
                error = $"Shell 错误码 0x{hr:X8}";
                return false;
            }
        }

        // 以重新查询的结果为准:被占用而清不掉的项会留在回收站里
        if (TryQueryRecycleBin(out var bytesAfter, out var itemsAfter, out _))
        {
            itemsRemoved = (int)Math.Max(0, itemsBefore - itemsAfter);
            bytesFreed = Math.Max(0, bytesBefore - bytesAfter);

            if (itemsAfter > 0)
            {
                error = $"仍有 {itemsAfter:N0} 项未能清空(可能被占用)。";
                return false;
            }
        }
        else
        {
            itemsRemoved = (int)Math.Min(itemsBefore, int.MaxValue);
            bytesFreed = bytesBefore;
        }

        error = "";
        return true;
    }

    /// <summary>在资源管理器中定位并选中指定文件。</summary>
    public static bool TryRevealInExplorer(string path, out string error)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"")
            {
                UseShellExecute = true,
            });
            error = "";
            return true;
        }
        catch (Win32Exception ex)
        {
            error = ex.Message;
            return false;
        }
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

    [StructLayout(LayoutKind.Sequential)]
    private struct SHQUERYRBINFO
    {
        public int cbSize;
        public long i64Size;
        public long i64NumItems;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHEmptyRecycleBinW(IntPtr hwnd, string? pszRootPath, uint dwFlags);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHQueryRecycleBinW(string? pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileExW(string lpExistingFileName, string? lpNewFileName, uint dwFlags);
}
