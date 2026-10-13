using System.Text.Json.Serialization;

namespace broom.Core;

/// <summary>隔离区中的一个文件:原位置、暂存位置与大小,用于还原与展示。</summary>
public sealed class QuarantineEntry
{
    public string OriginalPath { get; set; } = "";

    public string QuarantinePath { get; set; } = "";

    public long Size { get; set; }

    /// <summary>该文件已登记"重启后删除":重启时原位置会消失,不能按普通条目还原。</summary>
    public bool PendingReboot { get; set; }
}

/// <summary>一次清理对应一个隔离会话目录,清单记录其中已暂存的文件。</summary>
public sealed class QuarantineManifest
{
    public DateTimeOffset CreatedAt { get; set; }

    public List<QuarantineEntry> Entries { get; set; } = [];
}

/// <summary>隔离区清单的 JSON 源生成上下文(裁剪 / AOT 友好)。</summary>
[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(QuarantineManifest))]
internal sealed partial class QuarantineJsonContext : JsonSerializerContext
{
}
