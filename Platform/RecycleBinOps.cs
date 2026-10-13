using System.Runtime.Versioning;

namespace broom.Platform;

/// <summary>清空回收站 —— 这是不可逆操作,调用后文件无法再恢复。</summary>
[SupportedOSPlatform("windows")]
public static class RecycleBinOps
{
    public static bool TryEmpty(out string error)
    {
        var message = "";
        var ok = WindowsShell.RunSta(() =>
        {
            var result = WindowsShell.EmptyRecycleBin(out var shellError);
            message = shellError;
            return result;
        });

        error = message;
        return ok;
    }
}
