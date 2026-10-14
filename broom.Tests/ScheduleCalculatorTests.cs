using broom.Core;
using broom.Services;

namespace broom.Tests;

public class ScheduleCalculatorTests
{
    private static readonly DateTime Monday = new(2026, 10, 12, 8, 0, 0); // 2026-10-12 是周一

    [Fact]
    public void GetNextRun_Off_ReturnsNull()
    {
        Assert.Null(ScheduleCalculator.GetNextRun(Monday, AutoCleanFrequency.Off, 2, 1, 1));
    }

    [Fact]
    public void GetNextRun_Daily_BeforeHour_ReturnsSameDay()
    {
        var next = ScheduleCalculator.GetNextRun(Monday, AutoCleanFrequency.Daily, 20, 1, 1);

        Assert.Equal(new DateTime(2026, 10, 12, 20, 0, 0), next);
    }

    [Fact]
    public void GetNextRun_Daily_AfterHour_ReturnsNextDay()
    {
        var next = ScheduleCalculator.GetNextRun(Monday, AutoCleanFrequency.Daily, 2, 1, 1);

        Assert.Equal(new DateTime(2026, 10, 13, 2, 0, 0), next);
    }

    [Fact]
    public void GetNextRun_Daily_AtExactHour_IsNotDueYet()
    {
        // 严格大于锚点:整点本身不算“下一次”,避免同一时刻重复触发
        var next = ScheduleCalculator.GetNextRun(new DateTime(2026, 10, 12, 2, 0, 0), AutoCleanFrequency.Daily, 2, 1, 1);

        Assert.Equal(new DateTime(2026, 10, 13, 2, 0, 0), next);
    }

    [Fact]
    public void GetNextRun_Weekly_MatchesDayOfWeek()
    {
        // 周日(DayOfWeek=0)20:00;锚点是周一 8:00 → 下周日
        var next = ScheduleCalculator.GetNextRun(Monday, AutoCleanFrequency.Weekly, 20, 0, 1);

        Assert.Equal(new DateTime(2026, 10, 18, 20, 0, 0), next);
    }

    [Fact]
    public void GetNextRun_Monthly_MatchesDayOfMonth()
    {
        var next = ScheduleCalculator.GetNextRun(new DateTime(2026, 10, 2, 8, 0, 0), AutoCleanFrequency.Monthly, 3, 1, 28);

        Assert.Equal(new DateTime(2026, 10, 28, 3, 0, 0), next);
    }

    [Fact]
    public void GetNextRun_ClampsOutOfRangeValues()
    {
        // 时刻 25 → 23;星期 9 → 6(周六);日期 40 → 28
        var next = ScheduleCalculator.GetNextRun(Monday, AutoCleanFrequency.Weekly, 25, 9, 40);

        Assert.Equal(new DateTime(2026, 10, 17, 23, 0, 0), next);
    }

    [Fact]
    public void IsDue_ChecksNowAgainstNextRunWithinTolerance()
    {
        var next = new DateTime(2026, 10, 12, 2, 0, 0);
        var tolerance = TimeSpan.FromMinutes(30);

        Assert.False(ScheduleCalculator.IsDue(next.AddMinutes(-1), next, tolerance));
        Assert.True(ScheduleCalculator.IsDue(next, next, tolerance));
        Assert.True(ScheduleCalculator.IsDue(next.AddMinutes(10), next, tolerance));
        Assert.False(ScheduleCalculator.IsDue(next.AddMinutes(31), next, tolerance));
        Assert.False(ScheduleCalculator.IsDue(next, null, tolerance));
    }
}
