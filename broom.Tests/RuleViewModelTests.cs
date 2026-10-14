using broom.Core;
using broom.ViewModels;

namespace broom.Tests;

public class RuleViewModelTests
{
    private static readonly CleanupRule Rule = new() { Id = "t", DisplayName = "t", Paths = ["x"] };

    private static RuleViewModel CreateVm(params ScannedFile[] files)
    {
        var result = new RuleScanResult { Rule = Rule };
        foreach (var file in files)
        {
            result.Files.Add(file);
            result.TotalBytes += file.Size;
            result.ItemCount++;
        }

        var vm = new RuleViewModel(Rule, _ => { }, _ => { }, _ => { });
        vm.AttachScanResult(result);
        vm.ToggleFilesCommand.Execute(null);
        return vm;
    }

    [Fact]
    public void Files_DefaultToAllSortedBySizeDescending()
    {
        var vm = CreateVm(
            new ScannedFile(@"C:\a.tmp", 100),
            new ScannedFile(@"C:\f.tmp", 2L << 30),
            new ScannedFile(@"C:\c.tmp", 5L << 20));

        Assert.Equal(3, vm.Files.Count);
        Assert.Equal("f.tmp", vm.Files[0].FileName);
    }

    [Fact]
    public void SizeFilter_KeepsOnlyLargeFilesAndOrder()
    {
        var vm = CreateVm(
            new ScannedFile(@"C:\a.tmp", 100),
            new ScannedFile(@"C:\d.tmp", 30L << 20),
            new ScannedFile(@"C:\f.tmp", 2L << 30));

        vm.SelectedSizeFilter = vm.SizeFilters.First(o => o.MinBytes == 10L << 20);

        Assert.Equal(2, vm.Files.Count);
        Assert.Equal("f.tmp", vm.Files[0].FileName);
        Assert.Equal("d.tmp", vm.Files[1].FileName);
    }

    [Fact]
    public void SizeFilter_DoesNotChangeTotalCount()
    {
        var vm = CreateVm(new ScannedFile(@"C:\a.tmp", 100), new ScannedFile(@"C:\f.tmp", 2L << 30));
        vm.SelectedSizeFilter = vm.SizeFilters.First(o => o.MinBytes == 1L << 30);
        vm.ToggleFilesCommand.Execute(null); // 收起后按钮显示总数

        Assert.Equal("查看文件(2)", vm.FilesToggleText);
    }

    [Fact]
    public void SizeFilter_EmptyResultShowsHint()
    {
        var vm = CreateVm(new ScannedFile(@"C:\a.tmp", 100));

        vm.SelectedSizeFilter = vm.SizeFilters.First(o => o.MinBytes == 1L << 20);

        Assert.Empty(vm.Files);
        Assert.True(vm.ShowEmptyHint);
    }

    [Fact]
    public void SizeFilter_ResetRestoresAllFiles()
    {
        var vm = CreateVm(new ScannedFile(@"C:\a.tmp", 100), new ScannedFile(@"C:\f.tmp", 2L << 30));
        vm.SelectedSizeFilter = vm.SizeFilters.First(o => o.MinBytes == 1L << 30);

        vm.SelectedSizeFilter = vm.SizeFilters[0];

        Assert.Equal(2, vm.Files.Count);
        Assert.False(vm.ShowEmptyHint);
    }

    [Fact]
    public void SizeFilter_PagingCountsUseFilteredSet()
    {
        var files = new List<ScannedFile>();
        for (var i = 0; i < 250; i++)
        {
            files.Add(new ScannedFile($@"C:\s{i}.tmp", 1L << 20));
        }

        for (var i = 0; i < 5; i++)
        {
            files.Add(new ScannedFile($@"C:\b{i}.tmp", 50L << 20));
        }

        var vm = CreateVm([.. files]);
        Assert.True(vm.HasMoreFiles);

        vm.SelectedSizeFilter = vm.SizeFilters.First(o => o.MinBytes == 10L << 20);

        Assert.Equal(5, vm.Files.Count);
        Assert.False(vm.HasMoreFiles);
    }
}
