using System.Globalization;
using System.Resources;

namespace broom.Localization;

/// <summary>
/// 文案资源访问。中性资源为简体中文(Localization/Strings.resx),英文为 Localization/Strings.en.resx;
/// 键即中文原文(gettext 风格),缺失时回退中文原文,不会出现空白文案。
/// 语言在启动时按系统 UI 语言决定一次(zh* → 中文,其余 → 英文),不做运行时切换。
/// </summary>
public static class Strings
{
    private static readonly ResourceManager Manager =
        new("broom.Localization.Strings", typeof(Strings).Assembly);

    /// <summary>资源管理器(测试用:校验各语言键的完整性)。</summary>
    internal static ResourceManager ResourceManager => Manager;

    /// <summary>当前文案语言;null 表示跟随 <see cref="CultureInfo.CurrentUICulture"/>。</summary>
    public static CultureInfo? Culture { get; set; }

    /// <summary>系统 UI 语言 → 应用文案语言:中文环境保持中文,其余一律英文。</summary>
    public static CultureInfo ResolveUiCulture(CultureInfo systemUiCulture) =>
        systemUiCulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase)
            ? CultureInfo.GetCultureInfo("zh-CN")
            : CultureInfo.GetCultureInfo("en-US");

    /// <summary>启动时调用:决定文案语言并写入线程 / 默认线程的 UI 语言。</summary>
    public static void ApplySystemLanguage()
    {
        var culture = ResolveUiCulture(CultureInfo.CurrentUICulture);
        Culture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        Thread.CurrentThread.CurrentUICulture = culture;
    }

    /// <summary>取文案;缺失时返回键本身(即中文原文)。</summary>
    public static string T(string key) => Manager.GetString(key, Culture) ?? key;

    /// <summary>取文案并格式化(占位符与参数按当前语言的数字 / 日期格式)。</summary>
    public static string T(string key, params object?[] args) =>
        string.Format(Culture ?? CultureInfo.CurrentUICulture, Manager.GetString(key, Culture) ?? key, args);

    /// <summary>取文案;缺失时用调用方给的兜底文本。</summary>
    public static string GetOrDefault(string key, string fallback) => Manager.GetString(key, Culture) ?? fallback;

    /// <summary>
    /// 取插值消息:插值表达式的格式串(如 "清理 {0:N0} 项")即资源键,按当前语言重新格式化。
    /// 调用处保持插值写法:<c>Strings.M($"清理 {count:N0} 项")</c>。
    /// </summary>
    public static string M(FormattableString message)
    {
        var format = Manager.GetString(message.Format, Culture) ?? message.Format;
        return string.Format(Culture ?? CultureInfo.CurrentUICulture, format, message.GetArguments());
    }
}
