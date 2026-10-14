using broom.Platform;

namespace broom.Tests;

public class SecureEraseTests
{
    [Fact]
    public void OverwritePasses_DeleteFileAndOverwriteContent()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var dir = new TempDir();
        var target = dir.CreateFile("secret.bin", new string('S', 4096));
        var link = Path.Combine(dir.FullPath, "secret.link");
        Assert.True(NativeTest.CreateHardLink(link, target, IntPtr.Zero));

        var failures = new Dictionary<string, string>();
        var deleted = new PermanentFileDeleter(1).Delete([target], failures);

        Assert.Equal(1, deleted);
        Assert.Empty(failures);
        Assert.False(File.Exists(target));
        // 硬链接还在:内容应已被随机数据覆盖,不再是原明文
        var seen = File.ReadAllBytes(link);
        Assert.Equal(4096, seen.Length);
        Assert.False(seen.All(b => b == (byte)'S'));
    }

    [Fact]
    public void OverwriteFailure_KeepsFileAndReportsReason()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var dir = new TempDir();
        var locked = dir.CreateFile("locked.bin", "locked");

        using (new FileStream(locked, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var failures = new Dictionary<string, string>();
            var deleted = new PermanentFileDeleter(1).Delete([locked], failures);

            Assert.Equal(0, deleted);
            Assert.True(failures.ContainsKey(locked));
            Assert.True(File.Exists(locked));
        }
    }

    [Fact]
    public void MissingFile_CountsAsCleanedInBothModes()
    {
        using var dir = new TempDir();
        var missing = Path.Combine(dir.FullPath, "missing.bin");

        var withOverwrite = new Dictionary<string, string>();
        Assert.Equal(1, new PermanentFileDeleter(1).Delete([missing], withOverwrite));
        Assert.Empty(withOverwrite);

        var withoutOverwrite = new Dictionary<string, string>();
        Assert.Equal(1, new PermanentFileDeleter().Delete([missing], withoutOverwrite));
        Assert.Empty(withoutOverwrite);
    }

    [Fact]
    public void EmptyFile_IsDeletedWithoutOverwrite()
    {
        using var dir = new TempDir();
        var empty = dir.CreateFile("empty.bin", "");

        var failures = new Dictionary<string, string>();
        Assert.Equal(1, new PermanentFileDeleter(3).Delete([empty], failures));
        Assert.False(File.Exists(empty));
    }

    [Fact]
    public void WithoutOverwrite_BehaviorIsUnchanged()
    {
        using var dir = new TempDir();
        var file = dir.CreateFile("plain.bin", "abc");

        var failures = new Dictionary<string, string>();
        Assert.Equal(1, new PermanentFileDeleter().Delete([file], failures));
        Assert.False(File.Exists(file));
    }

    [Fact]
    public void DeleterName_ReflectsOverwriteMode()
    {
        Assert.Equal("永久删除", new PermanentFileDeleter().Name);
        Assert.Equal("永久删除(覆写 1 次)", new PermanentFileDeleter(1).Name);
    }

    [Fact]
    public void PurgeAll_OverwritesBeforeDeleting()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var dir = new TempDir();
        var root = Path.Combine(dir.FullPath, "quarantine");
        var session = Path.Combine(root, "20200101-000000");
        Directory.CreateDirectory(session);
        var a = Path.Combine(session, "a.bin");
        File.WriteAllText(a, new string('Q', 2048));
        File.WriteAllText(Path.Combine(session, "b.bin"), "bbb");
        var link = Path.Combine(dir.FullPath, "a.link");
        Assert.True(NativeTest.CreateHardLink(link, a, IntPtr.Zero));

        var ok = new QuarantineService(root).TryPurgeAll(out var items, out _, out _, secureErasePasses: 1);

        Assert.True(ok);
        Assert.Equal(2, items);
        Assert.False(Directory.Exists(session));
        Assert.False(File.ReadAllBytes(link).All(b => b == (byte)'Q'));
    }

    [Fact]
    public void PurgeAll_OverwriteFailure_KeepsFileAndSession()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var dir = new TempDir();
        var root = Path.Combine(dir.FullPath, "quarantine");
        var session = Path.Combine(root, "20200102-000000");
        Directory.CreateDirectory(session);
        var locked = Path.Combine(session, "locked.bin");
        File.WriteAllText(locked, "locked");
        var service = new QuarantineService(root);

        using (new FileStream(locked, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var ok = service.TryPurgeAll(out _, out _, out _, secureErasePasses: 1);

            Assert.False(ok);
            Assert.True(File.Exists(locked));
            Assert.True(Directory.Exists(session));
        }
    }

    [Fact]
    public void PurgeAll_WithoutOverwrite_RemovesWholeSessions()
    {
        using var dir = new TempDir();
        var root = Path.Combine(dir.FullPath, "quarantine");
        var session = Path.Combine(root, "20200103-000000");
        Directory.CreateDirectory(session);
        File.WriteAllText(Path.Combine(session, "a.bin"), "aaa");

        var ok = new QuarantineService(root).TryPurgeAll(out var items, out var bytes, out _);

        Assert.True(ok);
        Assert.Equal(1, items);
        Assert.Equal(3, bytes);
        Assert.False(Directory.Exists(session));
    }

    [Fact]
    public void PurgeExpired_RemovesOnlyExpiredSessions()
    {
        using var dir = new TempDir();
        var root = Path.Combine(dir.FullPath, "quarantine");
        var expired = Path.Combine(root, "20200104-000000");
        Directory.CreateDirectory(expired);
        File.WriteAllText(Path.Combine(expired, "old.bin"), "old");
        var fresh = Path.Combine(root, DateTimeOffset.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(fresh);
        File.WriteAllText(Path.Combine(fresh, "new.bin"), "new");
        var service = new QuarantineService(root);

        var removed = service.PurgeExpired(7, secureErasePasses: 1);

        Assert.Equal(1, removed);
        Assert.False(Directory.Exists(expired));
        Assert.True(Directory.Exists(fresh));
    }
}
