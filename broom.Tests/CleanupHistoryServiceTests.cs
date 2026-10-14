using broom.Core;
using broom.Services;

namespace broom.Tests;

public class CleanupHistoryServiceTests
{
    [Fact]
    public void Load_MissingFile_ReturnsEmpty()
    {
        using var dir = new TempDir();
        var service = new CleanupHistoryService(dir.FullPath);

        Assert.Empty(service.Load());
        Assert.Equal(0, service.GetTotals().CleanCount);
    }

    [Fact]
    public void AppendThenLoad_RoundTripsEntriesInOrder()
    {
        using var dir = new TempDir();
        var service = new CleanupHistoryService(dir.FullPath);
        var first = new CleanupHistoryEntry { TimestampUtc = new DateTime(2026, 10, 1, 2, 0, 0, DateTimeKind.Utc), ItemCount = 3, BytesRemoved = 1024 };
        var second = new CleanupHistoryEntry { TimestampUtc = new DateTime(2026, 10, 2, 2, 0, 0, DateTimeKind.Utc), ItemCount = 5, BytesRemoved = 2048, Source = CleanupHistoryEntry.SourceScheduled };

        service.Append(first);
        service.Append(second);

        var entries = service.Load();
        Assert.Equal(2, entries.Count);
        Assert.Equal(1024, entries[0].BytesRemoved);
        Assert.Equal(CleanupHistoryEntry.SourceManual, entries[0].Source);
        Assert.Equal(CleanupHistoryEntry.SourceScheduled, entries[1].Source);
        Assert.Equal(new DateTime(2026, 10, 2, 2, 0, 0, DateTimeKind.Utc), entries[1].TimestampUtc);
    }

    [Fact]
    public void GetTotals_SumsBytesItemsAndCount()
    {
        using var dir = new TempDir();
        var service = new CleanupHistoryService(dir.FullPath);
        service.Append(new CleanupHistoryEntry { ItemCount = 3, BytesRemoved = 100 });
        service.Append(new CleanupHistoryEntry { ItemCount = 4, BytesRemoved = 50 });

        var totals = service.GetTotals();

        Assert.Equal(2, totals.CleanCount);
        Assert.Equal(150, totals.TotalBytes);
        Assert.Equal(7, totals.TotalItems);
    }

    [Fact]
    public void Append_CorruptedFile_StartsFreshAndBacksUp()
    {
        using var dir = new TempDir();
        var service = new CleanupHistoryService(dir.FullPath);
        File.WriteAllText(service.FilePath, "{ not json");

        service.Append(new CleanupHistoryEntry { ItemCount = 1, BytesRemoved = 10 });

        Assert.True(File.Exists(Path.Combine(dir.FullPath, "history.bad.json")));
        var entries = service.Load();
        Assert.Single(entries);
        Assert.Equal(10, entries[0].BytesRemoved);
    }

    [Fact]
    public void Append_TrimsOldestBeyondMaxEntries()
    {
        using var dir = new TempDir();
        var service = new CleanupHistoryService(dir.FullPath);
        for (var i = 0; i < CleanupHistoryService.MaxEntries + 3; i++)
        {
            service.Append(new CleanupHistoryEntry { ItemCount = i, BytesRemoved = i });
        }

        var entries = service.Load();
        Assert.Equal(CleanupHistoryService.MaxEntries, entries.Count);
        Assert.Equal(3, entries[0].ItemCount);
        Assert.Equal(CleanupHistoryService.MaxEntries + 2, entries[^1].ItemCount);
    }

    [Fact]
    public void FromReport_MapsResultsAndTotals()
    {
        var rule = new CleanupRule { Id = "user-temp", DisplayName = "用户临时文件" };
        var report = new CleanupReport();
        var result = new RuleCleanResult { Rule = rule, BytesRemoved = 2048, DeletedCount = 7 };
        result.Failures.Add(new DeleteFailure(@"C:\a.txt", "占用"));
        report.Results.Add(result);

        var entry = CleanupHistoryEntry.FromReport(report, CleanupHistoryEntry.SourceCli);

        Assert.Equal(CleanupHistoryEntry.SourceCli, entry.Source);
        Assert.Equal(7, entry.ItemCount);
        Assert.Equal(2048, entry.BytesRemoved);
        Assert.Equal(1, entry.FailureCount);
        Assert.False(entry.WasCancelled);
        var item = Assert.Single(entry.Rules);
        Assert.Equal("user-temp", item.RuleId);
        Assert.Equal(7, item.Items);
        Assert.Equal(2048, item.Bytes);
    }
}
