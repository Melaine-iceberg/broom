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

    [Theory]
    [InlineData("chat-wechat")]
    [InlineData("chat-qq")]
    [InlineData("chat-dingtalk")]
    public void ChatCacheRules_OnlyCleanCacheSubdirectories(string ruleId)
    {
        // 聊天类应用的缓存与聊天记录同处一个数据根,规则必须精确落在缓存子目录,绝不能指向账号根或整目录
        string[] allowedLeaves = ["Cache", "Temp", "defEmotion", "AvatarFiles", "ImageFiles"];

        var rule = Assert.Single(WindowsRuleSet.Create(), r => r.Id == ruleId);

        Assert.NotEmpty(rule.Paths);
        Assert.All(rule.Paths, p => Assert.Contains(Path.GetFileName(p), allowedLeaves, StringComparer.OrdinalIgnoreCase));
    }

    [Theory]
    [InlineData("browser-privacy-cookies")]
    [InlineData("browser-privacy-history")]
    public void BrowserPrivacyRules_AreHighRiskAndUnchecked(string ruleId)
    {
        var rule = Assert.Single(WindowsRuleSet.Create(), r => r.Id == ruleId);

        Assert.Equal(RiskLevel.High, rule.Risk);
        Assert.False(rule.Recommended);
        Assert.Equal("浏览器隐私", rule.Category);
    }

    [Fact]
    public void BrowserPrivacyRules_NeverTouchSavedPasswords()
    {
        var rules = WindowsRuleSet.Create().Where(r => r.Category == "浏览器隐私").ToList();

        Assert.NotEmpty(rules);
        Assert.All(rules, r => Assert.DoesNotContain(r.IncludePatterns, p =>
            p.Contains("Login Data", StringComparison.OrdinalIgnoreCase)
            || p.Contains("Web Data", StringComparison.OrdinalIgnoreCase)));
    }

    [Fact]
    public void BrowserCacheRule_CoversAllSupportedBrowsers()
    {
        var rule = Assert.Single(WindowsRuleSet.Create(), r => r.Id == "browser-cache");

        foreach (var marker in new[] { "Chrome", "Edge", "Firefox", "Brave", "Vivaldi", "Opera", "360Chrome", "360se6", "QQBrowser" })
        {
            Assert.Contains(rule.Paths, p => p.Contains(marker, StringComparison.OrdinalIgnoreCase));
        }
    }

    [Fact]
    public void P2ExpansionRules_ExistAndAreOptIn()
    {
        string[] expandedIds =
        [
            "system-prefetch", "delivery-optimization", "upgrade-residue",
            "user-font-cache", "system-font-cache", "usage-traces",
            "chat-wechat", "chat-qq", "chat-dingtalk", "collab-cache",
            "office-onedrive", "media-spotify", "uwp-localcache",
            "browser-privacy-cookies", "browser-privacy-history",
        ];

        var rules = WindowsRuleSet.Create();
        var expanded = expandedIds.Select(id => Assert.Single(rules, r => r.Id == id)).ToList();

        // 新扩充的类目一律默认不勾选,由用户逐项确认
        Assert.All(expanded, r => Assert.False(r.Recommended));
    }

    [Fact]
    public void UwpCacheRule_DoesNotTouchAppData()
    {
        var rule = Assert.Single(WindowsRuleSet.Create(), r => r.Id == "uwp-localcache");

        Assert.All(rule.Paths, p =>
        {
            Assert.DoesNotContain("LocalState", p, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("RoamingState", p, StringComparison.OrdinalIgnoreCase);
        });
    }
}
