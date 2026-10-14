using System.Runtime.InteropServices;

namespace broom.Tests;

/// <summary>测试用临时目录:每个测试独立一份,释放时整个删除。</summary>
internal sealed class TempDir : IDisposable
{
    public TempDir()
    {
        FullPath = Path.Combine(Path.GetTempPath(), "broom-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(FullPath);
    }

    public string FullPath { get; }

    public string CreateDir(string name)
    {
        var path = Path.Combine(FullPath, name);
        Directory.CreateDirectory(path);
        return path;
    }

    public string CreateFile(string name, string content = "x", DateTime? lastWriteUtc = null)
    {
        var path = Path.Combine(FullPath, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        if (lastWriteUtc is not null)
        {
            File.SetLastWriteTimeUtc(path, lastWriteUtc.Value);
        }

        return path;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(FullPath, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>测试专用 Win32 声明;硬链接用于观察"覆写后删除"是否真的覆盖了内容。</summary>
internal static class NativeTest
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);
}
