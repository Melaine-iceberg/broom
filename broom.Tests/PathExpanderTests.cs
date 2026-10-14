using broom.Core;

namespace broom.Tests;

public class PathExpanderTests
{
    [Fact]
    public void Expand_ExistingDirectory_IsReturned()
    {
        using var dir = new TempDir();
        var sub = dir.CreateDir("sub");

        Assert.Equal(new[] { sub }, PathExpander.Expand(sub).ToList());
    }

    [Fact]
    public void Expand_MissingPath_YieldsNothing()
    {
        using var dir = new TempDir();

        Assert.Empty(PathExpander.Expand(Path.Combine(dir.FullPath, "nope")));
    }

    [Fact]
    public void Expand_EnvironmentVariables_AreResolved()
    {
        using var dir = new TempDir();
        var sub = dir.CreateDir("sub");

        // 不用 %TEMP% 之类的系统变量:CI 上它们可能是 8.3 短路径(如 RUNNER~1),
        // 与 GetTempPath 的长路径表示不一致;自定义变量让断言只验证展开行为本身。
        Environment.SetEnvironmentVariable("BROOM_TEST_ROOT", dir.FullPath);
        try
        {
            Assert.Equal(new[] { sub }, PathExpander.Expand(Path.Combine("%BROOM_TEST_ROOT%", "sub")).ToList());
        }
        finally
        {
            Environment.SetEnvironmentVariable("BROOM_TEST_ROOT", null);
        }
    }

    [Fact]
    public void Expand_Wildcard_MatchesAllBranches()
    {
        using var dir = new TempDir();
        var a = dir.CreateDir(Path.Combine("apps", "a", "cache"));
        var b = dir.CreateDir(Path.Combine("apps", "b", "cache"));
        dir.CreateDir(Path.Combine("apps", "c", "other"));

        var expanded = PathExpander.Expand(Path.Combine(dir.FullPath, "apps", "*", "cache")).ToList();

        Assert.Equal(2, expanded.Count);
        Assert.Contains(a, expanded);
        Assert.Contains(b, expanded);
    }

    [Fact]
    public void Expand_WildcardWithoutMatch_YieldsNothing()
    {
        using var dir = new TempDir();
        dir.CreateDir(Path.Combine("apps", "a"));

        Assert.Empty(PathExpander.Expand(Path.Combine(dir.FullPath, "apps", "*", "cache")));
    }
}
