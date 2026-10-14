using broom.Core;
using CommunityToolkit.Mvvm.Input;

namespace broom.ViewModels;

/// <summary>清理明细中的一个文件:可打开所在位置、排除该文件或排除所在文件夹。</summary>
public sealed class FileItemViewModel
{
    public FileItemViewModel(ScannedFile file, Action<string> excludeFile, Action<string> excludeDirectory, Action<string> revealFile)
    {
        FullPath = file.Path;
        FileName = Path.GetFileName(file.Path);
        DirectoryPath = Path.GetDirectoryName(file.Path) ?? "";
        SizeText = Formatting.FormatBytes(file.Size);
        ExcludeCommand = new RelayCommand(() => excludeFile(FullPath));
        ExcludeDirectoryCommand = new RelayCommand(() => excludeDirectory(DirectoryPath), () => DirectoryPath.Length > 0);
        RevealCommand = new RelayCommand(() => revealFile(FullPath));
    }

    public string FullPath { get; }

    public string FileName { get; }

    public string DirectoryPath { get; }

    public string SizeText { get; }

    public IRelayCommand ExcludeCommand { get; }

    public IRelayCommand ExcludeDirectoryCommand { get; }

    public IRelayCommand RevealCommand { get; }
}
