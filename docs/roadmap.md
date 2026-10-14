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
> 安全擦除(2026-10-14):backlog P1 第 3 项(本文档第 10 项)已实现,覆写落在永久删除与隔离区清理两个销毁点;验证情况见该项实现说明。
> 清理前创建还原点(2026-10-14):backlog P1 第 4 项(本文档第 11 项)已实现 —— **P1「安全与可控」四项全部完成**;验证情况见该项实现说明。
> 单元测试项目(2026-10-14):backlog 第 25 项(本文档第 12 项)已落地 —— `broom.Tests` 64 个测试覆盖扫描 / 清理 / 设置 / 规则不变量与 P1 已交付能力,根目录 `dotnet test` 全量回归;详见该项实现说明。
> CI(2026-10-14):backlog 第 26 项(本文档第 13 项)已落地并真实运行验证 —— 首次运行变红(暴露测试的环境假设)、修复后全绿(run 38529460180);工程基础(#25 测试、#26 CI)就绪。
> P2 规则扩充(2026-10-14):backlog 第 6–8 项(本文档第 14 项)已落地 —— 系统垃圾 / 应用缓存 / 浏览器覆盖共新增 15 条规则;聊天类只清缓存子目录、浏览器隐私独立成组且默认不勾选;动作型类目(事件日志 / DNS / DriverStore)留待「动作型规则」模型,见第 14 项。
> P4 三个小件(2026-10-14):backlog 第 15–17 项(本文档第 15–17 项)已落地 —— 磁盘空间前后对比、勾选状态持久化、报告复制与扫描明细导出;验证情况见各项实现说明。
> P2 收口(2026-10-14):「动作型规则」模型落地(本文档第 18 项),backlog 第 10、11 项与第 6 项遗留的事件日志 / DNS 类目随之实现;backlog 第 9 项(本文档第 19 项)以「清理后移除空目录」开关落地 —— **P2 全部完成**,仅 DriverStore 类目继续遗留。

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

## 10. 安全擦除(覆写删除)

> 来源:backlog P1 第 3 项。

**目标**:敏感残留文件在真正永久删除时先被覆写,降低事后恢复的可行性;覆写策略由用户显式开启(默认关闭)。

**现状(实现前)**

- [PermanentFileDeleter](../Platform/PermanentFileDeleter.cs) 直接 `File.Delete`,数据残留在磁盘空闲空间,可被恢复工具找回;
- 「永久删除 + 隔离区」(默认组合)下文件先移入隔离区(第 6 项),真正销毁发生在隔离区清理([QuarantineService](../Platform/QuarantineService.cs) 整目录 `Directory.Delete`),同样没有覆写 —— **隔离区清理才是实际销毁点,覆写必须落在这里**;
- 没有相关设置项,也没有任何风险说明。

**方案**

1. 设置模型:`Core/BroomSettings` 新增 `int SecureErasePasses`(0 = 不覆写,可选 1 / 3;默认 0);
2. 覆写实现:新增 `Platform/SecureErase.OverwriteAndDelete` —— 按文件长度用随机数据覆写 N 次,每次 `Flush(true)` 尽量落盘,然后删除;0 字节文件直接删除;
3. [PermanentFileDeleter](../Platform/PermanentFileDeleter.cs) 接受覆写次数,开启后走 `OverwriteAndDelete`;不存在的文件保持原语义"视为已清理";
4. 隔离区清理改为逐文件销毁:[QuarantineService](../Platform/QuarantineService.cs) 的过期清理与「清空隔离区」在开启覆写时逐文件"覆写后删除",再回收空目录;整目录递归删除只在覆写关闭时使用;
5. **失败语义**:覆写失败(被占用、只读等)的文件**不删除**,计入失败列表并给出原因 —— 宁可留下文件,也不无声跳过"不可恢复"的承诺;需要强制删除时关闭覆写重试即可;
6. UI:设置页「其他选项」新增"安全擦除"下拉(不覆写 / 覆写 1 次 / 覆写 3 次)与风险说明;清理报告在开启时按删除路径提示覆写次数与适用范围。

**边界与限制**

- 对 SSD / NVMe(磨损均衡、FTL)与写时复制文件系统(ReFS、Dev Drive)效果有限,主要在机械硬盘(HDD)上有意义;
- 不经过覆写:回收站删除与清空回收站(Shell 管理,无法逐文件覆写)、移入隔离区本身(销毁发生在隔离区清理时)、「重启后删除」(由系统在重启时执行)、VSS 快照 / 休眠文件中的历史副本;
- 覆写耗时与文件体积成正比,3 次覆写约为 1 次的三倍;默认关闭。

**影响文件**

- 新增 `Platform/SecureErase.cs`;[Platform/PermanentFileDeleter.cs](../Platform/PermanentFileDeleter.cs)、[Platform/QuarantineService.cs](../Platform/QuarantineService.cs)
- [Core/BroomSettings.cs](../Core/BroomSettings.cs)、[ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)

> 实现说明:覆写用 `RandomNumberGenerator` 随机数据按文件长度逐块写入,每轮 `Flush(true)` 尽量落盘;`PermanentFileDeleter` 与 `QuarantineService.DeleteTree` 共用 `Platform/SecureErase`,隔离区在覆写模式下不再整目录递归删除(只回收空目录),失败语义见方案第 5 条。覆写后删除 / 内容覆盖(硬链接观察)/ 失败保留 / 隔离区清理覆写 / 过期清理经临时校验程序验证(13 项通过),GUI 冒烟测试通过。

**验收标准**

- 开启「覆写 1 次」+ 关闭隔离区后清理:文件消失;通过指向同一数据的硬链接观察,内容已被随机数据覆盖,不再是原明文;
- 被占用的文件:覆写失败、文件保留,并在清理报告的失败列表中给出原因,不被静默删除;
- 开启覆写 + 隔离区(默认组合):本次清理先移入隔离区,「清空隔离区」后内容被覆写再删除(硬链接观察),覆写失败的文件保留在隔离区中;
- 关闭覆写:行为与之前完全一致(含"文件不存在视为已清理");
- 重启应用后设置仍生效;开启时清理报告给出覆写次数与"SSD / 写时复制文件系统效果有限"的提示。

## 11. 清理前创建系统还原点

> 来源:backlog P1 第 4 项(P1 收尾)。

**目标**:批量清理之前自动创建一个 Windows 系统还原点,给系统类目的清理提供一键回滚;创建失败不阻塞清理。

**现状(实现前)**

- 回滚只有隔离区(文件级、有保留期限)一层;系统类目(系统临时、更新缓存、`Windows.old` 等)删除后没有系统级回滚手段;
- 没有任何还原点相关能力。

**方案**

1. 平台抽象:`Platform/IRestorePointService`(`bool TryCreateRestorePoint(string description, out string error)`);Windows 实现 `Platform/WindowsRestorePointService` P/Invoke `srclient.dll!SRSetRestorePointW`(`BEGIN_SYSTEM_CHANGE` + `MODIFY_SETTINGS`,描述 256 字符内截断),按 `nStatus` 映射失败原因(5 = 需要管理员,1058 = 系统保护未开启,其余给错误码);非 Windows 平台由 [PlatformServices](../Platform/PlatformServices.cs) 返回占位实现;
2. 设置模型:`Core/BroomSettings.CreateRestorePointBeforeClean`(默认关闭 —— 创建耗时、需要提权、占用系统保护空间,由用户显式开启);
3. 清理流程:[MainWindowViewModel](../ViewModels/MainWindowViewModel.cs) 的清理在删除前(开启时)后台尝试创建还原点,描述为「broom 清理前还原点(时间)」;结果作为一行并入清理报告:成功给出名称,失败给出原因并注明"本次删除无法通过还原点回滚";
4. 失败不阻塞:未提权、系统保护未开启、API 失败都只提示,清理照常进行;
5. UI:设置页新增「系统还原点」卡片(开关 + 说明);说明中注明与 backlog 第 10 项「系统还原点与卷影副本清理」的语义冲突 —— 启用那类清理规则会删掉这些回滚点。

**边界与限制**

- 仅 Windows 且需要管理员权限;还原点只覆盖启用了系统保护的卷(通常为系统盘),对其他盘上的删除无效;
- Windows 对还原点创建有频率限制(部分版本默认每 24 小时一个),重复创建可能被合并,报告如实反映 API 结果;
- 与隔离区互补而非替代:隔离区管文件级回滚(可还原单个文件),还原点管系统状态回滚(整体回退);
- 「重启后删除」的登记写在注册表,还原点回滚后需人工复核该项登记。

**影响文件**

- 新增 `Platform/IRestorePointService.cs`、`Platform/WindowsRestorePointService.cs`;[Platform/PlatformServices.cs](../Platform/PlatformServices.cs)(工厂 + 非 Windows 占位)
- [Core/BroomSettings.cs](../Core/BroomSettings.cs)、[ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)

> 实现说明:结构体按 `RESTOREPOINTINFOW` / `STATEMGRSTATUS` 的原生布局编组(528 / 16 字节,经校验);失败原因按 `nStatus` 映射(5 → 需要管理员,1058 → 系统保护未开启),创建在 `Task.Run` 中执行不阻塞界面。结构体布局、工厂 / 占位实现、真实 API 失败路径(非提权下调用返回「需要管理员权限」)与设置流转经临时校验程序验证(7 项通过);提权 + 系统保护开启下的真实创建需人工验收;GUI 冒烟测试通过。

**验收标准**

- 提权 + 系统保护开启 + 设置开启:清理前创建还原点,「创建还原点」列表出现「broom 清理前还原点(...)」,清理报告给出同样信息;
- 未提权:报告提示"需要管理员权限,本次跳过",清理照常完成;
- 系统保护未开启:报告给出对应提示,清理照常完成;
- 关闭设置:清理过程不调用 API,报告无还原点相关行;
- 重启应用后设置仍生效;创建失败(任意原因)都不阻塞、不中断本次清理。

## 12. 单元测试项目(回归防线)

> 来源:backlog 第 25 项(工程基础);此前历次功能靠临时校验程序验证,用完即删、不可回归。

**目标**:把扫描 / 清理 / 设置 / 规则不变量固化为可重复运行的单元测试,任何改动都能一键回归;为 CI(backlog 第 26 项)提供 `dotnet test` 入口。

**现状(实现前)**

- 仓库没有任何测试项目;P1 各项的验证程序均为临时产物;
- [SettingsService](../Services/SettingsService.cs) 写死 `%APPDATA%\broom`,无法在临时目录中隔离测试。

**方案**

1. 新增 `broom.Tests`(xUnit,目标框架与主项目一致),项目引用主工程;`broom.sln` 收纳两个项目,根目录 `dotnet test` 即可全量回归;
2. 主工程开放内部可见:[broom.csproj](../broom.csproj) 增加 `InternalsVisibleTo("broom.Tests")`(还原点结构体布局等编组测试需要);
3. 可测性改造(唯一的产品代码改动):[SettingsService](../Services/SettingsService.cs) 构造函数支持注入目录(默认仍为 `%APPDATA%\broom`,行为不变),沿用 `QuarantineService` 根目录可注入的既有做法;
4. 覆盖范围(backlog 建议 + 已交付能力固化):
   - **Scanner**:路径模板展开(环境变量 / 通配符)、包含与排除模式、全局排除目录(段边界)与排除文件、`skipRecentDays` 时间过滤;
   - **Cleaner**:删除与失败统计、取消(`WasCancelled` / `SkippedRules`)、`skipRecentDays` 删除前复核、`BytesRemoved` 只计实际删除;
   - **SettingsService**:读写往返、文件缺失返回默认值、损坏 JSON 改名 `settings.bad.json` 并回退;
   - **规则不变量**([WindowsRuleSet](../Rules/WindowsRuleSet.cs)):Id 非空且唯一、显示名 / 类别非空、Paths 类规则路径模板非空、`Recommended` 只出现在安全项、平台标识一致、自定义规则合并;
   - **P1 已交付能力**:安全擦除(硬链接观察内容已覆写、失败保留、隔离区清理覆写)、设置去重 / 校验、明细大小筛选、还原点结构体编组布局与占位实现。
5. 不测:真实 GUI 交互(保留冒烟流程)、真实的系统还原点创建(有系统副作用,沿用提权人工验收)、真实回收站 Shell 调用。

**影响文件**

- 新增 `broom.Tests/`(测试项目)、`broom.sln`
- [broom.csproj](../broom.csproj)、[Services/SettingsService.cs](../Services/SettingsService.cs)

> 实现说明:64 个测试分 8 个测试类,全部使用临时目录、互不共享状态;`broom.slnx`(.NET 10 默认格式)收纳两个项目。测试落地过程中发现并修复一处统计问题:取消时未处理的文件尾部曾被计入 `BytesRemoved`(改为按已处理前缀统计);另做了变异验证 —— 注掉删除前复核后 `Clean_SkipRecentDays_RechecksBeforeDeleting` 变红。`dotnet test` 64/64 通过并重复运行稳定,GUI 冒烟通过。

**验收标准**

- 根目录 `dotnet test` 全部通过,重复运行结果稳定(测试无共享状态,全部使用临时目录);
- 覆盖范围内的行为均有断言:时间过滤(扫描 + 删除前复核)、排除段边界、取消统计、损坏设置回退、规则不变量、安全擦除覆写语义;
- 人为破坏任一被测行为(例如去掉删除前复核)后对应测试变红;
- 主程序行为不变(默认设置路径不落地测试目录,GUI 冒烟通过)。

## 13. CI(构建 + 测试)

> 来源:backlog 第 26 项(工程基础)。

**目标**:每次 push / PR 自动构建并运行单元测试,把第 12 项的回归防线前移到提交时刻;为后续发布打包留出可复用的工作流骨架。

**现状(实现前)**

- 仓库没有 `.github`,PR 无自动构建与测试,问题只能本地发现;
- `broom.Tests`(第 12 项)已就绪,`dotnet test broom.slnx` 可一键回归。

**方案**

1. 新增 [.github/workflows/ci.yml](../.github/workflows/ci.yml):
   - 触发:push 到 `main` + 所有 pull_request;
   - `windows-latest`:回收站 / 提权 / 还原点均为 Windows 能力,测试只在 Windows 上完整生效;
   - 步骤:checkout → `actions/setup-dotnet`(`10.0.x`,与 `TargetFramework=net10.0` 对齐)→ NuGet 缓存(`actions/cache`,键含 csproj 哈希)→ `dotnet restore` → `dotnet build -c Release --no-restore` → `dotnet test -c Release --no-build`;
   - 最小权限:`permissions: contents: read`。
2. CI 用 Release 配置(发布口径;诊断支持包按 `Configuration` 条件裁剪,恰好覆盖两套配置的构建差异);
3. 本项范围外:多平台矩阵(引擎尚无 macOS / Linux 规则集,见 backlog 第 24 项)、格式检查、发布打包工作流(backlog 第 19 项)。

**影响文件**

- 新增 `.github/workflows/ci.yml`

> 实现说明:工作流含 NuGet 缓存(`actions/cache`,键含 csproj 哈希)与最小权限 `contents: read`。真实运行记录:首次推送 run 38528754694 变红 —— 环境差异暴露(CI 的 `%TEMP%` 是 8.3 短路径 `RUNNER~1`,路径展开测试断言过严),顺带验证了「CI 能变红」;修复测试后 run 38529460180 全绿(Restore / Build / Test 全通过,64 个测试,约 1 分半)。

**验收标准**

- 提交并推送后 Actions 出现「CI」工作流,构建 + 64 个测试全绿;
- 人为制造编译错误或失败测试后,CI 变红并体现在 PR 状态上;
- 工作流只带 `contents: read` 最小权限;
- 本地按同一组 Release 命令执行与 CI 一致且通过。

## 14. P2 规则扩充(系统垃圾 / 应用缓存 / 浏览器覆盖)

> 来源:backlog 第 6–8 项(P2 · 清理覆盖面)。

**目标**:把三类高频缺口一次补齐 —— 系统垃圾(预读取、传递优化、升级残留、字体缓存、使用痕迹)、常用应用缓存(微信 / QQ / 钉钉、Teams / Discord / Slack、Office / OneDrive、Spotify、商店应用)、浏览器覆盖(Brave / Opera / Vivaldi / 360 / QQ 浏览器,以及可选的隐私数据);新增类目一律默认不勾选,由用户逐项确认。

**现状(实现前)**

- 规则集只有 22 条:系统临时 / 缓存、Chrome / Edge / Firefox 缓存、开发者缓存、回收站等;应用缓存完全空白,小众与国产浏览器不覆盖;
- 聊天类应用的缓存与聊天记录同处一个数据根,误清聊天记录不可接受(backlog 第 7 项风险),必须精确到缓存子目录;
- 浏览器隐私数据(历史 / Cookie / 会话)清理语义敏感,需要独立分组、默认不勾选并明确后果(backlog 第 8 项风险)。

**方案**

1. 系统垃圾(backlog 第 6 项,只做纯文件类目):新增 `system-prefetch`(Prefetch)、`delivery-optimization`(传递优化下载缓存)、`upgrade-residue`(`$WinREAgent` / `Panther` / `MoSetup` 升级残留与安装日志)、`user-font-cache` / `system-font-cache`(字体缓存,删除后自动重建)、`usage-traces`(最近使用的文档与跳转列表,含固定项)。**动作型类目范围外**:事件日志清空(API)、DNS 缓存刷新(`ipconfig /flushdns`)、DriverStore 旧驱动包(`pnputil`)需要引擎新增「动作型规则」模型与失败处理,与第 10 / 11 项的 VSS / DISM 一并设计;
2. 应用缓存(backlog 第 7 项):新增 `chat-wechat` / `chat-qq` / `chat-dingtalk` / `collab-cache` / `office-onedrive` / `media-spotify` / `uwp-localcache`。**聊天类只清缓存子目录**:微信 / QQ 精确到 `FileStorage\Cache` / `FileStorage\Temp`(账号目录用通配段展开),钉钉只清 `defEmotion` / `AvatarFiles` / `ImageFiles`;聊天记录数据库、FileRecv 与图片 / 视频 / 文件原目录不进扫描范围。UWP 只清 `LocalCache\Local|Low|Roaming`,不触碰 `LocalState` / `RoamingState` 中的应用数据;Teams / Discord / Slack 只清网页与渲染缓存,设置、登录令牌与本地数据库不进范围;
3. 浏览器覆盖(backlog 第 8 项):`browser-cache` 覆盖面从 Chrome / Edge / Firefox 扩到 Brave / Opera(含 GX)/ Vivaldi / 360 / QQ 浏览器,并补上 Chromium 系通用缓存目录(`DawnCache`)与 Firefox 的 Roaming 配置位置(原路径只有 `%LOCALAPPDATA%`,标准部署在 `%APPDATA%`);隐私数据不并入缓存规则,新增独立的 `browser-privacy-cookies` 与 `browser-privacy-history`,按文件名模式在配置档案下精确匹配,明确不碰已保存的密码(`Login Data` / `Web Data`);
4. 新类别「使用痕迹」「浏览器隐私」「应用缓存」进入界面分组排序([MainWindowViewModel](../ViewModels/MainWindowViewModel.cs) 的 `CategoryOrder`),沿用搜索与风险筛选;
5. 浏览器覆盖面(配置档案根 + 缓存子目录)抽成 [WindowsRuleSet](../Rules/WindowsRuleSet.cs) 内的共享数据,缓存规则与隐私规则共用,避免两处漂移。

**影响文件**

- [Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs)(新增 15 条规则、浏览器配置档案根 / 缓存子目录共用数据)
- [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)(分组排序)
- [broom.Tests/WindowsRuleSetTests.cs](../broom.Tests/WindowsRuleSetTests.cs)(新不变量测试)

> 实现说明:15 条新规则全部是纯数据、默认不勾选;浏览器覆盖面集中在 `ChromiumProfileRoots` / `FirefoxProfileRoots` 与 `ChromiumCacheFolders` 三份共享数据上,`browser-cache` 与两条隐私规则共用,顺带给 Chromium 系补 `DawnCache`、把 Firefox 缓存位置从只有 `%LOCALAPPDATA%` 扩到标准的 `%APPDATA%`。隐私规则用 `IncludePatterns` 在配置档案下按文件名精确匹配(`Login Data` / `Web Data` 明确不列入);聊天类规则的路径模板一律以 `Cache` / `Temp`(钉钉为 `defEmotion` / `AvatarFiles` / `ImageFiles`)结尾,由测试 `ChatCacheRules_OnlyCleanCacheSubdirectories` 锁死,防止后续改动误把账号根目录放进扫描范围。验证:新增 9 个测试(缓存子目录精确性、隐私规则高风险且不勾选、不碰已保存的密码、浏览器覆盖标记、UWP 不碰 LocalState / RoamingState、15 条新规则存在且默认不勾选),`dotnet test` 73/73 通过并重复运行稳定;临时校验程序在真实机器上对含 `browser-cache` 在内的 16 条规则做只读全量扫描,0 报错 —— 未安装的类目为 0(本机未装浏览器 / 微信等,符合预期),已安装的类目命中(Panther 4 项、Recent 353 项、Office / OneDrive 日志 62 项、UWP LocalCache 42 个根 1892 个文件约 988MB);非提权下 Prefetch 与系统字体缓存目录按 `IgnoreInaccessible` 静默跳过,提权后可清;GUI 冒烟通过(启动 12 秒无异常后正常退出)。

**验收标准**

- 规则列表出现「使用痕迹」「浏览器隐私」「应用缓存」三个新分组,15 条新规则全部默认不勾选;
- 未安装的类目(路径不存在)扫描为 0 且无报错;已安装的类目能扫出并可清理;
- 微信 / QQ 的扫描根只落在 `FileStorage\Cache` / `FileStorage\Temp`,清理后聊天记录数据库与文件原目录完好(测试断言 + 人工抽查);
- 勾选「浏览器 Cookie 与登录状态」清理后各浏览器需重新登录;「浏览器历史与会话」不影响书签与已保存的密码;
- 根目录 `dotnet test` 全部通过,GUI 冒烟通过。

## 15. 磁盘空间前后对比

> 来源:backlog 第 15 项(P4 · 体验与分发)。

**目标**:清理报告直接回答「实际释放了多少」——按本次清理涉及的盘符给出清理前后可用空间与差值,而不是只看计入的字节数。

**现状(实现前)**

- 报告只统计删除项数与字节;回收站删除(仍占用空间)、覆写、并发写盘等场景下,计入值与磁盘实际释放有出入;
- 用户要自己去资源管理器核对可用空间,报告没有自证能力。

**方案**

1. [Cleaner](../Services/Cleaner.cs) 在删除前后对涉及盘符各采样一次可用空间,差值写入 `CleanupReport.DriveSpace`;含回收站规则时覆盖全部就绪的固定磁盘(回收站分布在各盘),否则按被删文件所在盘;
2. 采样失败(读不到)的盘静默跳过、不阻塞清理;清理被取消时同样给出已完成部分的对比;
3. 报告在删除方式提示之前按盘输出「磁盘 X 可用空间:前 → 后(本次释放 +N)」,可用空间不增反减时如实展示并注明可能受其他程序活动影响;
4. 采样函数可注入(默认 `DriveInfo.AvailableFreeSpace`),单元测试用假探针验证前后值与差值;「累计释放」的历史统计仍归 backlog 第 14 项。

**影响文件**

- [Core/ScanModels.cs](../Core/ScanModels.cs)(`DriveSpaceDelta` 与 `CleanupReport.DriveSpace`)
- [Services/Cleaner.cs](../Services/Cleaner.cs)(采样与盘符收集)
- [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)(报告文案)
- [broom.Tests/CleanerTests.cs](../broom.Tests/CleanerTests.cs)

> 实现说明:盘符收集与探针都在 Cleaner 内,默认探针读取失败返回 null 即该盘不进对比;报告行放在「清理 N 项」摘要之后。3 个新测试覆盖正常差值(1000 → 1400 = +400)、探针不可用时跳过、取消清理仍输出对比。

**验收标准**

- 清理后报告按盘列出「可用空间 前 → 后(本次释放 +N)」,与资源管理器观察一致(±其他程序活动);
- 移入回收站的清理显示实际释放接近 0,并保留「回收站仍占用空间」提示;
- 盘符读取失败时报告无该行且清理正常完成;
- 根目录 `dotnet test` 全部通过。

## 16. 勾选状态持久化

> 来源:backlog 第 16 项(P4 · 体验与分发)。

**目标**:记住用户上次的勾选 —— 重启应用、保存设置、规则集变化后不再一律回到默认勾选。

**现状(实现前)**

`RuleViewModel` 构造时一律取 `rule.Recommended`;用户辛苦调整的勾选在任何一次规则重建后丢失。

**方案**

1. [BroomSettings](../Core/BroomSettings.cs) 新增 `SelectedRuleIds`(可空列表):null = 从未保存过 → 回到规则默认;非空 → 按 Id 集合恢复(大小写不敏感);
2. 勾选变化即持久化;批量操作(全选 / 仅安全 / 全不选)与规则重建合并为一次写盘,保存失败只影响记忆、不影响本次会话;
3. 隐藏规则(如关闭「显示高风险类目」时的高风险项)的 Id 原样保留,重新显示时仍按用户上次的选择;
4. 设置页保存重建 `BroomSettings` 时原样带过该字段,不被覆盖。

**影响文件**

- [Core/BroomSettings.cs](../Core/BroomSettings.cs)、[ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)
- [broom.Tests/SettingsServiceTests.cs](../broom.Tests/SettingsServiceTests.cs)、[broom.Tests/RuleSelectionTests.cs](../broom.Tests/RuleSelectionTests.cs)

> 实现说明:恢复语义集中在内部静态方法 `MainWindowViewModel.ResolveSelection`(null → 默认、非空 → Id 集合),由 `RuleSelectionTests` 锁定;`PersistSelection` 只更新当前规则集内的 Id、保留隐藏 Id,`_suspendSelectionPersist` 抑制重建与批量操作期间的逐条写盘。SettingsService 往返测试覆盖 null 与列表两种形态。

**验收标准**

- 调整勾选后重启应用,勾选原样保留;首次运行仍按默认勾选(安全项);
- 「全不选」后重启:一项都不勾;
- 关闭再打开「显示高风险类目」,高风险项的勾选状态不变;
- 设置页保存后勾选不被重置;`dotnet test` 全部通过。

## 17. 报告与清单导出

> 来源:backlog 第 17 项(P4 · 体验与分发)。

**目标**:报告一键复制到剪贴板;扫描到的全部文件可导出 CSV / TXT,分页明细也能整体核对。

**现状(实现前)**

- 报告文本框不能复制,失败清单无法粘给他人;
- 文件明细分页显示(每批 100 条),几十万文件的整体清单无处可看。

**方案**

1. 报告卡片标题栏加「复制报告」,整篇报告文本进剪贴板(状态栏给反馈);
2. 清理项工具栏加「导出明细」(未扫描时禁用),`StorageProvider` 保存对话框,按扩展名选格式:CSV(带 BOM,Excel 打开中文不乱码)/ TXT(制表符分隔);
3. 导出列为「规则 / 路径 / 大小(字节)」,每条规则内按体积降序(与文件明细一致);回收站等无文件列表的规则自然跳过;
4. 生成逻辑独立成 [Services/ScanExportWriter](../Services/ScanExportWriter.cs)(纯文本、可单测),剪贴板与保存对话框留在窗口代码后置;导出数据源为最近一次完整扫描结果。

**影响文件**

- 新增 [Services/ScanExportWriter.cs](../Services/ScanExportWriter.cs)
- [MainWindow.axaml](../MainWindow.axaml)、[MainWindow.axaml.cs](../MainWindow.axaml.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)(`LastScanResults`)
- 新增 [broom.Tests/ScanExportWriterTests.cs](../broom.Tests/ScanExportWriterTests.cs)

> 实现说明:CSV 对含逗号 / 引号 / 换行的字段加引号并双写引号;导出以 UTF-8 BOM 写出、`SetLength(0)` 覆盖同名旧文件;复制走 Avalonia 12 的 `ClipboardExtensions.SetTextAsync`(扩展方法,需要 `Avalonia.Input.Platform` 命名空间)。5 个新测试覆盖表头、引号转义、制表符格式、规则内按大小降序、跳过无文件规则。

**验收标准**

- 「复制报告」后粘贴得到完整报告文本,状态栏提示已复制;
- 「导出明细」可存 CSV / TXT:Excel 打开 CSV 分列正确、含逗号路径不串列,大小列为纯字节数;
- 未扫描时导出按钮禁用;取消保存对话框无副作用;
- `dotnet test` 全部通过,GUI 冒烟通过。

## 18. 动作型规则(事件日志 / DNS / 还原点与卷影 / WinSxS)

> 来源:backlog 第 6 项遗留、第 10、11 项(P2 · 清理覆盖面)。

**目标**:引擎支持「动作型规则」——不逐个删文件,而是调用系统能力完成一次清理动作;并用它落地四个高价值类目:DNS 缓存刷新、事件日志清空、旧还原点与卷影副本删除(每卷保留最新)、组件存储清理(WinSxS)。

**现状(实现前)**

- 引擎只有 `Paths`(删文件)与 `RecycleBin`(Shell 清空)两种规则;事件日志(API 清空)、DNS 缓存、还原点 / 卷影、WinSxS(DISM)这类「执行一个动作」的类目无法表达(backlog 第 6 项因此留下三个遗留类目);
- 动作类目普遍不可逆、DISM 还长耗时,需要失败处理、进度与取消语义。

**方案**

1. 规则模型:[CleanupRule](../Core/CleanupRule.cs) 新增 `RuleKind.Action` 与 `CleanupAction` 枚举(`FlushDnsCache` / `ClearEventLogs` / `DeleteShadowCopies` / `CleanComponentStore`),规则仍是纯数据;
2. 执行模型:新增 [ICleanupActionService](../Platform/ICleanupActionService.cs) 与 [WindowsCleanupActionService](../Platform/WindowsCleanupActionService.cs)(非 Windows 平台为占位实现):
   - **DNS**:`DnsFlushResolverCache` 直接刷新;
   - **事件日志**:`EventLogSession` 逐个 `ClearLog`(跳过空日志),受保护日志按项记失败不中断整体;需要管理员权限;
   - **还原点 / 卷影**:vssadmin「逐个删最旧」,每卷保留最新一个 —— 不依赖列表顺序与输出语言(按 `HarddiskVolumeShadowCopyN` 设备名计数,卷 GUID 不会误计);
   - **WinSxS**:`Dism /Online /Cleanup-Image /StartComponentCleanup`,输出行实时转为进度,取消时终止进程树;释放量以第 15 项的磁盘前后对比为准;
3. 执行语义:失败原因逐项进报告,成功摘要进 `RuleCleanResult.Summary`;动作中途取消不抛异常,由取消标记把剩余规则列为未执行(与文件删除的「优雅停止」一致);
4. 扫描语义:动作型规则无可枚举文件,扫描只登记规则、状态显示「执行时生效」;不计入预计释放总量,实际效果由清理后的磁盘对比展示;磁盘对比对动作型规则按全部固定磁盘采样;
5. 风险语义:事件日志 / 还原点与卷影 / WinSxS 均为高风险 + 默认不勾选 + 标注需管理员;DNS 为安全 + 默认勾选(代价近零)。

**影响文件**

- [Core/CleanupRule.cs](../Core/CleanupRule.cs)、[Core/ScanModels.cs](../Core/ScanModels.cs)
- 新增 [Platform/ICleanupActionService.cs](../Platform/ICleanupActionService.cs)、[Platform/WindowsCleanupActionService.cs](../Platform/WindowsCleanupActionService.cs);[Platform/PlatformServices.cs](../Platform/PlatformServices.cs)(工厂)
- [Services/Scanner.cs](../Services/Scanner.cs)、[Services/Cleaner.cs](../Services/Cleaner.cs)、[Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs)
- [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)(状态 / 报告)、[broom.csproj](../broom.csproj)(`System.Diagnostics.EventLog` 包)
- 新增 [broom.Tests/WindowsCleanupActionServiceTests.cs](../broom.Tests/WindowsCleanupActionServiceTests.cs),扩展 CleanerTests / ScannerTests / WindowsRuleSetTests

> 实现说明:卷影清理原设计走 WMI(`Win32_ShadowCopy`),实测开发机上 CIM 与 WMI 两种接口都报「初始化失败」(提供程序损坏),而 vssadmin 正常 —— 改为纯 vssadmin 路径(顺带移除 `System.Management` 依赖);长耗时动作的阶段文本经 `CleanProgress.Detail` 进状态栏。验证:23 个新测试(动作成功 / 失败 / 部分失败 / 不支持 / 缺动作定义 / 取消、`RunProcess` 成功 / 非零退出码 / 取消杀进程、`TryRunCapture`、卷影计数正则、扫描登记、规则不变量),`dotnet test` 109/109 通过;临时校验程序在真实机器实测 DNS 刷新成功、事件日志枚举 1237 个(135 个有记录)、DISM 与 vssadmin 就位;GUI 冒烟通过。**事件日志清空 / 卷影删除 / DISM 组件清理是不可逆动作,未在开发机上真实执行**,留提权环境人工验收(见验收标准)。

**验收标准**

- 四个动作型类目出现在对应分组:DNS 解析缓存(安全、默认勾选)、Windows 事件日志 / 旧还原点与卷影副本 / 组件存储清理(高风险、默认不勾选、标「需管理员」);
- DNS 清理执行后报告出「已刷新 DNS 解析缓存」,`ipconfig /displaydns` 显示缓存已重建;
- 提权后执行事件日志清空:事件查看器历史清零,受保护日志的失败项在报告中逐条列出;
- 提权后执行卷影清理:每卷只保留最新一个还原点 / 卷影副本,报告给出删除个数与磁盘对比;
- 执行 DISM 组件清理:状态栏显示进度行、可取消(取消后进程退出),释放量看磁盘对比;
- 未提权执行高风险动作:报告列出失败原因并提示「以管理员身份重启」;
- `dotnet test` 全部通过,GUI 冒烟通过。

## 19. 清理后回收空目录

> 来源:backlog 第 9 项(P2 · 清理覆盖面)。

**目标**:可选项「清理后移除扫描根下的空目录」—— 部分删除 / 自定义目录清理后不再残留空目录结构。

**现状(实现前)**

空目录回收只是「整目录规则」的附带行为(`IsWholeDirectory` 才回收);自定义目录或按文件名模式部分删除后,空目录一直残留。

**方案**

1. 设置页「其他选项」新增开关(默认关闭),说明「可能删除你有意保留的空目录结构」;
2. [Cleaner](../Services/Cleaner.cs) 开启时对所有 `Paths` 规则的扫描根回收空目录(扫描根本身不删),回收数量进 `CleanupReport.EmptyDirectoriesRemoved`,报告输出「另回收空目录 N 个」;关闭时行为与现状完全一致(整目录规则照旧附带回收);
3. 回收仍按由深到浅、跳过联接点,取消时立即停止。

**影响文件**

- [Core/BroomSettings.cs](../Core/BroomSettings.cs)、[Services/Cleaner.cs](../Services/Cleaner.cs)、[ViewModels/SettingsViewModel.cs](../ViewModels/SettingsViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)
- [broom.Tests/CleanerTests.cs](../broom.Tests/CleanerTests.cs)、[broom.Tests/SettingsServiceTests.cs](../broom.Tests/SettingsServiceTests.cs)

> 实现说明:计数含「清理后被腾空」与「原本就空」两类子目录,嵌套空目录由深到浅逐级回收(`sub3/inner` 删后 `sub3` 也变空、一并回收)。2 个新测试覆盖开启(4 个目录回收 + 计数正确)与关闭(空目录保留、计数 0),设置往返测试锁定持久化;设置页文案与「系统还原点」卡片里对卷影清理类目的互斥说明同步更新。

**验收标准**

- 开启后清理:扫描根下的空目录被回收,报告显示「另回收空目录 N 个」;扫描根本身保留;
- 关闭时行为与旧版一致:非整目录规则清理后不回收空目录;
- 开关状态经设置保存 / 重启后保留;`dotnet test` 全部通过。

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
| 10 | 安全擦除(覆写删除) | 只动删除路径与设置项;覆写落在永久删除与隔离区清理两处销毁点 |
| 11 | 清理前创建系统还原点 | 只动清理前置步骤与设置项,新增平台服务,与其余各项独立 |
| 12 | 单元测试项目 | 工程基础,不改产品行为(SettingsService 仅加可注入目录);其余各项的回归防线 |
| 13 | CI(构建 + 测试) | 工程基础,依赖第 12 项的 `dotnet test` 入口 |
| 14 | P2 规则扩充(系统垃圾 / 应用缓存 / 浏览器覆盖) | 纯规则数据 + 分组排序,不改引擎;动作型类目留待「动作型规则」模型(第 10 / 11 项的前置) |
| 15 | 磁盘空间前后对比 | 只动清理器采样与报告文案,与其余各项独立 |
| 16 | 勾选状态持久化 | 只动设置模型与规则重建,与其余各项独立 |
| 17 | 报告与清单导出 | 只动报告区 / 工具栏与新增导出器,与其余各项独立 |
| 18 | 动作型规则(事件日志 / DNS / 还原点与卷影 / WinSxS) | 解锁 backlog 第 6 项遗留、第 10、11 项;动作执行独立成平台服务,与文件清理互不干扰 |
| 19 | 清理后回收空目录 | 只动清理器空目录回收开关与设置项,与其余各项独立 |

各项相互独立,可单独交付;建议每项完成后跑一次「扫描 → 清理 → 报告」全流程,外加一次 GUI 冒烟测试(启动应用、确认窗口创建、关闭)。
