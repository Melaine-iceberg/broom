using System.Globalization;
using broom.Localization;
using broom.Rules;

namespace broom.Tests;

public class LocalizationTests
{
    private static void WithCulture(CultureInfo culture, Action action)
    {
        var previous = Strings.Culture;
        try
        {
            Strings.Culture = culture;
            action();
        }
        finally
        {
            Strings.Culture = previous;
        }
    }

    [Theory]
    [InlineData("zh-CN")]
    [InlineData("zh-TW")]
    [InlineData("zh")]
    public void ResolveUiCulture_ChineseSystems_KeepChinese(string cultureName)
    {
        var resolved = Strings.ResolveUiCulture(CultureInfo.GetCultureInfo(cultureName));

        Assert.Equal("zh-CN", resolved.Name);
    }

    [Theory]
    [InlineData("en-US")]
    [InlineData("en-GB")]
    [InlineData("fr-FR")]
    [InlineData("ja-JP")]
    public void ResolveUiCulture_OtherSystems_UseEnglish(string cultureName)
    {
        var resolved = Strings.ResolveUiCulture(CultureInfo.GetCultureInfo(cultureName));

        Assert.Equal("en-US", resolved.Name);
    }

    [Fact]
    public void EnglishResources_CoverEveryNeutralKey()
    {
        var neutral = Strings.ResourceManager.GetResourceSet(CultureInfo.InvariantCulture, true, false);
        var english = Strings.ResourceManager.GetResourceSet(CultureInfo.GetCultureInfo("en"), true, false);

        Assert.NotNull(neutral);
        Assert.NotNull(english);
        var missing = new List<string>();
        foreach (System.Collections.DictionaryEntry entry in neutral!)
        {
            var key = (string)entry.Key;
            if (english!.GetString(key) is not { Length: > 0 })
            {
                missing.Add(key);
            }
        }

        Assert.Empty(missing);
        // 英文不应该有中性资源之外的孤儿键
        foreach (System.Collections.DictionaryEntry entry in english!)
        {
            Assert.True(neutral!.GetString((string)entry.Key) is not null, $"英文资源里有多余的键:{entry.Key}");
        }
    }

    [Fact]
    public void ChineseLookup_ReturnsUnchangedSourceText()
    {
        WithCulture(CultureInfo.GetCultureInfo("zh-CN"), () =>
        {
            Assert.Equal("开始扫描", Strings.T("开始扫描"));
            Assert.Equal("清理完成。", Strings.T("清理完成。"));
        });
    }

    [Fact]
    public void EnglishLookup_ReturnsTranslation()
    {
        WithCulture(CultureInfo.GetCultureInfo("en-US"), () =>
        {
            Assert.Equal("Start scan", Strings.T("开始扫描"));
            Assert.Equal("Cleanup finished.", Strings.T("清理完成。"));
        });
    }

    [Fact]
    public void MissingKey_FallsBackToKeyItself()
    {
        WithCulture(CultureInfo.GetCultureInfo("en-US"), () =>
            Assert.Equal("不存在的键", Strings.T("不存在的键")));
    }

    [Fact]
    public void InterpolatedMessages_ResolvePerLanguage()
    {
        WithCulture(CultureInfo.GetCultureInfo("en-US"), () =>
            Assert.Equal("Scanning: user temp", Strings.M($"正在扫描:{"user temp"}")));
        WithCulture(CultureInfo.GetCultureInfo("zh-CN"), () =>
            Assert.Equal("正在扫描:user temp", Strings.M($"正在扫描:{"user temp"}")));
    }

    [Fact]
    public void RuleNamesAndDescriptions_LocalizePerLanguage()
    {
        WithCulture(CultureInfo.GetCultureInfo("en-US"), () =>
        {
            var rules = WindowsRuleSet.Create();
            var userTemp = rules.Single(r => r.Id == "user-temp");
            Assert.Equal("User temporary files", userTemp.DisplayName);
            Assert.Contains("temp folder", userTemp.Description);
            Assert.Equal("System temp & logs", userTemp.Category);
        });

        WithCulture(CultureInfo.GetCultureInfo("zh-CN"), () =>
        {
            var rules = WindowsRuleSet.Create();
            var userTemp = rules.Single(r => r.Id == "user-temp");
            Assert.Equal("用户临时文件", userTemp.DisplayName);
        });
    }
}
