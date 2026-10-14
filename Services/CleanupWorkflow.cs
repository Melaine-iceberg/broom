using broom.Core;
using broom.Platform;
using broom.Rules;

namespace broom.Services;

/// <summary>
/// 扫描 / 清理的可复用编排:规则构建、扫描、清理前置(系统还原点)、删除器创建与清理执行。
/// GUI、命令行与自动清理共用这一条流水线,保证行为一致。
/// </summary>
public sealed class CleanupWorkflow
{
    private readonly Scanner _scanner = new();
    private readonly Cleaner _cleaner = new();
    private readonly QuarantineService _quarantine;
    private readonly IRestorePointService _restorePoints = PlatformServices.CreateRestorePointService();

    /// <param name="quarantine">隔离区服务;留空时自建(与 GUI 共用同一实例可让还原 / 清空看到同一批会话)。</param>
    public CleanupWorkflow(QuarantineService? quarantine = null) => _quarantine = quarantine ?? new QuarantineService();

    /// <summary>
    /// 按设置构建规则集。<paramref name="includeHighRisk"/>=true 时忽略「显示高风险类目」的界面开关
    /// (命令行 --clean all 需要能显式选到全部规则)。
    /// </summary>
    public static IReadOnlyList<CleanupRule> CreateRules(BroomSettings settings, bool includeHighRisk = false)
    {
        IEnumerable<CleanupRule> rules = WindowsRuleSet.Create(settings);
        if (!includeHighRisk && !settings.ShowHighRiskRules)
        {
            rules = rules.Where(r => r.Risk != RiskLevel.High);
        }

        return rules.ToList();
    }

    public Task<IReadOnlyList<RuleScanResult>> ScanAsync(
        IReadOnlyList<CleanupRule> rules,
        BroomSettings settings,
        IProgress<ScanProgress>? progress = null,
        CancellationToken ct = default)
        => _scanner.ScanAsync(rules, settings.ExcludedPaths, settings.ExcludedFiles, progress, ct, settings.SkipRecentDays);

    public async Task<CleanupOutcome> CleanAsync(
        IReadOnlyList<RuleScanResult> targets,
        CleanupRequest request,
        IProgress<CleanProgress>? progress = null,
        CancellationToken ct = default)
    {
        // 先建回滚点再动手;失败(未提权 / 系统保护未开启)只提示,不阻塞清理
        string? restoreNote = null;
        if (request.Settings.CreateRestorePointBeforeClean)
        {
            restoreNote = await Task.Run(() => CreateRestorePointNote(request.IsElevated), ct);
        }

        var (deleter, warning) = CreateDeleter(request);
        var report = await _cleaner.CleanAsync(targets, deleter, progress, ct,
            request.Settings.SkipRecentDays,
            removeEmptyDirectories: request.Settings.RemoveEmptyDirectories);

        return new CleanupOutcome
        {
            Report = report,
            Deleter = deleter,
            Warning = warning,
            RestorePointNote = restoreNote,
            QuarantineSession = (deleter as QuarantineFileDeleter)?.Session,
        };
    }

    /// <summary>按清理请求选择删除器:回收站(默认)/ 永久删除(可选先移入隔离区);不支持回收站的平台降级。</summary>
    public (IFileDeleter Deleter, string? Warning) CreateDeleter(CleanupRequest request)
    {
        var settings = request.Settings;
        if (request.PermanentDelete)
        {
            if (settings.QuarantineEnabled)
            {
                // "永久删除"改为先移入隔离区:可在报告里还原,超过保留天数后自动清理
                return (new QuarantineFileDeleter(_quarantine.CreateSession()), null);
            }

            return (new PermanentFileDeleter(settings.SecureErasePasses), null);
        }

        if (OperatingSystem.IsWindows())
        {
            return (new WindowsRecycleBinDeleter(), null);
        }

        if (settings.QuarantineEnabled)
        {
            return (new QuarantineFileDeleter(_quarantine.CreateSession()), "当前平台暂不支持回收站,本次改为移入隔离区。");
        }

        return (new PermanentFileDeleter(settings.SecureErasePasses), "当前平台暂不支持回收站,本次改为永久删除。");
    }

    /// <summary>清理前创建系统还原点;失败不阻塞清理,返回的说明文字并入清理报告。</summary>
    public string CreateRestorePointNote(bool isElevated)
    {
        if (!OperatingSystem.IsWindows())
        {
            return "未创建系统还原点:当前平台暂不支持。";
        }

        if (!isElevated)
        {
            return "未创建系统还原点:需要管理员权限(可点击“以管理员身份重启”),本次跳过。";
        }

        var description = $"broom 清理前还原点({DateTime.Now:yyyy-MM-dd HH:mm})";
        return _restorePoints.TryCreateRestorePoint(description, out var error)
            ? $"已创建系统还原点:{description}。"
            : $"未创建系统还原点:{error}清理继续,本次删除无法通过还原点回滚。";
    }
}

/// <summary>一次清理的执行请求。</summary>
public sealed record CleanupRequest
{
    public required BroomSettings Settings { get; init; }

    /// <summary>永久删除(不经过回收站);false 时按平台能力选择回收站 / 隔离区。</summary>
    public bool PermanentDelete { get; init; }

    public bool IsElevated { get; init; }
}

/// <summary>一次清理的执行结果:报告 + 执行环境信息(删除器、提示文字、隔离区会话)。</summary>
public sealed class CleanupOutcome
{
    public required CleanupReport Report { get; init; }

    public required IFileDeleter Deleter { get; init; }

    /// <summary>平台降级提示(如“不支持回收站,改为移入隔离区”)。</summary>
    public string? Warning { get; init; }

    /// <summary>系统还原点的创建结果说明。</summary>
    public string? RestorePointNote { get; init; }

    /// <summary>本次清理移入隔离区的会话(未使用隔离区时为 null)。</summary>
    public QuarantineSession? QuarantineSession { get; init; }
}
