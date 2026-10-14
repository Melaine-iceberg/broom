using Avalonia.Markup.Xaml;

namespace broom.Localization;

/// <summary>
/// AXAML 文案引用:<c>Text="{loc:Loc '中文原文'}"</c>。
/// 键即中文原文;语言在应用启动时确定,控件创建时一次性解析。
/// </summary>
public sealed class LocExtension : MarkupExtension
{
    public LocExtension(string key) => Key = key;

    public string Key { get; }

    public override object ProvideValue(IServiceProvider serviceProvider) => Strings.T(Key);
}
