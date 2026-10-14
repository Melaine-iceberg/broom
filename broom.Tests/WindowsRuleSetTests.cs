using broom.Core;
using broom.Rules;

namespace broom.Tests;

public class WindowsRuleSetTests
{
    [Fact]
    public void BuiltInRules_HaveUniqueNonEmptyIds()
    {
        var rules = WindowsRuleSet.Create();

        Assert.NotEmpty(rules);
        Assert.All(rules, r => Assert.False(string.IsNullOrWhiteSpace(r.Id)));
        Assert.Equal(rules.Count, rules.Select(r => r.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Fact]
    public void BuiltInRules_HaveDisplayNameAndCategory()
    {
        var rules = WindowsRuleSet.Create();

        Assert.All(rules, r => Assert.False(string.IsNullOrWhiteSpace(r.DisplayName)));
        Assert.All(rules, r => Assert.False(string.IsNullOrWhiteSpace(r.Category)));
        Assert.All(rules, r => Assert.False(string.IsNullOrWhiteSpace(r.Description)));
    }

    [Fact]
    public void BuiltInRules_PathsRulesHaveValidTemplates()
    {
        var rules = WindowsRuleSet.Create();

        Assert.All(rules.Where(r => r.Kind == RuleKind.Paths), r =>
        {
            Assert.NotEmpty(r.Paths);
            Assert.All(r.Paths, p => Assert.False(string.IsNullOrWhiteSpace(p)));
        });
    }

    [Fact]
    public void BuiltInRules_IncludePatternsAreNeverEmpty()
    {
        var rules = WindowsRuleSet.Create();

        Assert.All(rules, r => Assert.NotEmpty(r.IncludePatterns));
    }

    [Fact]
    public void BuiltInRules_OnlySafeRulesAreRecommended()
    {
        var rules = WindowsRuleSet.Create();

        Assert.All(rules.Where(r => r.Recommended), r => Assert.Equal(RiskLevel.Safe, r.Risk));
    }

    [Fact]
    public void BuiltInRules_TargetWindowsPlatform()
    {
        var rules = WindowsRuleSet.Create();

        Assert.All(rules, r => Assert.Equal("windows", r.Platform));
    }

    [Fact]
    public void Create_WithCustomRules_MergesThemAsCustomCategory()
    {
        using var dir = new TempDir();
        var settings = new BroomSettings();
        settings.CustomRules.Add(new CustomRule
        {
            Path = dir.FullPath,
            Name = "我的目录",
            Risk = RiskLevel.Caution,
        });

        var builtIn = WindowsRuleSet.Create();
        var merged = WindowsRuleSet.Create(settings);

        Assert.Equal(builtIn.Count + 1, merged.Count);
        var custom = Assert.Single(merged, r => r.Category == "自定义目录");
        Assert.Equal("我的目录", custom.DisplayName);
        Assert.Equal($"custom-{dir.FullPath}", custom.Id);
        Assert.Equal(RiskLevel.Caution, custom.Risk);
    }

    [Fact]
    public void Create_WithCustomRules_KeepsIdsUnique()
    {
        using var dir = new TempDir();
        var settings = new BroomSettings();
        settings.CustomRules.Add(new CustomRule { Path = dir.FullPath });
        settings.CustomRules.Add(new CustomRule { Path = dir.CreateDir("other") });

        var merged = WindowsRuleSet.Create(settings);

        Assert.Equal(merged.Count, merged.Select(r => r.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }
}
