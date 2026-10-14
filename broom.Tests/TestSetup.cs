using System.Globalization;
using System.Runtime.CompilerServices;
using broom.Localization;

// 测试统一串行执行:文案语言是进程级静态状态,英文用例会临时切换 Culture
[assembly: Xunit.CollectionBehavior(DisableTestParallelization = true)]

namespace broom.Tests;

/// <summary>
/// 测试统一以中文(资源中性语言)运行,断言与既有行为保持一致;
/// 英文资源的完整性与示例由 <see cref="LocalizationTests"/> 单独覆盖。
/// </summary>
internal static class TestSetup
{
    [ModuleInitializer]
    public static void Init() => Strings.Culture = CultureInfo.GetCultureInfo("zh-CN");
}
