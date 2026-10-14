using broom.Core;
using broom.Services;

namespace broom.Tests;

public class ScannerTests
{
    private static CleanupRule RuleFor(string dir, string[]? include = null, string[]? exclude = null) => new()
    {
        Id = "test",
        DisplayName = "test",
        Paths = [dir],
        IncludePatterns = include ?? ["*"],
        ExcludePatterns = exclude ?? [],
    };

    [Fact]
    public async Task IncludePatterns_KeepOnlyMatchingFileNames()
    {
        using var dir = new TempDir();
        dir.CreateFile("a.txt");
        dir.CreateFile("b.log");
        dir.CreateFile("c.log");

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath, include: ["*.log"])]);

        Assert.Equal(2, results[0].ItemCount);
        Assert.All(results[0].Files, f => Assert.EndsWith(".log", f.Path));
    }

    [Fact]
    public async Task ExcludePatterns_TakePrecedenceOverInclude()
    {
        using var dir = new TempDir();
        dir.CreateFile("keep.log");
        dir.CreateFile("skip.log");

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath, include: ["*.log"], exclude: ["skip*"])]);

        Assert.Equal(1, results[0].ItemCount);
        Assert.EndsWith("keep.log", results[0].Files[0].Path);
    }

    [Fact]
    public async Task Scan_IsRecursiveIntoSubdirectories()
    {
        using var dir = new TempDir();
        dir.CreateFile("top.tmp");
        dir.CreateFile(Path.Combine("sub", "nested", "deep.tmp"));

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath)]);

        Assert.Equal(2, results[0].ItemCount);
    }

    [Fact]
    public async Task ExcludedPaths_MatchOnDirectorySegmentBoundary()
    {
        using var dir = new TempDir();
        var excludedDir = dir.CreateDir("Temp");
        dir.CreateFile(Path.Combine("Temp", "a.tmp"));
        dir.CreateFile(Path.Combine("Temp2", "b.tmp"));

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath)], excludedPaths: [excludedDir]);

        // 排除 Temp 不应误伤 Temp2
        Assert.Equal(1, results[0].ItemCount);
        Assert.EndsWith("b.tmp", results[0].Files[0].Path);
    }

    [Fact]
    public async Task ExcludedFiles_MatchExactPath()
    {
        using var dir = new TempDir();
        var keep = dir.CreateFile("keep.tmp");
        dir.CreateFile("other.tmp");

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath)], excludedFiles: [keep]);

        Assert.Equal(1, results[0].ItemCount);
        Assert.DoesNotContain(results[0].Files, f => f.Path == keep);
    }

    [Fact]
    public async Task SkipRecentDays_FiltersRecentlyModifiedFiles()
    {
        using var dir = new TempDir();
        var old = dir.CreateFile("old.tmp", "x", DateTime.UtcNow.AddDays(-10));
        dir.CreateFile("fresh.tmp", "y", DateTime.UtcNow);

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath)], skipRecentDays: 7);

        Assert.Equal(1, results[0].ItemCount);
        Assert.Equal(old, results[0].Files[0].Path);
    }

    [Fact]
    public async Task SkipRecentDays_DisabledKeepsAllFiles()
    {
        using var dir = new TempDir();
        dir.CreateFile("old.tmp", "x", DateTime.UtcNow.AddDays(-10));
        dir.CreateFile("fresh.tmp", "y", DateTime.UtcNow);

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath)]);

        Assert.Equal(2, results[0].ItemCount);
    }

    [Fact]
    public async Task SkipRecentDays_SkippedFilesDoNotCountTowardSize()
    {
        using var dir = new TempDir();
        dir.CreateFile("old.tmp", "x", DateTime.UtcNow.AddDays(-10));
        dir.CreateFile("fresh.tmp", new string('y', 200), DateTime.UtcNow);

        var results = await new Scanner().ScanAsync([RuleFor(dir.FullPath)], skipRecentDays: 7);

        Assert.Equal(1, results[0].TotalBytes);
    }

    [Fact]
    public async Task ActionRule_ReportsNoFilesWithoutError()
    {
        var rule = new CleanupRule
        {
            Id = "act",
            DisplayName = "动作项",
            Kind = RuleKind.Action,
            Action = CleanupAction.FlushDnsCache,
            Paths = [],
        };

        var results = await new Scanner().ScanAsync([rule]);

        var result = Assert.Single(results);
        Assert.Empty(result.Files);
        Assert.Equal(0, result.ItemCount);
        Assert.Empty(result.Errors);
    }

    [Fact]
    public async Task MissingPath_YieldsEmptyResultWithoutError()
    {
        using var dir = new TempDir();
        var rule = RuleFor(Path.Combine(dir.FullPath, "does-not-exist"));

        var results = await new Scanner().ScanAsync([rule]);

        Assert.Equal(0, results[0].ItemCount);
        Assert.Empty(results[0].Errors);
        Assert.Empty(results[0].Roots);
    }

    [Fact]
    public async Task PathPointingToSingleFile_IsScannedDirectly()
    {
        using var dir = new TempDir();
        var file = dir.CreateFile("single.tmp", "abc");
        var rule = new CleanupRule { Id = "test", DisplayName = "test", Paths = [file] };

        var results = await new Scanner().ScanAsync([rule]);

        Assert.Equal(1, results[0].ItemCount);
        Assert.Equal(file, results[0].Files[0].Path);
        Assert.Equal(3, results[0].TotalBytes);
    }
}
