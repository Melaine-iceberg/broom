using System.Globalization;
using broom.Core;

namespace broom.Services;

/// <summary>扫描结果导出格式:CSV(Excel 友好)与 TXT(制表符分隔)。</summary>
public enum ScanExportFormat
{
    Csv,
    Txt,
}

/// <summary>把扫描结果导出为「规则 / 路径 / 大小」明细;纯文本生成,便于单元测试。</summary>
public static class ScanExportWriter
{
    public static void Write(TextWriter writer, IEnumerable<RuleScanResult> results, ScanExportFormat format)
    {
        var separator = format == ScanExportFormat.Csv ? "," : "\t";
        writer.WriteLine(format == ScanExportFormat.Csv ? "规则,路径,大小(字节)" : "规则\t路径\t大小(字节)");

        foreach (var result in results)
        {
            // 与文件明细一致按体积降序,方便核对大文件
            foreach (var file in result.Files.OrderByDescending(f => f.Size))
            {
                writer.WriteLine(string.Join(separator,
                    Escape(format, result.Rule.DisplayName),
                    Escape(format, file.Path),
                    file.Size.ToString(CultureInfo.InvariantCulture)));
            }
        }
    }

    private static string Escape(ScanExportFormat format, string value)
    {
        // 制表符分隔:路径中不会出现制表符 / 换行,无需转义
        if (format == ScanExportFormat.Txt || value.IndexOfAny([',', '"', '\r', '\n']) < 0)
        {
            return value;
        }

        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }
}
