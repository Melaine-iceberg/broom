using broom.Core;
using broom.ViewModels;

namespace broom.Tests;

public class RuleSelectionTests
{
    private static readonly CleanupRule DefaultOn = new() { Id = "user-temp", DisplayName = "默认勾选", Recommended = true };
    private static readonly CleanupRule DefaultOff = new() { Id = "browser-cache", DisplayName = "默认不勾选" };

    [Fact]
    public void ResolveSelection_NoSavedIds_UsesRuleDefault()
    {
        Assert.True(MainWindowViewModel.ResolveSelection(null, DefaultOn));
        Assert.False(MainWindowViewModel.ResolveSelection(null, DefaultOff));
    }

    [Fact]
    public void ResolveSelection_SavedIds_OverrideRuleDefault()
    {
        Assert.False(MainWindowViewModel.ResolveSelection(["browser-cache"], DefaultOn));
        Assert.True(MainWindowViewModel.ResolveSelection(["browser-cache"], DefaultOff));
    }

    [Fact]
    public void ResolveSelection_MatchesIdsCaseInsensitively()
    {
        Assert.True(MainWindowViewModel.ResolveSelection(["USER-TEMP"], DefaultOn));
    }

    [Fact]
    public void ResolveSelection_EmptySavedIds_SelectsNothing()
    {
        Assert.False(MainWindowViewModel.ResolveSelection([], DefaultOn));
    }
}
