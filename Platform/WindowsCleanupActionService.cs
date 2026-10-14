using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text.RegularExpressions;
using broom.Core;

namespace broom.Platform;

/// <summary>Windows 动作型清理:DNS 缓存刷新、事件日志清空、卷影副本删除、DISM 组件存储清理。</summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsCleanupActionService : ICleanupActionService
{
    public bool IsSupported(CleanupAction action) => action is
        CleanupAction.FlushDnsCache
        or CleanupAction.ClearEventLogs
        or CleanupAction.DeleteShadowCopies
        or CleanupAction.CleanComponentStore;

    public CleanupActionResult Execute(CleanupAction action, IProgress<string>? progress = null, CancellationToken ct = default)
        => action switch
        {
            CleanupAction.FlushDnsCache => FlushDnsCache(),
            CleanupAction.ClearEventLogs => ClearEventLogs(ct),
            CleanupAction.DeleteShadowCopies => DeleteShadowCopies(progress, ct),
            CleanupAction.CleanComponentStore => CleanComponentStore(progress, ct),
            _ => new CleanupActionResult { Success = false, Error = $"未知的清理动作:{action}" },
        };

    [DllImport("dnsapi.dll", EntryPoint = "DnsFlushResolverCache")]
    private static extern bool DnsFlushResolverCache();

    private static CleanupActionResult FlushDnsCache()
    {
        try
        {
            return DnsFlushResolverCache()
                ? new CleanupActionResult { Success = true, Summary = "已刷新 DNS 解析缓存。" }
                : new CleanupActionResult { Success = false, Error = "刷新 DNS 解析缓存失败。" };
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            return new CleanupActionResult { Success = false, Error = $"刷新 DNS 解析缓存失败:{ex.Message}" };
        }
    }

    /// <summary>逐个清空事件日志:受保护的日志按项记录失败,不中断整体(需要管理员权限)。</summary>
    private static CleanupActionResult ClearEventLogs(CancellationToken ct)
    {
        var result = new CleanupActionResult { Success = true };
        var clearedLogs = 0;
        long clearedRecords = 0;

        try
        {
            var session = EventLogSession.GlobalSession;
            foreach (var name in session.GetLogNames())
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    var info = session.GetLogInformation(name, PathType.LogName);
                    if (info.RecordCount is not > 0)
                    {
                        continue;
                    }

                    session.ClearLog(name);
                    clearedLogs++;
                    clearedRecords += info.RecordCount.Value;
                }
                catch (Exception ex) when (ex is EventLogException or UnauthorizedAccessException or IOException)
                {
                    result.Failures.Add(new DeleteFailure($"<事件日志:{name}>", ex.Message));
                }
            }
        }
        catch (Exception ex) when (ex is EventLogException or UnauthorizedAccessException)
        {
            return new CleanupActionResult { Success = false, Error = $"枚举事件日志失败:{ex.Message}" };
        }

        return new CleanupActionResult
        {
            Success = true,
            ItemsAffected = (int)Math.Min(clearedRecords, int.MaxValue),
            Summary = $"已清空 {clearedLogs:N0} 个事件日志(共 {clearedRecords:N0} 条记录)",
        };
    }

    /// <summary>
    /// 删除还原点与卷影副本:每个卷保留最新一个。
    /// 用 vssadmin「逐个删最旧」实现 —— 不依赖列表顺序与输出语言;列表仅用于数个数。
    /// </summary>
    private static CleanupActionResult DeleteShadowCopies(IProgress<string>? progress, CancellationToken ct)
    {
        var vssadmin = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "vssadmin.exe");
        var result = new CleanupActionResult { Success = true };
        var listErrors = new List<string>();
        var deleted = 0;

        foreach (var drive in FixedDrives())
        {
            ct.ThrowIfCancellationRequested();
            if (!TryRunCapture(vssadmin, $"list shadows /for={drive}", out var output, out var error, ct))
            {
                listErrors.Add($"{drive.TrimEnd('\\')}({error})");
                continue;
            }

            var count = CountShadowCopies(output);
            for (var i = 1; i < count; i++)
            {
                ct.ThrowIfCancellationRequested();
                progress?.Report($"删除 {drive.TrimEnd('\\')} 的旧卷影副本({i}/{count - 1})…");
                if (TryRunCapture(vssadmin, $"delete shadows /for={drive} /oldest", out _, out error, ct))
                {
                    deleted++;
                }
                else
                {
                    result.Failures.Add(new DeleteFailure($"<卷影副本:{drive.TrimEnd('\\')}>", error));
                    break;
                }
            }
        }

        if (deleted > 0 || result.Failures.Count > 0)
        {
            return new CleanupActionResult
            {
                Success = true,
                ItemsAffected = deleted,
                Summary = $"已删除 {deleted:N0} 个旧还原点 / 卷影副本(每个卷保留最新一个)",
            };
        }

        // 一个都没删:可能是确实没有卷影副本,也可能压根列不出(典型为未提权)
        return listErrors.Count > 0
            ? new CleanupActionResult
            {
                Success = false,
                Error = $"无法列出卷影副本:{listErrors[0]}(可能是没有卷影副本,或需要管理员权限)",
            }
            : new CleanupActionResult { Success = true, Summary = "没有可删除的旧卷影副本(每个卷只保留最新一个)" };
    }

    /// <summary>从 vssadmin 输出数出卷影副本个数:按挂载设备名计数,与界面语言无关。</summary>
    internal static int CountShadowCopies(string vssadminOutput)
        => Regex.Matches(vssadminOutput, @"HarddiskVolumeShadowCopy\d+").Count;

    private static IEnumerable<string> FixedDrives()
    {
        DriveInfo[] drives;
        try
        {
            drives = DriveInfo.GetDrives();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            yield break;
        }

        foreach (var drive in drives)
        {
            if (drive.DriveType == DriveType.Fixed && drive.IsReady)
            {
                yield return drive.Name;
            }
        }
    }

    /// <summary>运行系统工具并捕获全部输出;成功返回 true,失败原因进 <paramref name="error"/>。</summary>
    internal static bool TryRunCapture(string fileName, string arguments, out string output, out string error, CancellationToken ct)
    {
        output = "";
        error = "";
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            process.Start();
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();

            while (!process.WaitForExit(200))
            {
                if (ct.IsCancellationRequested)
                {
                    try
                    {
                        process.Kill(entireProcessTree: true);
                    }
                    catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
                    {
                    }

                    process.WaitForExit();
                    throw new OperationCanceledException(ct);
                }
            }

            output = (stdout.GetAwaiter().GetResult() + stderr.GetAwaiter().GetResult()).Trim();
            if (process.ExitCode == 0)
            {
                return true;
            }

            error = $"退出码 {process.ExitCode}{(output.Length > 0 ? $":{Truncate(output, 200)}" : "")}";
            return false;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            error = ex.Message;
            return false;
        }
    }

    private static string Truncate(string text, int max)
        => text.Length <= max ? text : text[..max] + "…";

    private static CleanupActionResult CleanComponentStore(IProgress<string>? progress, CancellationToken ct)
    {
        var dism = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "Dism.exe");
        return RunProcess(dism, "/Online /Cleanup-Image /StartComponentCleanup", "组件存储清理", progress, ct);
    }

    /// <summary>运行系统工具并转发输出行作为进度;取消时终止进程树并抛出取消异常。</summary>
    internal static CleanupActionResult RunProcess(
        string fileName,
        string arguments,
        string actionName,
        IProgress<string>? progress,
        CancellationToken ct)
    {
        // 只留最后几行,失败时作为原因摘要(输出可能很长)
        var tail = new Queue<string>();
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };

            void Consume(string? line)
            {
                if (line is not { Length: > 0 })
                {
                    return;
                }

                lock (tail)
                {
                    tail.Enqueue(line.Trim());
                    while (tail.Count > 3)
                    {
                        tail.Dequeue();
                    }
                }

                progress?.Report(line.Trim());
            }

            process.OutputDataReceived += (_, e) => Consume(e.Data);
            process.ErrorDataReceived += (_, e) => Consume(e.Data);
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            while (!process.WaitForExit(200))
            {
                if (ct.IsCancellationRequested)
                {
                    try
                    {
                        process.Kill(entireProcessTree: true);
                    }
                    catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
                    {
                    }

                    process.WaitForExit();
                    throw new OperationCanceledException(ct);
                }
            }

            // 无超时等待一次,确保异步输出回调全部落地
            process.WaitForExit();
            if (process.ExitCode == 0)
            {
                return new CleanupActionResult { Success = true, Summary = $"{actionName}完成" };
            }

            string tailText;
            lock (tail)
            {
                tailText = string.Join(" / ", tail);
            }

            return new CleanupActionResult
            {
                Success = false,
                Error = $"{actionName}失败(退出码 {process.ExitCode}){(tailText.Length > 0 ? $":{tailText}" : "")}",
            };
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            return new CleanupActionResult { Success = false, Error = $"{actionName}无法执行:{ex.Message}" };
        }
    }
}
