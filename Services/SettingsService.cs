using System.Text.Json;
using broom.Core;

namespace broom.Services;

/// <summary>
/// 读写设置文件 settings.json:默认在 %APPDATA%\broom(便携模式见 <see cref="AppPaths"/>:exe 同目录 data\)。
/// 文件损坏时改名为 settings.bad.json 并回退默认值,保证应用始终能启动。
/// </summary>
public sealed class SettingsService
{
    private readonly string _directory;
    private readonly string _filePath;

    /// <param name="directory">设置目录;留空时使用 <see cref="AppPaths.DataDirectory"/>(测试可注入临时目录隔离)。</param>
    public SettingsService(string? directory = null)
    {
        _directory = directory ?? AppPaths.DataDirectory;
        _filePath = Path.Combine(_directory, "settings.json");
    }

    public string FilePath => _filePath;

    public BroomSettings Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return new BroomSettings();
            }

            var json = File.ReadAllText(_filePath);
            return JsonSerializer.Deserialize(json, BroomJsonContext.Default.BroomSettings) ?? new BroomSettings();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            TryBackupCorruptedFile();
            return new BroomSettings();
        }
    }

    public void Save(BroomSettings settings)
    {
        Directory.CreateDirectory(_directory);
        var json = JsonSerializer.Serialize(settings, BroomJsonContext.Default.BroomSettings);
        File.WriteAllText(_filePath, json);
    }

    private void TryBackupCorruptedFile()
    {
        try
        {
            File.Move(_filePath, Path.Combine(_directory, "settings.bad.json"), overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 备份失败不影响回退默认值
        }
    }
}
