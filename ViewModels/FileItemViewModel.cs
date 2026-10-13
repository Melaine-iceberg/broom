using broom.Core;
using CommunityToolkit.Mvvm.Input;

namespace broom.ViewModels;

/// <summary>清理明细中的一个文件:可打开所在位置或加入排除名单。</summary>
public sealed class FileItemViewModel
{
    public FileItemViewModel(ScannedFile file, Action<string> excludeFile, Action<string> revealFile)
    {
        FullPath = file.Path;
        FileName = Path.GetFileName(file.Path);
        DirectoryPath = Path.GetDirectoryName(file.Path) ?? "";
        SizeText = Formatting.FormatBytes(file.Size);
        ExcludeCommand = new RelayCommand(() => excludeFile(FullPath));
        RevealCommand = new RelayCommand(() => revealFile(FullPath));
    }

    public string FullPath { get; }

    public string FileName { get; }

    public string DirectoryPath { get; }

    public string SizeText { get; }

    public IRelayCommand ExcludeCommand { get; }

    public IRelayCommand RevealCommand { get; }
}
