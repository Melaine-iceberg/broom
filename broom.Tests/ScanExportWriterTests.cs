using System.Text;
using broom.Core;
using broom.Services;

namespace broom.Tests;

public class ScanExportWriterTests
{
    private static RuleScanResult Result(CleanupRule rule, params ScannedFile[] files)
    {
        var result = new RuleScanResult { Rule = rule };
        foreach (var file in files)
        {
            result.Files.Add(file);
        }

        return result;
    }

    private static readonly CleanupRule Rule1 = new() { Id = "r1", DisplayName = "规则一", Paths = ["x"] };
    private static readonly CleanupRule Rule2 = new() { Id = "r2", DisplayName = "规则二", Paths = ["y"] };

    private static string Write(ScanExportFormat format, params RuleScanResult[] results)
    {
        var sb = new StringBuilder();
        using var writer = new StringWriter(sb);
        ScanExportWriter.Write(writer, results, format);
        return sb.ToString();
    }

    [Fact]
    public void WriteCsv_EmitsHeaderAndRows()
    {
        var output = Write(ScanExportFormat.Csv, Result(Rule1, new ScannedFile(@"C:\a.tmp", 3)));

        var lines = output.TrimEnd().Split(Environment.NewLine);
        Assert.Equal("规则,路径,大小(字节)", lines[0]);
        Assert.Equal(@"规则一,C:\a.tmp,3", lines[1]);
    }

    [Fact]
    public void WriteCsv_QuotesFieldsContainingSeparators()
    {
        var output = Write(ScanExportFormat.Csv, Result(Rule1, new ScannedFile(@"C:\we,ird""name.tmp", 7)));

        Assert.Contains(@"""C:\we,ird""""name.tmp""", output);
    }

    [Fact]
    public void WriteTxt_UsesTabSeparatorWithoutQuoting()
    {
        var output = Write(ScanExportFormat.Txt, Result(Rule1, new ScannedFile(@"C:\we,ird.tmp", 7)));

        var lines = output.TrimEnd().Split(Environment.NewLine);
        Assert.Equal("规则\t路径\t大小(字节)", lines[0]);
        Assert.Equal("规则一\tC:\\we,ird.tmp\t7", lines[1]);
    }

    [Fact]
    public void Write_SortsFilesBySizeDescendingWithinRule()
    {
        var output = Write(ScanExportFormat.Txt, Result(Rule1,
            new ScannedFile("small", 1),
            new ScannedFile("big", 9),
            new ScannedFile("mid", 5)));

        var lines = output.TrimEnd().Split(Environment.NewLine);
        Assert.Equal(4, lines.Length);
        Assert.Equal("规则一\tbig\t9", lines[1]);
        Assert.Equal("规则一\tmid\t5", lines[2]);
        Assert.Equal("规则一\tsmall\t1", lines[3]);
    }

    [Fact]
    public void Write_SkipsRulesWithoutFiles()
    {
        var output = Write(ScanExportFormat.Txt, Result(Rule1), Result(Rule2, new ScannedFile("a", 1)));

        var lines = output.TrimEnd().Split(Environment.NewLine);
        Assert.Equal(2, lines.Length);
        Assert.Contains("规则二", lines[1]);
    }
}
