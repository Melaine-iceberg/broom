using broom.Core;
using broom.Services;

namespace broom.Tests;

public class SettingsServiceTests
{
    [Fact]
    public void Load_MissingFile_ReturnsDefaults()
    {
        using var dir = new TempDir();
        var service = new SettingsService(dir.FullPath);

        var settings = service.Load();

        Assert.Empty(settings.ExcludedPaths);
        Assert.Empty(settings.CustomRules);
        Assert.False(settings.DefaultPermanentDelete);
        Assert.True(settings.QuarantineEnabled);
        Assert.Equal(0, settings.SkipRecentDays);
        Assert.Equal(0, settings.SecureErasePasses);
        Assert.False(settings.CreateRestorePointBeforeClean);
        Assert.Null(settings.SelectedRuleIds);
    }

    [Fact]
    public void SaveThenLoad_RoundTripsAllSettings()
    {
        using var dir = new TempDir();
        var service = new SettingsService(dir.FullPath);
        var settings = new BroomSettings
        {
            CustomRules = [new CustomRule { Path = @"C:\work", Name = "工作目录", Risk = RiskLevel.Caution, Recommended = true }],
            ExcludedPaths = [@"C:\Temp\keep"],
            ExcludedFiles = [@"C:\a.txt"],
            DefaultPermanentDelete = true,
            ShowHighRiskRules = false,
            QuarantineEnabled = false,
            QuarantineRetentionDays = 3,
            SkipRecentDays = 7,
            SecureErasePasses = 3,
            CreateRestorePointBeforeClean = true,
            SelectedRuleIds = ["user-temp", "browser-cache"],
        };

        service.Save(settings);
        var loaded = service.Load();

        Assert.Equal(settings.CustomRules.Count, loaded.CustomRules.Count);
        Assert.Equal("工作目录", loaded.CustomRules[0].Name);
        Assert.Equal(settings.ExcludedPaths, loaded.ExcludedPaths);
        Assert.Equal(settings.ExcludedFiles, loaded.ExcludedFiles);
        Assert.True(loaded.DefaultPermanentDelete);
        Assert.False(loaded.ShowHighRiskRules);
        Assert.False(loaded.QuarantineEnabled);
        Assert.Equal(3, loaded.QuarantineRetentionDays);
        Assert.Equal(7, loaded.SkipRecentDays);
        Assert.Equal(3, loaded.SecureErasePasses);
        Assert.True(loaded.CreateRestorePointBeforeClean);
        Assert.Equal(settings.SelectedRuleIds, loaded.SelectedRuleIds);
    }

    [Fact]
    public void SaveThenLoad_KeepsSelectedRuleIdsNullWhenNeverSaved()
    {
        using var dir = new TempDir();
        var service = new SettingsService(dir.FullPath);

        service.Save(new BroomSettings());
        var loaded = service.Load();

        Assert.Null(loaded.SelectedRuleIds);
    }

    [Fact]
    public void Load_CorruptJson_FallsBackToDefaultsAndBacksUpFile()
    {
        using var dir = new TempDir();
        var service = new SettingsService(dir.FullPath);
        Directory.CreateDirectory(dir.FullPath);
        File.WriteAllText(service.FilePath, "{ this is not json");

        var settings = service.Load();

        Assert.Empty(settings.ExcludedPaths);
        Assert.False(File.Exists(service.FilePath));
        Assert.True(File.Exists(Path.Combine(dir.FullPath, "settings.bad.json")));
    }

    [Fact]
    public void FilePath_LivesInInjectedDirectory()
    {
        using var dir = new TempDir();
        var service = new SettingsService(dir.FullPath);

        Assert.StartsWith(dir.FullPath, service.FilePath);
    }

    [Fact]
    public void Save_CreatesDirectoryOnDemand()
    {
        using var dir = new TempDir();
        var nested = Path.Combine(dir.FullPath, "a", "b");
        var service = new SettingsService(nested);

        service.Save(new BroomSettings());

        Assert.True(File.Exists(service.FilePath));
    }
}
