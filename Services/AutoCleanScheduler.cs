using broom.Core;

namespace broom.Services;

/// <summary>
/// 应用内定时器:到达设置的执行时刻时触发回调。应用保持运行(托盘常驻)是前提;
/// 不写 Windows 计划任务 —— 需要关机后仍可执行的场景,用 CLI 接入计划任务(见 README)。
/// </summary>
public sealed class AutoCleanScheduler : IDisposable
{
    private static readonly TimeSpan DefaultCheckInterval = TimeSpan.FromSeconds(30);

    /// <summary>超时容差:超过执行时刻太久(如系统休眠跨过整天)就顺延到下一次,不做补偿执行。</summary>
    private static readonly TimeSpan DueTolerance = TimeSpan.FromMinutes(30);

    private readonly Func<BroomSettings> _settingsProvider;
    private readonly Func<Task> _onDue;
    private readonly Timer _timer;
    private readonly object _gate = new();
    private DateTime _anchorLocal;
    private string _scheduleKey = "";
    private int _running;

    public AutoCleanScheduler(Func<BroomSettings> settingsProvider, Func<Task> onDue, TimeSpan? checkInterval = null)
    {
        _settingsProvider = settingsProvider;
        _onDue = onDue;
        _anchorLocal = DateTime.Now;
        _timer = new Timer(_ => Tick(), null, TimeSpan.Zero, checkInterval ?? DefaultCheckInterval);
    }

    /// <summary>是否已有一次清理正在执行(避免重入)。</summary>
    public bool IsRunning => Volatile.Read(ref _running) == 1;

    /// <summary>当前排期键(频率 + 时刻 + 星期/日期),设置变化时自动重新锚定。</summary>
    internal string ScheduleKey
    {
        get
        {
            var settings = _settingsProvider();
            return $"{settings.AutoCleanFrequency}|{settings.AutoCleanHour}|{settings.AutoCleanDayOfWeek}|{settings.AutoCleanDayOfMonth}";
        }
    }

    /// <summary>下一次执行时刻(本地时间);未启用时为 null。</summary>
    public DateTime? GetNextRun()
    {
        lock (_gate)
        {
            return GetNextRunCore();
        }
    }

    /// <summary>立即检查一次是否到点(定时器之外的手动入口)。</summary>
    public void CheckNow() => Tick();

    private void Tick()
    {
        try
        {
            lock (_gate)
            {
                // 排期设置变化:从现在重新锚定,避免改完设置立刻补跑一次
                var key = ScheduleKey;
                if (key != _scheduleKey)
                {
                    _scheduleKey = key;
                    _anchorLocal = DateTime.Now;
                    return;
                }

                var next = GetNextRunCore();
                var now = DateTime.Now;

                // 休眠 / 长时间未运行跨过执行时刻:不做补偿执行,顺延到下一个周期
                if (next is { } missed && now > missed + DueTolerance)
                {
                    _anchorLocal = missed;
                    return;
                }

                if (!ScheduleCalculator.IsDue(now, next, DueTolerance))
                {
                    return;
                }

                _anchorLocal = now;
            }

            if (Interlocked.Exchange(ref _running, 1) == 1)
            {
                return;
            }

            _ = RunAsync();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            // 定时器回调里的异常不能让进程退出;错过本次顺延到下一个周期
        }
    }

    private async Task RunAsync()
    {
        try
        {
            await _onDue();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
        }
        finally
        {
            Interlocked.Exchange(ref _running, 0);
        }
    }

    private DateTime? GetNextRunCore()
    {
        var settings = _settingsProvider();
        return ScheduleCalculator.GetNextRun(
            _anchorLocal,
            settings.AutoCleanFrequency,
            settings.AutoCleanHour,
            settings.AutoCleanDayOfWeek,
            settings.AutoCleanDayOfMonth);
    }

    public void Dispose() => _timer.Dispose();
}
