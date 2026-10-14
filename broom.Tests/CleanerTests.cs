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

    [Fact]
    public async Task Clean_RecordsDiskSpaceDeltaForAffectedDrives()
    {
        using var dir = new TempDir();
        var file = dir.CreateFile("a.tmp", "aaa");
        var target = Target(Rule1, new ScannedFile(file, 3));
        var calls = 0;
        Func<string, long?> probe = _ => ++calls switch
        {
            1 => 1000,
            2 => 1400,
            _ => throw new InvalidOperationException("探针只应调用两次"),
        };

        var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter(), getFreeBytes: probe);

        var delta = Assert.Single(report.DriveSpace);
        Assert.Equal(Path.GetPathRoot(file), delta.Drive);
        Assert.Equal(1000, delta.FreeBefore);
        Assert.Equal(1400, delta.FreeAfter);
        Assert.Equal(400, delta.FreedBytes);
    }

    [Fact]
    public async Task Clean_UnreadableDriveSpace_SkipsComparison()
    {
        using var dir = new TempDir();
        var file = dir.CreateFile("a.tmp", "aaa");
        var target = Target(Rule1, new ScannedFile(file, 3));

        var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter(), getFreeBytes: _ => null);

        Assert.Empty(report.DriveSpace);
    }

    [Fact]
    public async Task Clean_CancelledStillRecordsDiskSpaceDelta()
    {
        using var dir = new TempDir();
        var first = dir.CreateFile("first.tmp", "aaa");
        var second = dir.CreateFile("second.tmp", "bbbb");
        var target1 = Target(Rule1, new ScannedFile(first, 3));
        var target2 = Target(Rule2, new ScannedFile(second, 4));
        using var cts = new CancellationTokenSource();
        var calls = 0;
        Func<string, long?> probe = _ => ++calls * 100;

        var report = await new Cleaner().CleanAsync(
            [target1, target2], new DeleteFirstThenCancel(cts), ct: cts.Token, getFreeBytes: probe);

        Assert.True(report.WasCancelled);
        var delta = Assert.Single(report.DriveSpace);
        Assert.Equal(100, delta.FreeBefore);
        Assert.Equal(200, delta.FreeAfter);
    }

    private static readonly CleanupRule ActionRule = new()
    {
        Id = "act",
        DisplayName = "动作项",
        Kind = RuleKind.Action,
        Action = CleanupAction.FlushDnsCache,
        Paths = [],
    };

    private sealed class FakeActions : ICleanupActionService
    {
        public Func<CleanupAction, CleanupActionResult>? OnExecute { get; init; }

        public bool Supported { get; init; } = true;

        public List<CleanupAction> Executed { get; } = [];

        public bool IsSupported(CleanupAction action) => Supported;

        public CleanupActionResult Execute(CleanupAction action, IProgress<string>? progress = null, CancellationToken ct = default)
        {
            Executed.Add(action);
            progress?.Report("执行中");
            return OnExecute?.Invoke(action) ?? new CleanupActionResult
            {
                Success = true,
                ItemsAffected = 2,
                BytesFreed = 10,
                Summary = "动作已完成",
            };
        }
    }

    private static RuleScanResult ActionTarget(CleanupRule rule) => new() { Rule = rule };

    [Fact]
    public async Task Clean_ActionRule_UsesActionServiceResult()
    {
        var actions = new FakeActions();

        var report = await new Cleaner().CleanAsync([ActionTarget(ActionRule)], new PermanentFileDeleter(), actionService: actions);

        var result = Assert.Single(report.Results);
        Assert.Equal([CleanupAction.FlushDnsCache], actions.Executed);
        Assert.Equal(2, result.DeletedCount);
        Assert.Equal(10, result.BytesRemoved);
        Assert.Equal("动作已完成", result.Summary);
        Assert.Empty(result.Failures);
    }

    [Fact]
    public async Task Clean_ActionRule_FailureRecordedWithReason()
    {
        var actions = new FakeActions
        {
            OnExecute = _ => new CleanupActionResult { Success = false, Error = "权限不足" },
        };

        var report = await new Cleaner().CleanAsync([ActionTarget(ActionRule)], new PermanentFileDeleter(), actionService: actions);

        var result = Assert.Single(report.Results);
        var failure = Assert.Single(result.Failures);
        Assert.Equal("权限不足", failure.Reason);
    }

    [Fact]
    public async Task Clean_ActionRule_PartialFailuresAreCopied()
    {
        var actions = new FakeActions
        {
            OnExecute = _ =>
            {
                var outcome = new CleanupActionResult { Success = true, ItemsAffected = 3, Summary = "已清空部分日志" };
                outcome.Failures.Add(new DeleteFailure("<日志:Security>", "拒绝访问"));
                return outcome;
            },
        };

        var report = await new Cleaner().CleanAsync([ActionTarget(ActionRule)], new PermanentFileDeleter(), actionService: actions);

        var result = Assert.Single(report.Results);
        Assert.Equal(3, result.DeletedCount);
        Assert.Equal("已清空部分日志", result.Summary);
        Assert.Equal("拒绝访问", Assert.Single(result.Failures).Reason);
    }

    [Fact]
    public async Task Clean_ActionRule_UnsupportedServiceFails()
    {
        var actions = new FakeActions { Supported = false };

        var report = await new Cleaner().CleanAsync([ActionTarget(ActionRule)], new PermanentFileDeleter(), actionService: actions);

        var result = Assert.Single(report.Results);
        Assert.Contains("暂不支持", Assert.Single(result.Failures).Reason);
        Assert.Empty(actions.Executed);
    }

    [Fact]
    public async Task Clean_ActionRule_MissingActionDefinitionFails()
    {
        var noAction = new CleanupRule { Id = "act2", DisplayName = "缺动作", Kind = RuleKind.Action, Paths = [] };

        var report = await new Cleaner().CleanAsync([ActionTarget(noAction)], new PermanentFileDeleter(), actionService: new FakeActions());

        Assert.Contains("缺少清理动作", Assert.Single(Assert.Single(report.Results).Failures).Reason);
    }

    [Fact]
    public async Task Clean_ActionRule_CancelledMarksActionCancelledAndSkipsRest()
    {
        using var cts = new CancellationTokenSource();
        var actions = new FakeActions
        {
            OnExecute = _ =>
            {
                cts.Cancel();
                throw new OperationCanceledException(cts.Token);
            },
        };
        var second = new RuleScanResult { Rule = Rule2, Roots = { "y" } };

        var report = await new Cleaner().CleanAsync(
            [ActionTarget(ActionRule), second], new PermanentFileDeleter(), ct: cts.Token, actionService: actions);

        Assert.True(report.WasCancelled);
        Assert.Equal("动作已取消", Assert.Single(report.Results).Summary);
        Assert.Equal([Rule2], report.SkippedRules);
    }

    [Fact]
    public async Task Clean_ActionRule_DiskComparisonCoversFixedDrives()
    {
        var calls = 0;
        Func<string, long?> probe = _ => ++calls * 100;

        var report = await new Cleaner().CleanAsync(
            [ActionTarget(ActionRule)], new PermanentFileDeleter(), getFreeBytes: probe, actionService: new FakeActions());

        Assert.NotEmpty(report.DriveSpace);
    }

    [Fact]
    public async Task Clean_RemoveEmptyDirectories_RemovesAndCounts()
    {
        using var dir = new TempDir();
        dir.CreateFile("keep.txt", "keep");
        dir.CreateFile(Path.Combine("sub1", "a.tmp"), "aaa");
        dir.CreateDir("sub2");
        dir.CreateDir(Path.Combine("sub3", "inner"));
        var rule = new CleanupRule { Id = "partial", DisplayName = "partial", Paths = [dir.FullPath], IncludePatterns = ["*.tmp"] };
        var target = Target(rule, new ScannedFile(Path.Combine(dir.FullPath, "sub1", "a.tmp"), 3));
        target.Roots.Add(dir.FullPath);

        var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter(), removeEmptyDirectories: true);

        Assert.False(Directory.Exists(Path.Combine(dir.FullPath, "sub1")));
        Assert.False(Directory.Exists(Path.Combine(dir.FullPath, "sub2")));
        Assert.False(Directory.Exists(Path.Combine(dir.FullPath, "sub3")));
        Assert.True(File.Exists(Path.Combine(dir.FullPath, "keep.txt")));
        Assert.Equal(4, report.EmptyDirectoriesRemoved);
    }

    [Fact]
    public async Task Clean_RemoveEmptyDirectories_DisabledKeepsEmptyDirectories()
    {
        using var dir = new TempDir();
        dir.CreateFile(Path.Combine("sub1", "a.tmp"), "aaa");
        dir.CreateDir("sub2");
        var rule = new CleanupRule { Id = "partial", DisplayName = "partial", Paths = [dir.FullPath], IncludePatterns = ["*.tmp"] };
        var target = Target(rule, new ScannedFile(Path.Combine(dir.FullPath, "sub1", "a.tmp"), 3));
        target.Roots.Add(dir.FullPath);

        var report = await new Cleaner().CleanAsync([target], new PermanentFileDeleter());

        Assert.True(Directory.Exists(Path.Combine(dir.FullPath, "sub1")));
        Assert.True(Directory.Exists(Path.Combine(dir.FullPath, "sub2")));
        Assert.Equal(0, report.EmptyDirectoriesRemoved);
    }
}
