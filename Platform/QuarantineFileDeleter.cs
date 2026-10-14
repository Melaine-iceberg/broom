using broom.Localization;

namespace broom.Platform;

/// <summary>
/// 删除装饰器:把"永久删除"换成"移入隔离区",失败项按原样记入失败列表(不回退为永久删除)。
/// </summary>
public sealed class QuarantineFileDeleter : IFileDeleter
{
    public QuarantineFileDeleter(QuarantineSession session) => Session = session;

    public string Name => Strings.T("隔离区(可还原)");

    public QuarantineSession Session { get; }

    public int Delete(IReadOnlyList<string> paths, IDictionary<string, string> failures, CancellationToken ct = default)
    {
        var quarantined = 0;
        foreach (var path in paths)
        {
            if (ct.IsCancellationRequested)
            {
                break;
            }

            if (Session.TryQuarantine(path, out var error))
            {
                quarantined++;
            }
            else
            {
                failures[path] = error;
            }
        }

        Session.Flush();
        return quarantined;
    }
}
