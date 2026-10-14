using broom.Core;

namespace broom.Services;

/// <summary>自动清理时间的纯计算:给定锚点时刻与设置,算出下一次应执行的本地时刻。</summary>
public static class ScheduleCalculator
{
    /// <summary>
    /// 返回 <paramref name="afterLocal"/> 之后的下一次执行时刻(本地时间,按设置的整点执行)。
    /// 频率关闭时返回 null。每周按星期几匹配,每月按日期(1–28)匹配,避免“31 号”月份跳过。
    /// </summary>
    public static DateTime? GetNextRun(DateTime afterLocal, AutoCleanFrequency frequency, int hour, int dayOfWeek, int dayOfMonth)
    {
        if (frequency == AutoCleanFrequency.Off)
        {
            return null;
        }

        hour = Math.Clamp(hour, 0, 23);
        dayOfWeek = Math.Clamp(dayOfWeek, 0, 6);
        dayOfMonth = Math.Clamp(dayOfMonth, 1, 28);

        var day = afterLocal.Date;
        for (var i = 0; i < 400; i++)
        {
            if (IsMatch(day, frequency, dayOfWeek, dayOfMonth))
            {
                var candidate = day.AddHours(hour);
                if (candidate > afterLocal)
                {
                    return candidate;
                }
            }

            day = day.AddDays(1);
        }

        return null;
    }

    /// <summary>下一次执行是否已到(超过时刻且未超出容差用于防抖)。</summary>
    public static bool IsDue(DateTime nowLocal, DateTime? nextRunLocal, TimeSpan tolerance) =>
        nextRunLocal is { } next && nowLocal >= next && nowLocal - next <= tolerance;

    private static bool IsMatch(DateTime day, AutoCleanFrequency frequency, int dayOfWeek, int dayOfMonth) => frequency switch
    {
        AutoCleanFrequency.Daily => true,
        AutoCleanFrequency.Weekly => (int)day.DayOfWeek == dayOfWeek,
        AutoCleanFrequency.Monthly => day.Day == dayOfMonth,
        _ => false,
    };
}
