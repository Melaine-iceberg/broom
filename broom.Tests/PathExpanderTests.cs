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
        var template = Path.Combine("%TEMP%", Path.GetFileName(dir.FullPath));

        Assert.Equal(new[] { dir.FullPath }, PathExpander.Expand(template).ToList());
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
