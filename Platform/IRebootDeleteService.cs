namespace broom.Platform;

/// <summary>
/// 重启后删除抽象:把当前无法删除(被占用等)的文件登记到系统的重启时删除队列。
/// Windows 上依赖 PendingFileRenameOperations,需要管理员权限。
/// </summary>
public interface IRebootDeleteService
{
    /// <summary>当前平台是否支持重启后删除。</summary>
    bool IsSupported { get; }

    /// <summary>
    /// 登记单个文件在下次重启时删除。
    /// 失败(如权限不足、路径不存在)时返回 false 并给出系统原因。
    /// </summary>
    bool TrySchedule(string path, out string error);
}
