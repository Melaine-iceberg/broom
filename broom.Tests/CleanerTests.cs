using broom.Core;
using broom.Platform;
using broom.Services;

namespace broom.Tests;

public class CleanerTests
{
    private static RuleScanResult Target(CleanupRule rule, params ScannedFile[] files)
    {
        var result = new RuleScanResult { Rule = rule };
        foreach (var file in files)
        {
            result.Files.Add(file);
            result.TotalBytes += file.Size;
            result.ItemCount++;
        }

        return result;
    }

    private static readonly CleanupRule Rule1 = new() { Id = "r1", DisplayName = "r1", Paths = ["x"] };
    private static readonly CleanupRule Rule2 = new() { Id = "r2", DisplayName = "r2", Paths = ["y"] };

    [Fact]
    public async Task Clean_DeletesFilesAndCountsBytes()
    {
        using var dir = new TempDir();
        var a = dir.CreateFile("a.tmp", "aaa");
        var b = dir.CreateFile("b.tmp", "bbbb");

        var target = Target(Rule1, new ScannedFile(a, 3), new ScannedFile(b, 4));
        var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter());

        Assert.False(File.Exists(a));
        Assert.False(File.Exists(b));
        Assert.Equal(2, report.Results[0].DeletedCount);
        Assert.Equal(7, report.Results[0].BytesRemoved);
        Assert.Empty(report.Results[0].Failures);
    }

    [Fact]
    public async Task Clean_LockedFileIsReportedAndNotCounted()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var dir = new TempDir();
        var ok = dir.CreateFile("ok.tmp", "aaa");
        var locked = dir.CreateFile("locked.tmp", "bbbb");

        RuleScanResult target;
        using (new FileStream(locked, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            target = Target(Rule1, new ScannedFile(ok, 3), new ScannedFile(locked, 4));
            var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter());

            Assert.Equal(1, report.Results[0].DeletedCount);
            Assert.Equal(3, report.Results[0].BytesRemoved);
            Assert.Single(report.Results[0].Failures);
            Assert.Equal(locked, report.Results[0].Failures[0].Path);
            Assert.True(File.Exists(locked));
        }
    }

    /// <summary>删除第一个文件后触发取消,模拟"清理到一半被用户取消"。</summary>
    private sealed class DeleteFirstThenCancel : IFileDeleter
    {
        private readonly CancellationTokenSource _cts;

        public DeleteFirstThenCancel(CancellationTokenSource cts) => _cts = cts;

        public string Name => "测试删除器";

        public int Delete(IReadOnlyList<string> paths, IDictionary<string, string> failures, CancellationToken ct = default)
        {
            if (paths.Count == 0)
            {
                return 0;
            }

            File.Delete(paths[0]);
            _cts.Cancel();
            return 1;
        }
    }

    [Fact]
    public async Task Clean_PreCancelledToken_ThrowsCancellation()
    {
        using var dir = new TempDir();
        var file = dir.CreateFile("a.tmp", "aaa");
        var target = Target(Rule1, new ScannedFile(file, 3));
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        // 任务尚未开始就被取消:与界面层的 catch (OperationCanceledException) 对应
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => new Cleaner().CleanAsync([target], new PermanentFileDeleter(), ct: cts.Token));
    }

    [Fact]
    public async Task Clean_CancelMidwayKeepsFinishedPartsAndSkipsRest()
    {
        using var dir = new TempDir();
        var first = dir.CreateFile("first.tmp", "aaa");
        var second = dir.CreateFile("second.tmp", "bbbb");
        var target1 = Target(Rule1, new ScannedFile(first, 3));
        var target2 = Target(Rule2, new ScannedFile(second, 4));
        using var cts = new CancellationTokenSource();

        var report = await new Cleaner().CleanAsync([target1, target2], new DeleteFirstThenCancel(cts), ct: cts.Token);

        Assert.True(report.WasCancelled);
        Assert.Single(report.Results);
        Assert.Equal(1, report.Results[0].DeletedCount);
        Assert.Equal(3, report.Results[0].BytesRemoved);
        Assert.Equal(new[] { Rule2 }, report.SkippedRules);
        Assert.False(File.Exists(first));
        Assert.True(File.Exists(second));
    }

    [Fact]
    public async Task Clean_SkipRecentDays_RechecksBeforeDeleting()
    {
        using var dir = new TempDir();
        // 扫描时是旧文件,清理前被重新写入
        var file = dir.CreateFile("touched.tmp", "aaa", DateTime.UtcNow.AddDays(-10));
        var target = Target(Rule1, new ScannedFile(file, 3));
        File.SetLastWriteTimeUtc(file, DateTime.UtcNow);

        var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter(), skipRecentDays: 7);

        Assert.True(File.Exists(file));
        Assert.Equal(0, report.Results[0].DeletedCount);
        Assert.Equal(0, report.Results[0].BytesRemoved);
    }

    [Fact]
    public async Task Clean_SkipRecentDays_DisabledDeletesNormally()
    {
        using var dir = new TempDir();
        var file = dir.CreateFile("touched.tmp", "aaa", DateTime.UtcNow.AddDays(-10));
        var target = Target(Rule1, new ScannedFile(file, 3));
        File.SetLastWriteTimeUtc(file, DateTime.UtcNow);

        var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter());

        Assert.False(File.Exists(file));
        Assert.Equal(1, report.Results[0].DeletedCount);
    }

    [Fact]
    public async Task Clean_WholeDirectoryRule_RemovesEmptySubdirectories()
    {
        using var dir = new TempDir();
        var sub = dir.CreateDir("sub");
        var file = dir.CreateFile(Path.Combine("sub", "a.tmp"), "aaa");
        var rule = new CleanupRule { Id = "whole", DisplayName = "whole", Paths = [dir.FullPath] };
        var target = Target(rule, new ScannedFile(file, 3));
        target.Roots.Add(dir.FullPath);

        await new Cleaner().CleanAsync([target], new PermanentFileDeleter());

        Assert.False(Directory.Exists(sub));
        Assert.True(Directory.Exists(dir.FullPath));
    }
}
