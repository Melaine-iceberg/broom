namespace broom.Core;

/// <summary>
/// 单实例互斥(GUI 用):创建命名 Mutex 抢占所有权,已有实例在跑时返回 null,调用方静默退出。
/// 命令行 / 无人值守模式不加锁,允许与界面并行(计划任务自动清理不受影响)。
/// </summary>
public sealed class SingleInstanceGuard : IDisposable
{
    /// <summary>默认互斥名;Local\ 前缀限定在当前用户会话内,不跨会话互斥。</summary>
    public const string DefaultMutexName = @"Local\broom.SingleInstance";

    private readonly Mutex _mutex;
    private bool _released;

    private SingleInstanceGuard(Mutex mutex) => _mutex = mutex;

    /// <summary>尝试取得实例锁;已被其他实例持有时返回 null。</summary>
    /// <param name="name">互斥名(测试可注入独立名称避免相互干扰)。</param>
    public static SingleInstanceGuard? TryAcquire(string name = DefaultMutexName)
    {
        var mutex = new Mutex(initiallyOwned: true, name, out var createdNew);
        if (!createdNew)
        {
            mutex.Dispose();
            return null;
        }

        return new SingleInstanceGuard(mutex);
    }

    public void Dispose()
    {
        if (!_released)
        {
            _released = true;
            _mutex.ReleaseMutex();
        }

        _mutex.Dispose();
    }
}
