using broom.Core;
using broom.Localization;

namespace broom.Rules;

/// <summary>
/// Windows 首批清理规则集(安全项 A 级 + 谨慎项 B 级)。
/// 规则是纯数据:将来支持 macOS / Linux 时,只需提供新的规则集,扫描与删除引擎不用改动。
/// </summary>
public static class WindowsRuleSet
{
    private const string DevHint = "下次构建或安装依赖时需要重新下载 / 重新编译。";

    /// <summary>Chromium 系浏览器的缓存子目录名;各版本大同小异,不存在的会被自然跳过。</summary>
    private static readonly string[] ChromiumCacheFolders = ["Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "DawnCache"];

    /// <summary>
    /// Chromium 系浏览器的配置档案根目录,缓存规则与隐私规则共用同一份覆盖面。
    /// Opera 没有 User Data 层,配置根即缓存所在目录。
    /// </summary>
    private static readonly string[] ChromiumProfileRoots =
    [
        @"%LOCALAPPDATA%\Google\Chrome\User Data\*",
        @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*",
        @"%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*",
        @"%LOCALAPPDATA%\Vivaldi\User Data\*",
        @"%LOCALAPPDATA%\Opera Software\Opera Stable",
        @"%LOCALAPPDATA%\Opera Software\Opera GX Stable",
        @"%LOCALAPPDATA%\360Chrome\Chrome\User Data\*",
        @"%LOCALAPPDATA%\360se6\User Data\*",
        @"%APPDATA%\360se6\User Data\*",
        @"%LOCALAPPDATA%\Tencent\QQBrowser\User Data\*",
    ];

    /// <summary>Firefox 配置档案根目录:标准位于 Roaming,部分便携 / 企业部署放在 Local。</summary>
    private static readonly string[] FirefoxProfileRoots =
    [
        @"%APPDATA%\Mozilla\Firefox\Profiles\*",
        @"%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*",
    ];

    private static readonly CleanupRule[] BuiltInRules =
    [
        // ── A 级:可放心清理 ───────────────────────────────
        new CleanupRule
        {
            Id = "user-temp",
            Category = "系统临时与日志",
            DisplayName = "用户临时文件",
            Description = "当前用户的临时目录,程序正在使用的文件会自动跳过。",
            Paths = [@"%TEMP%"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "system-temp",
            Category = "系统临时与日志",
            DisplayName = "系统临时文件",
            Description = @"C:\Windows\Temp 中的临时文件。",
            Paths = [@"%SystemRoot%\Temp"],
            RequiresAdmin = true,
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "user-crash-dumps",
            Category = "系统临时与日志",
            DisplayName = "应用崩溃转储",
            Description = "程序崩溃时生成的转储文件,仅用于事后诊断。",
            Paths = [@"%LOCALAPPDATA%\CrashDumps"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "system-crash-dumps",
            Category = "系统临时与日志",
            DisplayName = "系统内存转储",
            Description = "系统蓝屏转储与内存转储文件,通常体积很大。",
            Paths = [@"%SystemRoot%\Minidump", @"%SystemRoot%\MEMORY.DMP"],
            RequiresAdmin = true,
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "user-wer",
            Category = "系统临时与日志",
            DisplayName = "Windows 错误报告(用户)",
            Description = "应用程序错误报告归档。",
            Paths = [@"%LOCALAPPDATA%\Microsoft\Windows\WER"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "system-wer",
            Category = "系统临时与日志",
            DisplayName = "Windows 错误报告(系统)",
            Description = "系统级错误报告归档,与用户级互相独立。",
            Paths = [@"%ProgramData%\Microsoft\Windows\WER"],
            RequiresAdmin = true,
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "inet-cache",
            Category = "系统缓存",
            DisplayName = "Internet 临时文件",
            Description = "系统 Internet 临时文件缓存。",
            Paths = [@"%LOCALAPPDATA%\Microsoft\Windows\INetCache"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "thumbnail-cache",
            Category = "系统缓存",
            DisplayName = "缩略图与图标缓存",
            Description = "资源管理器缩略图与图标缓存,删除后会自动重建。",
            Paths = [@"%LOCALAPPDATA%\Microsoft\Windows\Explorer"],
            IncludePatterns = ["thumbcache_*.db", "iconcache_*.db"],
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "user-font-cache",
            Category = "系统缓存",
            DisplayName = "字体缓存(用户)",
            Description = "当前用户的字体缓存,删除后系统自动重建;重建完成前个别应用的字体渲染可能短暂异常。",
            Paths = [@"%LOCALAPPDATA%\Microsoft\Windows\FontCache"],
        },
        new CleanupRule
        {
            Id = "system-font-cache",
            Category = "系统缓存",
            DisplayName = "字体缓存(系统)",
            Description = "系统服务使用的字体缓存,删除后自动重建。",
            Paths = [@"%SystemRoot%\ServiceProfiles\LocalService\AppData\Local\FontCache"],
            RequiresAdmin = true,
        },

        // ── B 级:需谨慎,默认不勾选 ────────────────────────
        new CleanupRule
        {
            Id = "windows-update-cache",
            Category = "系统缓存",
            DisplayName = "Windows 更新下载缓存",
            Description = "已下载的更新安装包缓存,删除后更新时可能需要重新下载。",
            Paths = [@"%SystemRoot%\SoftwareDistribution\Download"],
            Risk = RiskLevel.Caution,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "system-prefetch",
            Category = "系统缓存",
            DisplayName = "预读取文件(Prefetch)",
            Description = "Windows 为程序启动生成的预读记录;删除后系统会重建,近期应用首次启动可能略慢。",
            Paths = [@"%SystemRoot%\Prefetch"],
            Risk = RiskLevel.Caution,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "delivery-optimization",
            Category = "系统缓存",
            DisplayName = "传递优化文件",
            Description = "Windows 更新经 P2P 分发留下的下载缓存;需要时会重新下载。",
            Paths = [@"%SystemRoot%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"],
            Risk = RiskLevel.Caution,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "upgrade-residue",
            Category = "系统临时与日志",
            DisplayName = "系统升级残留与安装日志",
            Description = @"$WinREAgent、C:\Windows\Panther 等升级 / 安装日志与临时残留;删除后无法再查看安装日志,不影响已安装的系统。",
            Paths = [@"%SystemDrive%\$WinREAgent", @"%SystemRoot%\Panther", @"%SystemRoot%\Logs\MoSetup"],
            Risk = RiskLevel.Caution,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "usage-traces",
            Category = "使用痕迹",
            DisplayName = "最近使用的文档与跳转列表",
            Description = "资源管理器「最近使用」与任务栏跳转列表(含固定项)的记录;不影响文档本身,列表从头开始重新积累。",
            Paths = [@"%APPDATA%\Microsoft\Windows\Recent"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "recycle-bin",
            Category = "回收站",
            DisplayName = "回收站",
            Description = "清空回收站,清空后其中的文件将无法恢复。",
            Kind = RuleKind.RecycleBin,
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "browser-cache",
            Category = "浏览器缓存",
            DisplayName = "浏览器网页缓存",
            Description = "Chrome / Edge / Brave / Opera / Vivaldi / 360 / QQ 浏览器 / Firefox 的网页缓存,不涉及密码、Cookie 与书签。",
            Paths = BrowserCachePaths(),
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "browser-privacy-cookies",
            Category = "浏览器隐私",
            DisplayName = "浏览器 Cookie 与登录状态",
            Description = "删除各浏览器保存的 Cookie(不含已保存的密码);所有网站的登录状态都会丢失,需要重新登录,网银等站点可能要求重新验证身份。浏览器运行中被占用的文件会跳过,建议先退出浏览器。",
            Paths = BrowserProfilePaths(),
            IncludePatterns = ["Cookies", "Cookies-journal", "cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"],
            Risk = RiskLevel.High,
        },
        new CleanupRule
        {
            Id = "browser-privacy-history",
            Category = "浏览器隐私",
            DisplayName = "浏览器历史与会话",
            Description = "删除浏览历史、常访问站点与标签页会话记录(不含书签与已保存的密码);自动补全的网址建议随之消失,且不可恢复(除非浏览器已开启同步)。",
            Paths = BrowserProfilePaths(),
            IncludePatterns =
            [
                "History", "History-journal", "Visited Links",
                "Top Sites", "Top Sites-journal", "Favicons", "Favicons-journal",
                "Shortcuts", "Shortcuts-journal",
                "Current Session", "Current Tabs", "Last Session", "Last Tabs", "Session_*",
                "places.sqlite", "places.sqlite-wal", "places.sqlite-shm",
                "favicons.sqlite", "favicons.sqlite-wal", "favicons.sqlite-shm",
                "sessionstore.jsonlz4", "recovery.jsonlz4", "previous.jsonlz4", "upgrade.jsonlz4*",
            ],
            Risk = RiskLevel.High,
        },
        new CleanupRule
        {
            Id = "windows-old",
            Category = "系统备份",
            DisplayName = "旧系统备份与升级残留",
            Description = "Windows.old 等升级残留,删除后无法回滚到升级前的系统。",
            Paths = [@"%SystemDrive%\Windows.old", @"%SystemDrive%\$WINDOWS.~BT", @"%SystemDrive%\$WINDOWS.~WS"],
            Risk = RiskLevel.High,
            RequiresAdmin = true,
        },

        // ── 动作型:执行系统清理动作,不逐个删文件 ─────────────
        new CleanupRule
        {
            Id = "action-dns-cache",
            Category = "系统缓存",
            DisplayName = "DNS 解析缓存",
            Description = "刷新系统的域名解析缓存;不影响正常使用,个别域名解析可能短暂变慢,随后自动重建。",
            Kind = RuleKind.Action,
            Action = CleanupAction.FlushDnsCache,
            Recommended = true,
        },
        new CleanupRule
        {
            Id = "action-event-logs",
            Category = "系统临时与日志",
            DisplayName = "Windows 事件日志",
            Description = "通过系统 API 清空事件查看器中的历史记录;排障历史将丢失且不可恢复,建议先导出留存。",
            Kind = RuleKind.Action,
            Action = CleanupAction.ClearEventLogs,
            Risk = RiskLevel.High,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "action-shadow-copies",
            Category = "系统备份",
            DisplayName = "旧还原点与卷影副本",
            Description = "删除系统还原点 / 卷影副本,每个卷保留最新一个;释放量通常很大,但删除后无法回滚到更早的系统状态。",
            Kind = RuleKind.Action,
            Action = CleanupAction.DeleteShadowCopies,
            Risk = RiskLevel.High,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "action-winsxs",
            Category = "系统备份",
            DisplayName = "组件存储清理(WinSxS)",
            Description = "DISM 组件清理,移除已被取代的旧组件;耗时较长(可能十几分钟),执行后无法卸载被取代的更新;释放量以清理后的磁盘对比为准。",
            Kind = RuleKind.Action,
            Action = CleanupAction.CleanComponentStore,
            Risk = RiskLevel.High,
            RequiresAdmin = true,
        },
        new CleanupRule
        {
            Id = "windows-logs",
            Category = "系统临时与日志",
            DisplayName = "Windows 组件日志",
            Description = "更新与组件安装过程产生的日志文件。",
            Paths =
            [
                @"%SystemRoot%\Logs\CBS",
                @"%SystemRoot%\Logs\DISM",
                @"%SystemRoot%\Logs\SIH",
                @"%SystemRoot%\Logs\WindowsUpdate",
            ],
            Risk = RiskLevel.Caution,
            RequiresAdmin = true,
        },

        // ── 应用缓存:可重建但需重新下载;聊天类只清缓存子目录 ──
        new CleanupRule
        {
            Id = "chat-wechat",
            Category = "应用缓存",
            DisplayName = "应用缓存 · 微信",
            Description = "只清微信 FileStorage 下的 Cache / Temp 缓存子目录;聊天记录数据库与图片 / 视频 / 文件原目录不在清理范围内,缺失的缓存内容联网后重新加载。",
            Paths =
            [
                @"%USERPROFILE%\Documents\WeChat Files\*\FileStorage\Cache",
                @"%USERPROFILE%\Documents\WeChat Files\*\FileStorage\Temp",
                @"%USERPROFILE%\Documents\xwechat_files\*\FileStorage\Cache",
                @"%USERPROFILE%\Documents\xwechat_files\*\FileStorage\Temp",
            ],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "chat-qq",
            Category = "应用缓存",
            DisplayName = "应用缓存 · QQ",
            Description = "只清 Tencent Files 下的 Cache / Temp 缓存子目录;聊天记录数据库(Msg3.0.db / nt_msg.db 等)、FileRecv 接收文件与图片 / 视频原目录不在清理范围内。",
            Paths =
            [
                @"%USERPROFILE%\Documents\Tencent Files\*\FileStorage\Cache",
                @"%USERPROFILE%\Documents\Tencent Files\*\FileStorage\Temp",
            ],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "chat-dingtalk",
            Category = "应用缓存",
            DisplayName = "应用缓存 · 钉钉",
            Description = "只清表情 / 头像 / 聊天图片缓存目录;聊天记录与收发的文件不清理,缓存内容联网后重新加载。",
            Paths =
            [
                @"%APPDATA%\DingTalk\defEmotion",
                @"%APPDATA%\DingTalk\*\AvatarFiles",
                @"%APPDATA%\DingTalk\*\ImageFiles",
            ],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "collab-cache",
            Category = "应用缓存",
            DisplayName = "应用缓存 · Teams / Discord / Slack",
            Description = "Teams / Discord / Slack 的网页与渲染缓存;设置、登录令牌与本地数据库不清理。新版 Teams 按微软文档清缓存,清理后可能需要重新登录。",
            Paths =
            [
                @"%APPDATA%\Microsoft\Teams\Cache",
                @"%APPDATA%\Microsoft\Teams\Code Cache",
                @"%APPDATA%\Microsoft\Teams\GPUCache",
                @"%APPDATA%\Microsoft\Teams\blob_storage",
                @"%APPDATA%\Microsoft\Teams\tmp",
                @"%APPDATA%\discord\Cache",
                @"%APPDATA%\discord\Code Cache",
                @"%APPDATA%\discord\GPUCache",
                @"%APPDATA%\discord\blob_storage",
                @"%APPDATA%\discord\DawnCache",
                @"%APPDATA%\Slack\Cache",
                @"%APPDATA%\Slack\Code Cache",
                @"%APPDATA%\Slack\GPUCache",
                @"%APPDATA%\Slack\blob_storage",
                @"%APPDATA%\Slack\Service Worker\CacheStorage",
                @"%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams",
            ],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "office-onedrive",
            Category = "应用缓存",
            DisplayName = "应用缓存 · Office / OneDrive",
            Description = "Office 文档协同编辑缓存与 OneDrive 客户端 / 安装日志;不影响云端与本地已同步的文件,重新打开文档时可能需要重新下载。",
            Paths =
            [
                @"%LOCALAPPDATA%\Microsoft\Office\16.0\OfficeFileCache",
                @"%LOCALAPPDATA%\Microsoft\Office\OTele",
                @"%LOCALAPPDATA%\Microsoft\OneDrive\logs",
                @"%LOCALAPPDATA%\Microsoft\OneDrive\setup\logs",
            ],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "media-spotify",
            Category = "应用缓存",
            DisplayName = "应用缓存 · Spotify",
            Description = "Spotify 的歌曲与界面缓存;离线下载的音乐需要重新缓存。",
            Paths = [@"%LOCALAPPDATA%\Spotify\Storage", @"%LOCALAPPDATA%\Spotify\Data"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "uwp-localcache",
            Category = "应用缓存",
            DisplayName = "应用缓存 · 商店应用(UWP)",
            Description = "商店应用 LocalCache 下的缓存(磁盘紧张时系统本就可能清除);不触碰 LocalState / RoamingState 中的应用数据,个别应用可能需要重新下载资源。",
            Paths =
            [
                @"%LOCALAPPDATA%\Packages\*\LocalCache\Local",
                @"%LOCALAPPDATA%\Packages\*\LocalCache\Low",
                @"%LOCALAPPDATA%\Packages\*\LocalCache\Roaming",
            ],
            Risk = RiskLevel.Caution,
        },

        // ── 开发者缓存:可重建,但代价是重新下载 ────────────
        new CleanupRule
        {
            Id = "dev-nuget",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · NuGet",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.nuget\packages"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-npm",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · npm",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\npm-cache"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-pip",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · pip",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\pip\Cache"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-yarn",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Yarn",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\Yarn\Cache"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-pnpm",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · pnpm",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\pnpm\store"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-gradle",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Gradle",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.gradle\caches"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-maven",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Maven",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.m2\repository"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-go",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Go 构建缓存",
            Description = DevHint,
            Paths = [@"%LOCALAPPDATA%\go-build"],
            Risk = RiskLevel.Caution,
        },
        new CleanupRule
        {
            Id = "dev-cargo",
            Category = "开发者缓存",
            DisplayName = "开发者缓存 · Cargo",
            Description = DevHint,
            Paths = [@"%USERPROFILE%\.cargo\registry\cache"],
            Risk = RiskLevel.Caution,
        },
    ];

    /// <summary>内置规则 + 用户自定义规则(设置页维护)。</summary>
    public static IReadOnlyList<CleanupRule> Create(BroomSettings? settings = null)
    {
        if (settings is null || settings.CustomRules.Count == 0)
        {
            return [.. BuiltInRules.Select(Localize)];
        }

        var rules = new List<CleanupRule>(BuiltInRules.Select(Localize));
        foreach (var custom in settings.CustomRules)
        {
            rules.Add(Localize(ToCleanupRule(custom)));
        }

        return rules;
    }

    /// <summary>
    /// 文案本地化:规则是纯数据,内联文案即资源键(gettext 风格);
    /// 显示名 / 说明 / 类别在创建时按当前语言解析,找不到资源时回退中文原文。
    /// 自定义规则的用户自定义名称同样过一遍(不存在的键原样返回)。
    /// </summary>
    private static CleanupRule Localize(CleanupRule rule) => rule with
    {
        DisplayName = Strings.T(rule.DisplayName),
        Description = Strings.T(rule.Description),
        Category = Strings.T(rule.Category),
    };

    /// <summary>各浏览器配置档案下的缓存目录全集。</summary>
    private static string[] BrowserCachePaths()
    {
        var paths = new List<string>(ChromiumProfileRoots.Length * ChromiumCacheFolders.Length + FirefoxProfileRoots.Length);
        foreach (var root in ChromiumProfileRoots)
        {
            foreach (var folder in ChromiumCacheFolders)
            {
                paths.Add($@"{root}\{folder}");
            }
        }

        foreach (var root in FirefoxProfileRoots)
        {
            paths.Add($@"{root}\cache2");
        }

        return [.. paths];
    }

    /// <summary>各浏览器配置档案根目录,隐私规则按文件名模式在其下精确匹配。</summary>
    private static string[] BrowserProfilePaths()
    {
        var paths = new List<string>(ChromiumProfileRoots.Length + FirefoxProfileRoots.Length);
        paths.AddRange(ChromiumProfileRoots);
        paths.AddRange(FirefoxProfileRoots);
        return [.. paths];
    }

    private static CleanupRule ToCleanupRule(CustomRule custom) => new()
    {
        Id = $"custom-{custom.Path}",
        Category = "自定义目录",
        DisplayName = string.IsNullOrWhiteSpace(custom.Name) ? Strings.M($"自定义:{custom.Path}") : custom.Name,
        Description = "来自设置的自定义目录。",
        Paths = [custom.Path],
        IncludePatterns = custom.IncludePatterns.Count > 0 ? [.. custom.IncludePatterns] : ["*"],
        ExcludePatterns = [.. custom.ExcludePatterns],
        Risk = custom.Risk,
        Recommended = custom.Recommended,
    };
}
