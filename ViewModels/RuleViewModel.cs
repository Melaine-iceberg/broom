using System.Collections.ObjectModel;
using broom.Core;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace broom.ViewModels;

/// <summary>单条清理规则在界面上的状态,含文件明细预览。</summary>
public partial class RuleViewModel : ObservableObject
{
    /// <summary>文件明细每批加载的条数 —— %TEMP% 这类目录可能有几十万文件,分批避免界面卡顿。</summary>
    private const int FilePreviewPageSize = 100;

    private readonly Action<string> _excludeFile;
    private readonly Action<string> _excludeDirectory;
    private readonly Action<string> _revealFile;
    private RuleScanResult? _scanResult;
    private List<ScannedFile>? _orderedFiles;
    private int _shownFiles;

    public RuleViewModel(CleanupRule rule, Action<string> excludeFile, Action<string> excludeDirectory, Action<string> revealFile)
    {
        Rule = rule;
        IsSelected = rule.Recommended;
        _excludeFile = excludeFile;
        _excludeDirectory = excludeDirectory;
        _revealFile = revealFile;
    }

    public CleanupRule Rule { get; }

    [ObservableProperty]
    private bool _isSelected;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SizeText))]
    private long _sizeBytes;

    [ObservableProperty]
    private string _statusText = "尚未扫描";

    [ObservableProperty]
    private bool _hasFailures;

    /// <summary>已加载到界面上的明细行(首批最多 <see cref="FilePreviewPageSize"/> 行)。</summary>
    public ObservableCollection<FileItemViewModel> Files { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(FilesToggleText))]
    private bool _isFilesExpanded;

    /// <summary>扫描结果中是否包含可逐个预览的文件(回收站规则没有文件列表)。</summary>
    public bool HasFiles => _scanResult is { Files.Count: > 0 };

    public string FilesToggleText =>
        IsFilesExpanded ? "收起文件" : $"查看文件({_scanResult?.Files.Count ?? 0:N0})";

    public bool HasMoreFiles => _orderedFiles is not null && _shownFiles < _orderedFiles.Count;

    public string ShowMoreText => $"显示更多(剩余 {(_orderedFiles?.Count ?? 0) - _shownFiles:N0} 项)";

    public string DisplayName => Rule.DisplayName;

    public string Description => Rule.Description;

    public bool RequiresAdmin => Rule.RequiresAdmin;

    public bool IsSafe => Rule.Risk == RiskLevel.Safe;

    public bool IsCaution => Rule.Risk == RiskLevel.Caution;

    public bool IsHigh => Rule.Risk == RiskLevel.High;

    public string RiskText => Rule.Risk switch
    {
        RiskLevel.Safe => "安全",
        RiskLevel.Caution => "谨慎",
        _ => "高风险",
    };

    /// <summary>文件明细的大小筛选选项(仅影响展示,不改变清理范围)。</summary>
    public IReadOnlyList<SizeFilterOption> SizeFilters => SizeFilterList;

    private static readonly SizeFilterOption[] SizeFilterList =
    [
        new(0, "全部大小"),
        new(1L << 20, "≥ 1 MB"),
        new(10L << 20, "≥ 10 MB"),
        new(100L << 20, "≥ 100 MB"),
        new(1L << 30, "≥ 1 GB"),
    ];

    [ObservableProperty]
    private SizeFilterOption _selectedSizeFilter = SizeFilterList[0];

    /// <summary>扫描结果里有文件,但当前筛选下明细为空(例如规则里没有大文件)。</summary>
    public bool ShowEmptyHint => IsFilesExpanded && Files.Count == 0 && HasFiles;

    public string SizeText => Formatting.FormatBytes(SizeBytes);

    /// <summary>扫描结果更新后绑定(传 null 表示回到"尚未扫描"),并重置文件预览。</summary>
    public void AttachScanResult(RuleScanResult? result)
    {
        _scanResult = result;
        ResetFiles();
        IsFilesExpanded = false;
        NotifyFilesChanged();
    }

    /// <summary>当前扫描数据变化(如排除了某个文件)后刷新明细,保留展开状态。</summary>
    public void RefreshFiles()
    {
        ResetFiles();
        if (!HasFiles)
        {
            IsFilesExpanded = false;
        }

        if (IsFilesExpanded)
        {
            ShowMoreFiles();
        }

        NotifyFilesChanged();
    }

    [RelayCommand]
    private void ToggleFiles()
    {
        if (!HasFiles)
        {
            return;
        }

        IsFilesExpanded = !IsFilesExpanded;
        if (IsFilesExpanded && Files.Count == 0)
        {
            ShowMoreFiles();
        }
    }

    [RelayCommand]
    private void ShowMoreFiles()
    {
        if (_scanResult is null)
        {
            return;
        }

        // 按体积降序,优先看到占用最大的文件;大小筛选只影响展示,先过滤再排序
        _orderedFiles ??= _scanResult.Files
            .Where(f => f.Size >= SelectedSizeFilter.MinBytes)
            .OrderByDescending(f => f.Size)
            .ToList();
        var end = Math.Min(_shownFiles + FilePreviewPageSize, _orderedFiles.Count);
        for (var i = _shownFiles; i < end; i++)
        {
            Files.Add(new FileItemViewModel(_orderedFiles[i], _excludeFile, _excludeDirectory, _revealFile));
        }

        _shownFiles = end;
        OnPropertyChanged(nameof(HasMoreFiles));
        OnPropertyChanged(nameof(ShowMoreText));
    }

    private void ResetFiles()
    {
        _orderedFiles = null;
        _shownFiles = 0;
        Files.Clear();
    }

    /// <summary>大小筛选变化:重置分页,按新条件重新加载明细。</summary>
    partial void OnSelectedSizeFilterChanged(SizeFilterOption value)
    {
        ResetFiles();
        if (IsFilesExpanded && HasFiles)
        {
            ShowMoreFiles();
        }

        NotifyFilesChanged();
    }

    private void NotifyFilesChanged()
    {
        OnPropertyChanged(nameof(HasFiles));
        OnPropertyChanged(nameof(FilesToggleText));
        OnPropertyChanged(nameof(HasMoreFiles));
        OnPropertyChanged(nameof(ShowMoreText));
        OnPropertyChanged(nameof(ShowEmptyHint));
    }
}

/// <summary>文件明细的大小筛选下拉项;只影响展示,不改变清理范围。</summary>
public sealed record SizeFilterOption(long MinBytes, string Label);
