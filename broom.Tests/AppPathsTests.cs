using broom.Core;

namespace broom.Tests;

/// <summary>便携模式数据目录解析:标记文件决定数据跟随 exe 还是进用户配置目录。</summary>
public class AppPathsTests
{
    [Fact]
    public void IsPortableMode_ReflectsMarkerFilePresence()
    {
        using var dir = new TempDir();

        Assert.False(AppPaths.IsPortableMode(dir.FullPath));

        File.WriteAllText(Path.Combine(dir.FullPath, AppPaths.PortableMarkerFileName), "");

        Assert.True(AppPaths.IsPortableMode(dir.FullPath));
    }

    [Fact]
    public void ResolveDataDirectory_WithMarker_ReturnsDataSubfolderBesideBase()
    {
        using var dir = new TempDir();
        File.WriteAllText(Path.Combine(dir.FullPath, AppPaths.PortableMarkerFileName), "");

        var resolved = AppPaths.ResolveDataDirectory(dir.FullPath);

        Assert.Equal(Path.Combine(dir.FullPath, "data"), resolved);
    }

    [Fact]
    public void ResolveDataDirectory_WithoutMarker_ReturnsAppDataBroom()
    {
        using var dir = new TempDir();

        var resolved = AppPaths.ResolveDataDirectory(dir.FullPath);

        Assert.Equal(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "broom"),
            resolved);
    }

    [Fact]
    public void ResolveQuarantineDirectory_WithMarker_ReturnsQuarantineUnderData()
    {
        using var dir = new TempDir();
        File.WriteAllText(Path.Combine(dir.FullPath, AppPaths.PortableMarkerFileName), "");

        var resolved = AppPaths.ResolveQuarantineDirectory(dir.FullPath);

        Assert.Equal(Path.Combine(dir.FullPath, "data", "quarantine"), resolved);
    }

    [Fact]
    public void ResolveQuarantineDirectory_WithoutMarker_ReturnsLocalAppDataQuarantine()
    {
        using var dir = new TempDir();

        var resolved = AppPaths.ResolveQuarantineDirectory(dir.FullPath);

        Assert.Equal(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "broom", "quarantine"),
            resolved);
    }
}
