# broom 后续增强 — 设计与验收标准

> 更新于 2026-10-13。记录计划功能的背景、方案、影响文件与验收标准;实现前先按本文档评审,实现时逐项落地。
> 建议实施顺序:① 扫描/清理取消 → ② 管理员提权 → ③ 重启后删除 → ④ 设置页 → ⑤ 文件级预览与单文件排除 → ⑥ 隔离区与撤销(依赖关系见文末)。
> 本文档聚焦已设计 / 已实现的功能;尚未排期的功能缺口与候选类目见 [backlog.md](backlog.md)。
> 实现状态(2026-10-13):四项已按建议顺序落地(取消 b34572d、提权 3b9b7e7、重启删除 08ae97c、设置 c0ecb96,取消边界补充 20d296c);引擎侧取消 / 排除前缀 / 设置持久化经临时校验程序验证,GUI 冒烟测试通过。
> 界面重构(2026-10-13):主窗口改为「侧边栏 + 清理 / 设置两页」结构,规则按类别分组并支持搜索、风险筛选与排序;新增 `Styles/Theme.axaml`(深浅色双主题设计变量)与 `Styles/Controls.axaml`(卡片、徽章、按钮、导航样式),设置页并入主窗口,移除 `SettingsWindow`。
> 文件明细(2026-10-13):第 5 项「文件级预览与单文件排除」已落地;扫描过滤(含大小写不敏感匹配)与设置序列化经临时校验程序验证,GUI 冒烟测试通过。
> 隔离区与撤销(2026-10-13):backlog P1 第 1 项立项并落地(本文档第 6 项);引擎侧移入 / 还原 / 冲突 / 清单 / 过期清理 / 重启后删除副本经临时校验程序验证(63 项通过),GUI 冒烟测试与设置页「隔离区」卡片渲染检查通过。
> P1 落地(2026-10-14):backlog P1 第 1 项的时间过滤部分(本文档第 7 项)与第 2 项(第 8 项)已实现;时间过滤的扫描 / 删除前复核、排除去重与校验经临时校验程序验证(12 项通过),GUI 冒烟测试通过。大小过滤语义未定,不在本期范围。
> 大小过滤定案(2026-10-14):不做引擎级大小过滤 —— 轻量需求以第 9 项「文件明细大小筛选」承接并已实现,深度需求归 backlog 第 20 项「大文件 / 磁盘占用分析」;评审依据见第 9 项顶部。

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

## 6. 隔离区与撤销

**目标**:把「永久删除」从不可逆操作变成可回退操作 —— 文件先移入 `%LOCALAPPDATA%\broom\quarantine`,清理报告可就地还原,隔离区按保留天数自动清理。

**现状(实现前)**

- 永久删除直接 `File.Delete`,删除后没有任何找回途径;
- 「清空回收站」规则整批交给 Shell 清空,连回收站自身都不再有兜底;
- 删除失败的项可以「重启后删除」延迟处理,但重启后同样不可恢复。

**方案**

1. 删除装饰器:新增 `Platform/QuarantineFileDeleter`(实现 `IFileDeleter`),把永久删除换成「移动进隔离区」;移动失败按原样记入失败列表,不回退为永久删除;
2. 目录结构:`quarantine\<yyyyMMdd-HHmmss>\<卷标>\<原路径>`,每次清理一个会话目录,会话内写 `manifest.json` 记录原路径 / 隔离路径 / 大小 / 是否已登记重启后删除;
3. 设置项 `QuarantineEnabled`(默认开启)、`QuarantineRetentionDays`(默认 7 天,0 = 永久保留);启动应用与保存设置时在后台清理过期会话;
4. 清理报告底部提供「还原本次隔离的 N 项」:按清单移回原位置,原位置已存在同名文件时不覆盖、给出原因并保留副本;
5. 设置页新增「隔离区」卡片:开关、保留天数、当前用量、打开隔离区、清空隔离区(两步确认);
6. 与「重启后删除」联动:登记前先复制一份到隔离区(登记后原文件会在重启时消失,因此复制而非移动);复制失败的项不登记并保留原因,已复制过的项重试时不会重复复制。

**边界与限制**

- 隔离区中的文件仍占用磁盘空间,超过保留天数后自动删除;跨盘移动等价于复制 + 删除,较慢;
- 「清空回收站」规则不经过隔离区,仍不可恢复;
- 已登记重启后删除的文件不能在原位置还原,需要从隔离区手动复制(撤销登记不在本期范围)。

**影响文件**

- 新增 `Core/QuarantineModels.cs`、`Platform/QuarantineService.cs`、`Platform/QuarantineSession.cs`、`Platform/QuarantineFileDeleter.cs`
- [Core/BroomSettings.cs](../Core/BroomSettings.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)

> 实现说明:装饰器只在「永久删除」路径启用(回收站本身可恢复,不重复暂存),非 Windows 平台没有回收站时同样走隔离区;会话目录按需创建,清单在每条规则处理完成后与登记重启删除后写入,写入失败不影响隔离本身(文件仍按原路径存放,可人工找回)。隔离区根目录可注入,便于校验程序在临时目录中验证。

**验收标准**

- 开启「永久删除」后清理:报告提示文件已移入隔离区,原位置消失,文件出现在 `%LOCALAPPDATA%\broom\quarantine\<时间戳>\<卷标>\...` 且清单记录原路径;
- 点击「还原本次隔离的 N 项」:文件回到原位置,会话目录随之清理,状态栏与报告给出结果;
- 原位置重新出现同名文件时该条不还原并给出原因,副本保留;
- 设置页关闭「先移入隔离区」后,清理恢复为直接永久删除,报告不再出现还原入口;
- 保留天数改为 1 天后重启应用,过期会话被自动删除;
- 登记「重启后删除」且隔离区开启时,隔离区中出现带标记的副本;复制失败的项目不被登记。

## 7. 按时间过滤(跳过最近修改的文件)

> 来源:backlog P1 第 1 项(时间部分)。

**目标**:「最近仍在用」的文件不被清理 —— 全局选项「跳过最近 N 天内修改过的文件」(0 = 不启用),让 `%TEMP%` 这类活跃目录的清理可预期。

**现状(实现前)**

- 扫描过滤只有规则模式与排除名单([Scanner.cs](../Services/Scanner.cs)),没有时间维度;正在下载、仍在滚动写入的临时文件会被列出并删除;
- 扫描到清理之间存在时间差:只在扫描阶段过滤,仍可能删到扫描之后刚被写入的文件。

**方案**

1. 设置模型:`Core/BroomSettings` 新增 `int SkipRecentDays`(默认 0 = 不启用);
2. 扫描阶段过滤:[Scanner](../Services/Scanner.cs) 对命中的文件按 `LastWriteTimeUtc` 判断,晚于 `UtcNow.AddDays(-SkipRecentDays)` 的文件不计入扫描结果(回收站规则不适用);
3. 删除前复核:[Cleaner](../Services/Cleaner.cs) 在删除前对同一条件再次校验,扫描与清理之间被重新写入的文件同样跳过 —— 「跳过最近修改」的承诺在删除时刻依然成立;跳过的文件不计入删除数与释放量;
4. 设置页「其他选项」卡片新增下拉(不启用 / 1 / 3 / 7 / 14 / 30 天),说明文字注明"按最后写入时间判断、对清空回收站不生效";
5. 过滤条件变化视为扫描结果失效,提示重新扫描(与排除项变化同等待遇)。

**边界与限制**

- 按「最后写入时间」判断:复制时保留原时间戳的文件可能被当作旧文件清理;
- 「清空回收站」规则整批交给 Shell,不做逐文件时间过滤;
- 按大小过滤(跳过小文件 vs. 只清大文件)语义未定,本期不做,明确语义后另行立项。

**影响文件**

- [Core/BroomSettings.cs](../Core/BroomSettings.cs)、[Services/Scanner.cs](../Services/Scanner.cs)、[Services/Cleaner.cs](../Services/Cleaner.cs)
- [ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)

> 实现说明:扫描与删除都按 `LastWriteTimeUtc` 对 `UtcNow` 判断(不受夏令时影响);删除前复核只影响实际尝试删除的文件,跳过项不进报告,也不计入删除数与释放量;时间过滤条件变化与排除项变化同等待遇,提示重新扫描;设置下拉的预设为 1 / 3 / 7 / 14 / 30 天,`settings.json` 中保存为 `skipRecentDays`。

**验收标准**

- 设置 7 天后扫描:最近 7 天内修改过的文件不出现,更早的文件正常列出并计数;
- 扫描后把某个已列出的文件改为当前时间,不重新扫描直接清理:该文件不被删除,也不计入释放量;
- 选择「不启用」后扫描/清理行为与之前完全一致;
- 重启应用后该设置仍生效。

## 8. 排除操作增强

> 来源:backlog P1 第 2 项。

**目标**:在文件明细里就能排除整个目录;保存设置时排除项自动去重并校验,无效行当面提示,不再"看起来生效了但匹配不上"。

**现状(实现前)**

- 明细行只有「排除」(单文件,写入 `ExcludedFiles`);排除所在目录必须去设置页手输路径前缀,不顺手;
- 设置页两个多行文本框按行原样解析([SettingsViewModel](../ViewModels/SettingsViewModel.cs) 的 `ParseLines`),重复行、相对路径、拼错的路径均无提示。

**方案**

1. [FileItemViewModel](../ViewModels/FileItemViewModel.cs) 增加「排除文件夹」命令:把该文件所在目录写入 `BroomSettings.ExcludedPaths`(目录前缀排除,任何规则下都跳过);
2. [MainWindowViewModel](../ViewModels/MainWindowViewModel.cs) 新增 `ExcludeDirectory`:与单文件排除同等待遇 —— 去重后持久化、同步设置页文本框、当前扫描结果中该目录下的文件立即移除,规则小计 / 顶部总计同步刷新;
3. [SettingsViewModel](../ViewModels/SettingsViewModel.cs) 保存时对两个排除列表去重(路径大小写规则与扫描器一致,Windows 不区分大小写),文本框回写去重后的结果,状态栏提示合并数量;
4. 基本校验:每行必须是绝对路径或包含 `%环境变量%`;无效行阻止保存,错误文案列出具体行(最多 3 行,超出用"等 N 项")。

**影响文件**

- [ViewModels/FileItemViewModel.cs](../ViewModels/FileItemViewModel.cs)、[ViewModels/RuleViewModel.cs](../ViewModels/RuleViewModel.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)
- [ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)

> 实现说明:目录排除沿用扫描器的段边界前缀语义(排除 `C:\Temp` 不影响 `C:\Temp2`),与单文件排除一样即时从当前结果移除,规则小计 / 顶部总计同步刷新;重复行合并后文本框回写规范化结果,合并数量并入状态栏提示;无效行(既非绝对路径也不含 `%ENV%`)阻止保存并列出具体行。

**验收标准**

- 文件明细行新增「排除文件夹」:点击后该目录下的文件从当前结果移除并立即生效;重新扫描后仍不出现;
- 在设置页删除对应行并保存后,重新扫描该目录下的文件恢复列出;
- 保存含重复行的排除项:保存成功,文本框合并为单行,状态栏提示已合并的重复项数量;
- 保存含相对路径 / 无效行的排除项:保存被阻止,错误文案指出具体行;修正后可保存。

## 9. 文件明细大小筛选

> 来源:backlog P1 第 1 项「按大小过滤」的定案(2026-10-14)。评审结论:**不做引擎级大小过滤** —— 「跳过小于 X」没有实际收益,「只清大文件」破坏清理完备性;对照 CCleaner 等同类工具,清理引擎只有时间阈值,「大小」能力都是独立的大文件分析(归 backlog 第 20 项),清理侧只保留轻量的展示筛选。

**目标**:文件明细里快速定位大文件 —— 「仅显示 ≥ X」下拉,配合已有的按体积降序与逐项排除,让人工决策有重点;纯展示,不影响清理范围。

**现状(实现前)**

- 明细按体积降序分批展示([RuleViewModel](../ViewModels/RuleViewModel.cs) 的 `ShowMoreFiles`),小文件多的规则要翻页才能看到排在后面的大文件;
- 引擎没有大小语义,时间过滤(第 7 项)之外没有其他过滤维度。

**方案**

1. [RuleViewModel](../ViewModels/RuleViewModel.cs) 增加大小筛选下拉(全部大小 / ≥ 1 MB / ≥ 10 MB / ≥ 100 MB / ≥ 1 GB),仅作用于该规则的明细展示;选择变化后重置分页,按新条件重新加载首批;
2. 筛选与排序叠加:先过滤再按体积降序,「显示更多」的剩余计数按筛选后的集合计算;
3. 筛选后为空时明细区提示"没有符合当前筛选的文件"(规则的「查看文件(N)」总数不受影响);
4. 不持久化:视图状态,每次启动回到「全部大小」;不改扫描 / 清理的任何行为。

**边界与限制**

- 仅是展示筛选:被筛掉的文件仍在清理范围内,勾选规则清理时照常删除(与「排除」语义严格区分);
- 引擎级大小过滤经评审不做,理由见本节顶部;深度的大小分析需求由 backlog 第 20 项「大文件 / 磁盘占用分析」承接。

**影响文件**

- [ViewModels/RuleViewModel.cs](../ViewModels/RuleViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)

> 实现说明:筛选下拉与逐规则的明细面板同处一格,状态不持久化、随会话重置;`ShowMoreFiles` 先按 `MinBytes` 过滤再按体积降序,分页计数基于筛选后的集合;筛选仅是视图,`GetSelectedResults` 的清理范围不变。展示逻辑经临时校验程序验证(10 项通过),GUI 冒烟测试通过。

**验收标准**

- 展开规则明细,选择「≥ 10 MB」:只显示不小于 10 MB 的文件,仍按体积降序,「显示更多」按筛选后的数量分批;
- 筛选后没有文件时给出提示文案,规则的「查看文件(N)」总数不变;
- 切回「全部大小」恢复完整明细;不触发重扫,也不改变本次清理的范围(被筛掉的文件照常可被清理)。

## 依赖关系与建议顺序

| 顺序 | 项 | 理由 |
|---|---|---|
| 1 | 扫描 / 清理取消 | 改动最小,只动 VM 与 UI,先落地 |
| 2 | 管理员提权 | 第 3 项的前置(登记重启后删除需要管理员) |
| 3 | 重启后删除 | 依赖第 2 项 |
| 4 | 设置页 | 工程量最大,且会改动规则合并与扫描过滤,放最后避免与其他项冲突 |
| 5 | 文件级预览与单文件排除 | 复用扫描结果与设置持久化,与其余各项独立 |
| 6 | 隔离区与撤销 | 只动删除路径与设置项,复用设置页持久化,排在最后不与其他项冲突 |
| 7 | 按时间过滤 | 只动扫描过滤、删除前复核与设置项,与其余各项独立 |
| 8 | 排除操作增强 | 复用文件明细与排除持久化,与第 7 项独立,可并行 |
| 9 | 文件明细大小筛选 | 只动明细展示层,与其余各项独立 |

各项相互独立,可单独交付;建议每项完成后跑一次「扫描 → 清理 → 报告」全流程,外加一次 GUI 冒烟测试(启动应用、确认窗口创建、关闭)。
