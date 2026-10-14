using broom.Core;

namespace broom.Tests;

/// <summary>单实例互斥:同一互斥名只允许一个持有者,释放后可再次取得。</summary>
public class SingleInstanceGuardTests
{
    private static string NewMutexName() => @"Local\broom-tests-" + Guid.NewGuid().ToString("N");

    [Fact]
    public void TryAcquire_FirstInstance_ReturnsGuard()
    {
        var name = NewMutexName();

        using var guard = SingleInstanceGuard.TryAcquire(name);

        Assert.NotNull(guard);
    }

    [Fact]
    public void TryAcquire_AlreadyAcquired_ReturnsNull()
    {
        var name = NewMutexName();
        using var first = SingleInstanceGuard.TryAcquire(name);

        var second = SingleInstanceGuard.TryAcquire(name);

        Assert.Null(second);
    }

    [Fact]
    public void TryAcquire_AfterDispose_SucceedsAgain()
    {
        var name = NewMutexName();
        var guard = SingleInstanceGuard.TryAcquire(name);
        guard!.Dispose();

        using var again = SingleInstanceGuard.TryAcquire(name);

        Assert.NotNull(again);
    }

    [Fact]
    public void Dispose_Twice_DoesNotThrow()
    {
        var name = NewMutexName();
        var guard = SingleInstanceGuard.TryAcquire(name);

        guard!.Dispose();

        guard.Dispose();
    }
}
