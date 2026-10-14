using broom.Core;
using broom.Services;

namespace broom.Tests;

public class AutoCleanServiceTests
{
    private static readonly CleanupRule SafeRule = new() { Id = "safe", DisplayName = "安全项", Risk = RiskLevel.Safe };
    private static readonly CleanupRule CautionRule = new() { Id = "caution", DisplayName = "谨慎项", Risk = RiskLevel.Caution };
    private static readonly CleanupRule HighRule = new() { Id = "high", DisplayName = "高风险", Risk = RiskLevel.High };
    private static readonly CleanupRule DefaultSelectedRule = new() { Id = "default", DisplayName = "默认勾选", Risk = RiskLevel.Caution, Recommended = true };

    private static readonly List<CleanupRule> Rules = [SafeRule, CautionRule, HighRule, DefaultSelectedRule];

    [Fact]
    public void SelectRules_SafeOnly_TakesOnlySafeRules()
    {
        var selected = AutoCleanService.SelectRules(Rules, AutoCleanScope.SafeOnly, ["safe", "caution"]);

        Assert.Equal([SafeRule], selected);
    }

    [Fact]
    public void SelectRules_SelectedRules_UsesSavedIds()
    {
        var selected = AutoCleanService.SelectRules(Rules, AutoCleanScope.SelectedRules, ["caution", "high"]);

        Assert.Equal([CautionRule, HighRule], selected);
    }

    [Fact]
    public void SelectRules_SelectedRules_NeverSaved_FallsBackToDefaults()
    {
        var selected = AutoCleanService.SelectRules(Rules, AutoCleanScope.SelectedRules, null);

        Assert.Equal([DefaultSelectedRule], selected);
    }

    [Fact]
    public void SelectRules_SelectedRules_SavedEmptyList_SelectsNothing()
    {
        // 全不勾也是一次明确选择,不能回落到默认勾选
        Assert.Empty(AutoCleanService.SelectRules(Rules, AutoCleanScope.SelectedRules, []));
    }
}

public class DiskSpaceWatcherTests
{
    [Fact]
    public void FindLowDisks_ReturnsOnlyBelowThreshold()
    {
        var drives = new List<KeyValuePair<string, long?>>
        {
            new(@"C:\", 5L * 1024 * 1024 * 1024),
            new(@"D:\", 50L * 1024 * 1024 * 1024),
        };

        var alerts = DiskSpaceWatcher.FindLowDisks(drives, 20L * 1024 * 1024 * 1024);

        var alert = Assert.Single(alerts);
        Assert.Equal(@"C:\", alert.Drive);
        Assert.Equal(5L * 1024 * 1024 * 1024, alert.FreeBytes);
        Assert.Equal(20L * 1024 * 1024 * 1024, alert.ThresholdBytes);
        Assert.Contains("C:", alert.Message);
    }

    [Fact]
    public void FindLowDisks_IgnoresDrivesWithoutReading()
    {
        var drives = new List<KeyValuePair<string, long?>> { new(@"E:\", null) };

        Assert.Empty(DiskSpaceWatcher.FindLowDisks(drives, 1024));
    }

    [Fact]
    public void FindLowDisks_EmptyList_NoAlerts()
    {
        Assert.Empty(DiskSpaceWatcher.FindLowDisks([], 1024));
    }
}
