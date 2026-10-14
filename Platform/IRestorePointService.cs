namespace broom.Platform;

/// <summary>
/// 系统还原点:清理前创建回滚点。
/// Windows 上通过 SRSetRestorePointW 实现,需要管理员权限与已开启的系统保护。
/// </summary>
public interface IRestorePointService
{
    /// <summary>
    /// 创建一个系统还原点。
    /// 失败(权限不足、系统保护未开启等)时返回 false 并给出面向用户的原因,不抛异常。
    /// </summary>
    bool TryCreateRestorePoint(string description, out string error);
}
