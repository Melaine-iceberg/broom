using broom.Core;
using broom.ViewModels;

namespace broom.Tests;

public class SettingsViewModelTests
{
    private static SettingsViewModel CreateEditor() => new(new BroomSettings(), () => "", () => "");

    [Fact]
    public void TryBuild_DeduplicatesExcludedPathsIgnoringCase()
    {
        var editor = CreateEditor();
        editor.ExcludedPathsText = string.Join(
            Environment.NewLine, @"C:\Temp\keep", @"c:\temp\KEEP", @"C:\Temp\keep2");
        editor.ExcludedFilesText = @"C:\a.txt";

        var ok = editor.TryBuild(out var settings, out _);

        Assert.True(ok);
        Assert.Equal(2, settings.ExcludedPaths.Count);
        Assert.Single(settings.ExcludedFiles);
    }

    [Fact]
    public void TryBuild_RejectsRelativeExclusionAndNamesTheLine()
    {
        var editor = CreateEditor();
        editor.ExcludedPathsText = @"Temp\relative";

        var ok = editor.TryBuild(out _, out var error);

        Assert.False(ok);
        Assert.Contains(@"Temp\relative", error);
    }

    [Fact]
    public void TryBuild_AllowsEnvironmentVariableExclusions()
    {
        var editor = CreateEditor();
        editor.ExcludedPathsText = "%USERPROFILE%\\keep";

        var ok = editor.TryBuild(out var settings, out _);

        Assert.True(ok);
        Assert.Single(settings.ExcludedPaths);
    }

    [Fact]
    public void Save_RewritesTextWithoutDuplicatesAndReportsCount()
    {
        var editor = CreateEditor();
        editor.ExcludedPathsText = string.Join(Environment.NewLine, @"C:\Temp\keep", @"c:\temp\KEEP");

        var closed = false;
        editor.CloseRequested += _ => closed = true;
        editor.SaveCommand.Execute(null);

        Assert.True(closed);
        Assert.Equal(@"C:\Temp\keep", editor.ExcludedPathsText);
        Assert.Contains("1", editor.SaveNotice);
    }

    [Fact]
    public void Save_InvalidInput_KeepsEditorOpenAndClearsNotice()
    {
        var editor = CreateEditor();
        editor.ExcludedPathsText = "relative";
        var closed = false;
        editor.CloseRequested += _ => closed = true;

        editor.SaveCommand.Execute(null);

        Assert.False(closed);
        Assert.NotEmpty(editor.ErrorText);
        Assert.Equal("", editor.SaveNotice);
    }

    [Fact]
    public void AppendExcludedFileAndPath_SyncTheTextboxes()
    {
        var editor = CreateEditor();

        editor.AppendExcludedFile(@"C:\a.txt");
        editor.AppendExcludedPath(@"C:\keep");

        Assert.Equal(@"C:\a.txt", editor.ExcludedFilesText);
        Assert.Equal(@"C:\keep", editor.ExcludedPathsText);
    }

    [Fact]
    public void TryBuild_FlowsSkipRecentDaysAndSecureEraseIntoModel()
    {
        var editor = CreateEditor();
        editor.SelectedSkipRecent = editor.SkipRecentOptions.First(o => o.Days == 7);
        editor.SelectedSecureErase = editor.SecureEraseOptions.First(o => o.Passes == 3);

        var ok = editor.TryBuild(out var settings, out _);

        Assert.True(ok);
        Assert.Equal(7, settings.SkipRecentDays);
        Assert.Equal(3, settings.SecureErasePasses);
    }

    [Fact]
    public void RestorePointOption_DefaultsOffAndRoundTrips()
    {
        var editor = CreateEditor();
        Assert.False(editor.CreateRestorePointBeforeClean);

        editor.CreateRestorePointBeforeClean = true;
        var ok = editor.TryBuild(out var settings, out _);

        Assert.True(ok);
        Assert.True(settings.CreateRestorePointBeforeClean);
    }

    [Fact]
    public void Constructor_ReadsPersistedValues()
    {
        var settings = new BroomSettings
        {
            SkipRecentDays = 3,
            SecureErasePasses = 1,
            CreateRestorePointBeforeClean = true,
            ExcludedPaths = [@"C:\keep"],
        };

        var editor = new SettingsViewModel(settings, () => "", () => "");

        Assert.Equal(3, editor.SelectedSkipRecent.Days);
        Assert.Equal(1, editor.SelectedSecureErase.Passes);
        Assert.True(editor.CreateRestorePointBeforeClean);
        Assert.Equal(@"C:\keep", editor.ExcludedPathsText);
    }

    [Fact]
    public void AutomationOptions_FlowIntoModel()
    {
        var editor = CreateEditor();
        editor.SelectedAutoCleanFrequency = editor.AutoCleanFrequencyOptions.Single(o => o.Frequency == AutoCleanFrequency.Weekly);
        editor.SelectedAutoCleanHour = editor.AutoCleanHourOptions.Single(o => o.Hour == 5);
        editor.SelectedAutoCleanDayOfWeek = editor.AutoCleanDayOfWeekOptions.Single(o => o.DayOfWeek == 3);
        editor.SelectedAutoCleanDayOfMonth = editor.AutoCleanDayOfMonthOptions.Single(o => o.DayOfMonth == 20);
        editor.SelectedAutoCleanScope = editor.AutoCleanScopeOptions.Single(o => o.Scope == AutoCleanScope.SelectedRules);
        editor.CloseToTray = false;
        editor.SelectedLowDisk = editor.LowDiskOptions.Single(o => o.ThresholdGb == 50);

        var ok = editor.TryBuild(out var settings, out _);

        Assert.True(ok);
        Assert.Equal(AutoCleanFrequency.Weekly, settings.AutoCleanFrequency);
        Assert.Equal(5, settings.AutoCleanHour);
        Assert.Equal(3, settings.AutoCleanDayOfWeek);
        Assert.Equal(20, settings.AutoCleanDayOfMonth);
        Assert.Equal(AutoCleanScope.SelectedRules, settings.AutoCleanScope);
        Assert.False(settings.CloseToTray);
        Assert.Equal(50, settings.LowDiskThresholdGb);
        Assert.True(editor.IsWeekly);
        Assert.False(editor.IsMonthly);
    }

    [Fact]
    public void AutomationOptions_DefaultsKeepAutoCleanOff()
    {
        var editor = CreateEditor();

        Assert.False(editor.IsAutoCleanEnabled);
        Assert.False(editor.IsWeekly);
        Assert.False(editor.IsMonthly);
        Assert.True(editor.CloseToTray);
    }
}
