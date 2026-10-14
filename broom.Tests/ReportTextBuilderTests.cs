using broom.Core;
using broom.Services;

namespace broom.Tests;

public class ReportTextBuilderTests
{
    [Fact]
    public void Build_OrdersSummaryNotesResultsAndFooter()
    {
        var rule = new CleanupRule { Id = "user-temp", DisplayName = "用户临时文件" };
        var report = new CleanupReport();
        var result = new RuleCleanResult { Rule = rule, BytesRemoved = 1024, DeletedCount = 2 };
        result.Failures.Add(new DeleteFailure(@"C:\a.txt", "占用"));
        report.Results.Add(result);
        report.EmptyDirectoriesRemoved = 3;

        var text = ReportTextBuilder.Build(
            report,
            "回收站:清理 2 项,共 1 KB。",
            ["注记一", "", "注记二"],
            "脚注提示");

        var lines = text.Split(Environment.NewLine);
        Assert.Equal("回收站:清理 2 项,共 1 KB。", lines[0]);
        Assert.Contains("注记一", lines[1]);
        // 空注记被跳过
        Assert.Contains("注记二", lines[2]);
        Assert.Contains("· 用户临时文件:2 项 / 1 KB", lines[3]);
        Assert.Contains("✗", lines[4]);
        Assert.Contains("另回收空目录 3 个", text);
        Assert.EndsWith("脚注提示", text);
    }

    [Fact]
    public void Build_ListsSkippedRulesAndLimitsFailures()
    {
        var rule = new CleanupRule { Id = "r", DisplayName = "规则" };
        var report = new CleanupReport();
        var result = new RuleCleanResult { Rule = rule };
        for (var i = 0; i < 12; i++)
        {
            result.Failures.Add(new DeleteFailure($@"C:\f{i}.txt", "占用"));
        }

        report.Results.Add(result);
        report.SkippedRules.Add(new CleanupRule { Id = "skipped", DisplayName = "未执行规则" });

        var text = ReportTextBuilder.Build(report, "摘要", maxFailuresPerRule: 10);

        Assert.Equal(10, text.Split("✗").Length - 1);
        Assert.Contains("其余 2 项失败未列出", text);
        Assert.Contains("未执行的规则:未执行规则", text);
    }

    [Fact]
    public void Build_SkipsRuleWithNoEffect()
    {
        var report = new CleanupReport();
        report.Results.Add(new RuleCleanResult { Rule = new CleanupRule { Id = "empty", DisplayName = "空规则" } });

        var text = ReportTextBuilder.Build(report, "摘要");

        Assert.Equal("摘要", text);
    }
}
