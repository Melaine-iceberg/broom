using broom.Cli;

namespace broom.Tests;

public class CommandLineParserTests
{
    [Fact]
    public void Parse_Scan_Defaults()
    {
        var result = CommandLineParser.Parse(["--scan"]);

        Assert.Null(result.Error);
        Assert.Equal(CliAction.Scan, result.Options!.Action);
        Assert.Equal(CliScope.Safe, result.Options.Scope);
        Assert.False(result.Options.DryRun);
        Assert.False(result.Options.AssumeYes);
        Assert.Null(result.Options.ReportPath);
    }

    [Theory]
    [InlineData("safe", CliScope.Safe)]
    [InlineData("all", CliScope.All)]
    [InlineData("ALL", CliScope.All)]
    public void Parse_CleanWithScope_ReadsScope(string value, CliScope expected)
    {
        var result = CommandLineParser.Parse(["--clean", value]);

        Assert.Equal(CliAction.Clean, result.Options!.Action);
        Assert.Equal(expected, result.Options.Scope);
    }

    [Fact]
    public void Parse_CleanWithoutScope_DefaultsToSafe()
    {
        var result = CommandLineParser.Parse(["--clean"]);

        Assert.Equal(CliScope.Safe, result.Options!.Scope);
    }

    [Fact]
    public void Parse_AllOptions_ReadsEverything()
    {
        var result = CommandLineParser.Parse(["--clean", "all", "--dry-run", "--report", @"C:\tmp\out.txt", "--yes"]);

        var options = result.Options!;
        Assert.Equal(CliAction.Clean, options.Action);
        Assert.Equal(CliScope.All, options.Scope);
        Assert.True(options.DryRun);
        Assert.True(options.AssumeYes);
        Assert.Equal(@"C:\tmp\out.txt", options.ReportPath);
    }

    [Fact]
    public void Parse_CleanWithoutYes_IsNotAssumeYes()
    {
        // --yes 必须显式给出,否则走确认提示
        var result = CommandLineParser.Parse(["--clean"]);

        Assert.False(result.Options!.AssumeYes);
    }

    [Theory]
    [InlineData("--wat")]
    [InlineData("scan")]
    public void Parse_UnknownParameter_Fails(string arg)
    {
        var result = CommandLineParser.Parse([arg]);

        Assert.Null(result.Options);
        Assert.NotNull(result.Error);
    }

    [Fact]
    public void Parse_UnknownScope_Fails()
    {
        var result = CommandLineParser.Parse(["--clean", "everything"]);

        Assert.Null(result.Options);
        Assert.Contains("safe", result.Error);
    }

    [Fact]
    public void Parse_BothActions_Fails()
    {
        Assert.NotNull(CommandLineParser.Parse(["--scan", "--clean"]).Error);
    }

    [Fact]
    public void Parse_ReportWithoutPath_Fails()
    {
        Assert.NotNull(CommandLineParser.Parse(["--scan", "--report"]).Error);
        Assert.NotNull(CommandLineParser.Parse(["--scan", "--report", "--yes"]).Error);
    }

    [Fact]
    public void Parse_NoAction_Fails()
    {
        var result = CommandLineParser.Parse(["--yes"]);

        Assert.Null(result.Options);
        Assert.NotNull(result.Error);
    }

    [Fact]
    public void Parse_Help_ShowsHelpWithoutError()
    {
        var result = CommandLineParser.Parse(["--help"]);

        Assert.Null(result.Options);
        Assert.Null(result.Error);
        Assert.True(result.ShowHelp);
    }

    [Theory]
    [InlineData(new[] { "--scan" }, true)]
    [InlineData(new[] { "--clean", "safe" }, true)]
    [InlineData(new[] { "--help" }, true)]
    [InlineData(new[] { "/?" }, true)]
    [InlineData(new[] { "--unknown" }, false)]
    [InlineData(new string[0], false)]
    public void LooksLikeCliRequest_DetectsCliFlags(string[] args, bool expected)
    {
        Assert.Equal(expected, CommandLineParser.LooksLikeCliRequest(args));
    }

    [Fact]
    public void Run_Help_ReturnsOkAndPrintsUsage()
    {
        var output = new StringWriter();

        var exitCode = CliRunner.Run(["--help"], output, new StringWriter());

        Assert.Equal(CliRunner.ExitOk, exitCode);
        Assert.Contains("用法:", output.ToString());
    }

    [Fact]
    public void Run_UsageError_ReturnsExitUsage()
    {
        var error = new StringWriter();

        var exitCode = CliRunner.Run(["--scan", "--clean"], new StringWriter(), error);

        Assert.Equal(CliRunner.ExitUsage, exitCode);
        Assert.Contains("--scan 与 --clean", error.ToString());
    }

    [Fact]
    public void Run_UnknownParameter_ReturnsExitUsage()
    {
        var exitCode = CliRunner.Run(["--nope"], new StringWriter(), new StringWriter());

        Assert.Equal(CliRunner.ExitUsage, exitCode);
    }
}
