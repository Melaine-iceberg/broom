# broom 后续增强 — 设计与验收标准

> 更新于 2026-10-13。记录计划功能的背景、方案、影响文件与验收标准;实现前先按本文档评审,实现时逐项落地。
> 建议实施顺序:① 扫描/清理取消 → ② 管理员提权 → ③ 重启后删除 → ④ 设置页 → ⑤ 文件级预览与单文件排除(依赖关系见文末)。
> 本文档聚焦已设计 / 已实现的功能;尚未排期的功能缺口与候选类目见 [backlog.md](backlog.md)。
> 实现状态(2026-10-13):四项已按建议顺序落地(取消 b34572d、提权 3b9b7e7、重启删除 08ae97c、设置 c0ecb96,取消边界补充 20d296c);引擎侧取消 / 排除前缀 / 设置持久化经临时校验程序验证,GUI 冒烟测试通过。
> 界面重构(2026-10-13):主窗口改为「侧边栏 + 清理 / 设置两页」结构,规则按类别分组并支持搜索、风险筛选与排序;新增 `Styles/Theme.axaml`(深浅色双主题设计变量)与 `Styles/Controls.axaml`(卡片、徽章、按钮、导航样式),设置页并入主窗口,移除 `SettingsWindow`。
> 文件明细(2026-10-13):第 5 项「文件级预览与单文件排除」已落地;扫描过滤(含大小写不敏感匹配)与设置序列化经临时校验程序验证,GUI 冒烟测试通过。

## 1. 扫描 / 清理取消

**目标**:长时间扫描(`%TEMP%` 可能几十万文件、`Windows.old` 可能数 GB)可以随时中止,应用立刻回到空闲状态。

**现状**

- [Scanner.ScanAsync](../Services/Scanner.cs) 与 [Cleaner.CleanAsync](../Services/Cleaner.cs) 已经接受 `CancellationToken`,并在规则边界、批次边界、逐文件循环处调用 `ThrowIfCancellationRequested`;
- `MainWindowViewModel` 没有创建 `CancellationTokenSource`,UI 也没有取消入口;
- 取消异常目前会被 `catch (Exception)` 命中,显示成"扫描失败:操作已取消。"。

**方案**

1. `MainWindowViewModel` 增加字段 `CancellationTokenSource? _cts`,在 `ScanCoreAsync` / `CleanAsync` 开始时新建,`finally` 中释放并置空;
2. 新增 `[RelayCommand] private void Cancel() => _cts?.Cancel();`
3. 单独捕获 `OperationCanceledException`:状态栏显示"已取消";清理被取消时仍生成"部分清理报告"(已删项照常汇报),扫描被取消时丢弃半成品结果(保留上一次完整结果);
4. UI:忙碌期间显示"取消"按钮(或主按钮切换为取消);取消后进度条隐藏、按钮恢复。

**影响文件**

- [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)(主要)
- [MainWindow.axaml](../MainWindow.axaml)(取消按钮)
- 引擎层无需改动(令牌早已贯通)

> 实现说明:为了让“部分清理报告”包含已删项,删除器与 [Cleaner](../Services/Cleaner.cs) 改为取消时优雅停止(不抛异常);在规则执行过程中(含最后一条规则)取消同样标记 `WasCancelled` 并列出未执行规则。

**验收标准**

- 扫描 `%TEMP%` 过程中点击取消,1 秒内停止,界面恢复可操作,状态栏显示"已取消";
- 清理过程中取消:已成功删除的文件出现在报告中,未处理的规则标记为未执行;
- 取消后可以立即重新扫描,不残留旧状态。

## 2. 管理员提权

**目标**:让 `RequiresAdmin=true` 的规则(系统临时文件、更新下载缓存、`Windows.old`、组件日志、系统 WER…)真正可清理。

**现状**

- [Core/CleanupRule.cs](../Core/CleanupRule.cs) 已有 `RequiresAdmin` 标记,UI 显示"需要管理员"徽章;
- 未提权时相关删除会失败,仅体现在清理报告的失败列表里;应用没有提权入口。

**方案**

1. 平台抽象(为其他平台预留):`Platform/IElevationService`
   - `bool IsElevated { get; }`
   - `bool TryRestartElevated(out string? error)`
   - Windows 实现:用 `WindowsPrincipal.IsInRole(WindowsBuiltInRole.Administrator)` 检测提权状态;重启使用 `Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true, Verb = "runas" })`;用户拒绝 UAC(`Win32Exception.NativeErrorCode == 1223`)时返回失败原因,当前进程继续运行;
   - 非 Windows 实现:报告不支持。
2. UI:
   - 已提权:工具栏显示"已以管理员身份运行"徽章,提权按钮隐藏;
   - 未提权:显示"以管理员身份重启"按钮;
   - 未提权且勾选了需要管理员的规则:清理完成后在报告中提示"部分失败可通过提权重试"。
3. 重启为纯重启(不迁移勾选状态),启动后重新扫描即可。

**影响文件**

- 新增 `Platform/IElevationService.cs`、`Platform/WindowsElevationService.cs`
- [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)
- 另有 `Platform/PlatformServices.cs`(平台工厂 + 非 Windows 占位实现)

> 实现说明:Windows 侧用 `WindowsPrincipal.IsInRole` 检测提权;提权成功启动新实例后,由 [MainWindow](../MainWindow.axaml.cs) 关闭当前窗口退出(ShutdownMode.OnLastWindowClose)。

**验收标准**

- 未提权启动 → 点击按钮弹 UAC;确认后新进程 `IsElevated=true`,系统临时文件可清理;
- 拒绝 UAC → 提示"已取消提权",应用保持原状态正常运行;
- 已提权启动 → 提权按钮不出现,徽章正确显示。

## 3. 重启后删除(锁定文件兜底)

**目标**:对被占用、当前无法删除的文件提供"重启后删除",把失败项变成延迟成功。

**现状**

- 删除失败逐条记录在 `RuleCleanResult.Failures`([Core/ScanModels.cs](../Core/ScanModels.cs)),仅展示,没有后续动作;
- 报告中的失败原因典型为"文件被占用"。

**方案**

1. P/Invoke `MoveFileExW(existing, null, MOVEFILE_DELAY_UNTIL_REBOOT)`,加到 [Platform/WindowsShell.cs](../Platform/WindowsShell.cs);由系统写入注册表 `PendingFileRenameOperations`,重启时删除;
2. 抽象为 `Platform/IRebootDeleteService`(`bool TrySchedule(string path, out string error)`);Windows 实现标注 `[SupportedOSPlatform("windows")]`,其他平台返回不支持;
3. 交互(显式操作,不静默堆积):清理报告的失败列表旁提供"安排重启后删除(N)"按钮;完成后提示"已安排 X 项,重启后生效";
4. 前置条件:写 `PendingFileRenameOperations` 需要管理员;未提权时按钮禁用并提示先提权(与第 2 项联动)。

**边界与限制**

- 只可靠支持文件;目录不保证(`MoveFileEx` 的延迟删除以文件为主);
- 重启前文件仍在,不释放空间;
- 本期不做"撤销登记",取消需要用户自行重启或手动清理注册表。

**影响文件**

- [Platform/WindowsShell.cs](../Platform/WindowsShell.cs)、新增 `Platform/IRebootDeleteService.cs` / `Platform/WindowsRebootDeleteService.cs`
- [Services/Cleaner.cs](../Services/Cleaner.cs)(把失败列表完整暴露给 VM)
- [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)(报告区按钮)

> 实现说明:只有完整路径的失败项进入登记队列(`<回收站>` 等伪路径跳过);登记失败的项保留在队列中并附带系统原因。

**验收标准**

- 对锁定文件(可用一个被记事本打开的文件模拟)点击按钮后,注册表 `PendingFileRenameOperations` 出现对应项;
- 重启后文件消失;
- 未提权时按钮禁用并给出提示。

## 4. 设置页(自定义目录 / 排除规则持久化)

**目标**:用户可以追加自己的清理目录、维护排除规则、选择默认删除方式,并在重启后保留。

**现状**

- 规则集为内置的 [WindowsRuleSet.Create()](../Rules/WindowsRuleSet.cs),不可增改;
- 排除能力只有规则内置的 `ExcludePatterns`,没有用户级配置;
- 没有任何持久化。

**方案**

1. 配置模型 `Core/BroomSettings`
   - `List<CustomRule>`:路径、包含模式、排除模式、风险等级、是否默认勾选;
   - `List<string> ExcludedPaths`:全局排除路径前缀,任何规则命中都跳过;
   - `bool DefaultPermanentDelete`、`bool ShowHighRiskRules`(显示/隐藏高风险类目)。
2. 持久化:`Services/SettingsService` 读写 `%APPDATA%\broom\settings.json`(`Environment.SpecialFolder.ApplicationData`,跨平台自动落到对应目录);用 `System.Text.Json` + `JsonSerializerContext` 源生成(保持裁剪 / AOT 友好);解析失败时把坏文件改名为 `settings.bad.json` 后回退默认值。
3. 规则合并:启动时"内置规则 + 自定义规则";扫描过滤阶段追加"全局排除前缀"判断(路径前缀匹配)。
4. UI:侧边栏"设置"入口进入内嵌设置页(与"清理"页共用主窗口),三个分组 —— 自定义目录(列表增删)、排除规则(多行文本)、其他选项(默认永久删除、显示高风险);保存 / 放弃更改;保存后规则集合变化时提示或自动重扫。

**影响文件**

- 新增 `Core/BroomSettings.cs`、`Services/SettingsService.cs`、`ViewModels/SettingsViewModel.cs`、`ViewModels/CustomRuleViewModel.cs`
- [Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs)(规则合并入口调整)、[Services/Scanner.cs](../Services/Scanner.cs)(排除前缀过滤)
- [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)

> 实现说明:排除前缀按目录段边界匹配(避免 `C:\Temp` 误伤 `C:\Temp2`)并支持 `%ENV%` 展开;设置页内嵌在主窗口侧边栏中(原先为模态对话框 `SettingsWindow`,界面重构时并入主窗口),保存后仅在规则集或排除项变化时重置扫描状态并提示重扫。

**验收标准**

- 添加自定义目录 → 出现在规则列表,可扫描、可清理,大小正确;
- 排除某目录后,该目录文件不出现在任何规则的扫描结果中;
- 修改"默认永久删除"后重启应用仍生效;
- `settings.json` 被手动破坏后,应用仍能启动并回退默认值。

## 5. 文件级预览与单文件排除

**目标**:扫描后可查看每条规则命中的具体文件;对个别不应删除的文件可以单独排除,并在后续扫描中持续生效。

**方案**

1. 规则行「查看文件(N)」展开明细:按体积降序,首批 100 项,「显示更多」分批加载,避免 `%TEMP%` 这类几十万文件的目录卡顿;
2. 明细行提供「打开位置」(资源管理器中选中该文件)与「排除」两个操作;
3. 排除项写入 `BroomSettings.ExcludedFiles`(全局单文件排除),Scanner 在扫描阶段按完整路径跳过,与 `ExcludedPaths` 前缀排除并列;
4. 排除后立即从当前扫描结果与界面明细中移除,规则小计 / 顶部总计 / 分组小计同步刷新,本次清理不会删除该文件;
5. 设置页新增「排除的文件」多行文本框:删除对应行并保存后重新扫描,该文件重新纳入清理范围。

**影响文件**

- [Core/BroomSettings.cs](../Core/BroomSettings.cs)(新增 `ExcludedFiles`)、[Services/Scanner.cs](../Services/Scanner.cs)(排除过滤)
- [ViewModels/RuleViewModel.cs](../ViewModels/RuleViewModel.cs)(明细状态与分页)、新增 [ViewModels/FileItemViewModel.cs](../ViewModels/FileItemViewModel.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)
- [MainWindow.axaml](../MainWindow.axaml)(明细列表与设置卡片)、[Platform/WindowsShell.cs](../Platform/WindowsShell.cs)(`TryRevealInExplorer`)

**验收标准**

- 展开任意规则可见按体积降序的文件明细,超过 100 项可分批加载;回收站规则不显示明细入口;
- 点击「打开位置」在资源管理器中定位该文件;
- 点击「排除」后文件从明细与规则小计中消失,立即清理不会删除该文件;重启应用后再次扫描仍不会出现;
- 在设置页删除对应行并保存后,重新扫描该文件重新出现。

## 依赖关系与建议顺序

| 顺序 | 项 | 理由 |
|---|---|---|
| 1 | 扫描 / 清理取消 | 改动最小,只动 VM 与 UI,先落地 |
| 2 | 管理员提权 | 第 3 项的前置(登记重启后删除需要管理员) |
| 3 | 重启后删除 | 依赖第 2 项 |
| 4 | 设置页 | 工程量最大,且会改动规则合并与扫描过滤,放最后避免与其他项冲突 |
| 5 | 文件级预览与单文件排除 | 复用扫描结果与设置持久化,与其余各项独立 |

各项相互独立,可单独交付;建议每项完成后跑一次「扫描 → 清理 → 报告」全流程,外加一次 GUI 冒烟测试(启动应用、确认窗口创建、关闭)。
