using System.Security.Cryptography;

namespace broom.Platform;

/// <summary>安全擦除:删除前用随机数据覆写文件内容,降低事后恢复的可行性。</summary>
internal static class SecureErase
{
    private const int BufferSize = 64 * 1024;

    /// <summary>
    /// 用随机数据覆写 <paramref name="passes"/> 次后删除文件(0 字节文件直接删除)。
    /// 覆写或删除失败时抛出异常,文件保持原样 —— 调用方负责把它计入失败列表,不回退为不覆写直接删。
    /// </summary>
    public static void OverwriteAndDelete(string path, int passes)
    {
        var length = new FileInfo(path).Length;
        if (length > 0)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None))
            {
                var buffer = new byte[BufferSize];
                for (var pass = 0; pass < passes; pass++)
                {
                    stream.Position = 0;
                    long written = 0;
                    while (written < length)
                    {
                        var count = (int)Math.Min(buffer.Length, length - written);
                        RandomNumberGenerator.Fill(buffer.AsSpan(0, count));
                        stream.Write(buffer, 0, count);
                        written += count;
                    }

                    // 尽量落盘,减少内容滞留在写缓存中的可能
                    stream.Flush(true);
                }
            }
        }

        File.Delete(path);
    }
}
