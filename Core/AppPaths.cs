namespace broom.Core;

/// <summary>
/// 应用数据目录解析。默认写入用户配置目录;exe 同目录存在 <see cref="PortableMarkerFileName"/> 标记文件时
/// 进入便携模式,数据集中写入 exe 同目录的 data\ 子目录(设置、历史、隔离区),便于绿色目录 / U 盘携带。
/// </summary>
public static class AppPaths
{
    /// <summary>便携模式标记文件名:放在 broom.exe 同目录即启用便携模式。</summary>
    public const string PortableMarkerFileName = "portable.txt";

    /// <summary>设置与历史目录:便携模式为 exe 同目录 data\,否则 %APPDATA%\broom。</summary>
    public static string DataDirectory => ResolveDataDirectory(AppContext.BaseDirectory);

    /// <summary>隔离区根目录:便携模式为 exe 同目录 data\quarantine,否则 %LOCALAPPDATA%\broom\quarantine。</summary>
    public static string QuarantineDirectory => ResolveQuarantineDirectory(AppContext.BaseDirectory);

    /// <summary>指定目录(通常是 exe 所在目录)下是否有便携模式标记文件。</summary>
    public static bool IsPortableMode(string baseDirectory)
        => File.Exists(Path.Combine(baseDirectory, PortableMarkerFileName));

    /// <summary>按 exe 目录解析数据目录;标记文件存在时跟随 exe,否则用 %APPDATA%\broom。</summary>
    public static string ResolveDataDirectory(string baseDirectory)
        => IsPortableMode(baseDirectory)
            ? Path.Combine(baseDirectory, "data")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "broom");

    /// <summary>按 exe 目录解析隔离区目录;标记文件存在时跟随 exe,否则用 %LOCALAPPDATA%\broom\quarantine。</summary>
    public static string ResolveQuarantineDirectory(string baseDirectory)
        => IsPortableMode(baseDirectory)
            ? Path.Combine(baseDirectory, "data", "quarantine")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "broom", "quarantine");
}
