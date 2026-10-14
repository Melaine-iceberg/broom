# broom 未完成功能清单(backlog)

> 更新于 2026-10-13。基于当前代码基线的缺口评审整理。roadmap 第 1–6 项(扫描/清理取消、管理员提权、重启后删除、设置页、文件级预览与单文件排除、隔离区与撤销)均已实现,不再列入本文档。
> 更新于 2026-10-14:roadmap 第 7、8 项(P1 时间过滤、排除操作增强)也已落地,同样不再列入;第 7 项未包含的「按大小过滤」保留在 P1。
> 使用方式:从本清单挑选条目 → 按 [roadmap](roadmap.md) 的模板补齐「背景 / 方案 / 影响文件 / 验收标准」→ 评审后实现,并在 roadmap 中记录状态。
> 优先级为建议顺序;规模为粗略估计:S ≈ 半天以内,M ≈ 1–3 天,L ≈ 3 天以上(单人)。

## P1 · 安全与可控(建议优先)

> 第 1 项的时间过滤部分与第 2 项已于 2026-10-14 立项并实现,设计与验收标准见 roadmap 第 7、8 项,不再列入本文档。

### 1. 按大小过滤(原「按文件时间 / 大小过滤」的剩余部分)
- **说明**:时间过滤已随 roadmap 第 7 项落地;大小过滤语义未定(候选:跳过小于 X 的文件 / 只清理大于 X 的文件),需要先明确产品语义再排期。
- **规模**:S。

### 3. 安全擦除(覆写删除)
- **动机**:敏感残留文件希望在永久删除时不可恢复。
- **方案要点**:设置页增加「永久删除前覆写次数(0/1/3)」;[Platform/PermanentFileDeleter.cs](../Platform/PermanentFileDeleter.cs) 覆写后再删除;清理报告与设置页标注「对 SSD / 写时复制文件系统效果有限」。
- **涉及**:[Platform/PermanentFileDeleter.cs](../Platform/PermanentFileDeleter.cs)、[Core/BroomSettings.cs](../Core/BroomSettings.cs)、设置页。
- **规模**:M · **风险**:显著拖慢清理;在 SSD 上主要是安慰剂,必须明确告知。

### 4. 清理前创建系统还原点
- **动机**:批量清理系统类目之前,提供一键回滚点。
- **方案要点**:提权状态下通过 WMI / `Checkpoint-Computer` 创建还原点;失败(系统保护未开启)不阻塞清理,仅提示。
- **涉及**:新增 Platform 服务、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)。
- **规模**:M · **风险**:系统保护未开启时不可用;与第 10 项(清理还原点)语义冲突,需在 UI 说明。

## P2 · 清理覆盖面(规则扩充)

### 6. 系统垃圾规则扩充
- **动机**:多个常见可清理项未覆盖,用户仍要手工处理。
- **候选类目**:事件日志(需 API 清空,不能删文件)、Prefetch、传递优化文件(Delivery Optimization)、`$WinREAgent` / Panther 升级日志、DNS 缓存(`ipconfig /flushdns`)、字体缓存、Jump List / 最近使用文档、旧驱动包(DriverStore,仅清陈旧包)。
- **涉及**:[Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs);部分类目需要引擎新增「动作型规则」(现有引擎只支持删文件 / 清空回收站)。
- **规模**:M · **风险**:先做纯文件类目;动作型规则(命令执行)需要新的模型与失败处理。

### 7. 应用缓存规则扩充
- **动机**:开发缓存已覆盖,但常用应用的缓存仍是空白。
- **候选类目**:微信/QQ/钉钉、Teams/Discord/Slack、Office/OneDrive、Spotify、商店应用缓存(UWP LocalCache)。
- **涉及**:[Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs)。
- **规模**:M · **风险**:路径随应用版本变化,需要宽匹配 + 保守排除;**微信等聊天缓存与聊天记录同目录,排除规则必须精确**,否则不可接受。

### 8. 浏览器覆盖扩充
- **动机**:目前仅 Chrome / Edge / Firefox 的缓存;小众与国产浏览器用户无法覆盖。
- **候选类目**:Brave / Opera / Vivaldi / 360 / QQ 浏览器缓存;可选「隐私数据」(历史、Cookie、会话)——默认不勾选并明确说明后果(登录状态丢失)。
- **涉及**:[Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs)、风险说明文案。
- **规模**:M · **风险**:隐私数据清理语义敏感,建议独立开关、逐项确认。

### 9. 空文件夹清理
- **动机**:空目录回收目前只是「整目录规则」的附带行为;自定义目录或部分删除后的空目录不会被清理。
- **方案要点**:二选一——引擎选项「清理后移除扫描根下的空目录」(对所有规则生效);或独立「空文件夹」规则(需告知可能删除用户有意保留的空目录)。
- **涉及**:[Services/Cleaner.cs](../Services/Cleaner.cs)、[Core/CleanupRule.cs](../Core/CleanupRule.cs)。
- **规模**:S。

### 10. 系统还原点与卷影副本清理
- **动机**:还原点 / 卷影副本常占数 GB。
- **方案要点**:通过 VSS API 或 `vssadmin` 列出并删除旧还原点(保留最新一个);需要管理员权限。
- **涉及**:新增 Platform 服务、[Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs)(动作型规则)。
- **规模**:M · **风险**:删除后无法回滚系统;必须标记高风险且默认不勾选。

### 11. 组件存储清理(WinSxS)
- **动机**:`DISM /Online /Cleanup-Image /StartComponentCleanup` 是最大的可回收空间来源之一。
- **方案要点**:以「动作型规则」调用 DISM(需提权),执行时间较长,进度与释放量在报告中展示。
- **涉及**:新增 Platform 服务、引擎(动作型规则)、UI(耗时提示)。
- **规模**:M · **风险**:删除后无法卸载已安装的更新;执行时间长,需要取消/进度策略。

## P3 · 自动化

### 12. 定时 / 阈值自动清理 + 托盘常驻
- **动机**:长期免维护;磁盘空间紧张时主动提醒。
- **方案要点**:设置页「每周 / 每月自动清理」(按当前勾选或仅安全项);可用 Windows 计划任务或应用内定时 + 托盘图标;磁盘低于阈值时通知。
- **涉及**:新增服务、Avalonia `TrayIcon`、设置持久化。
- **规模**:L · **风险**:自动删除需要可预期(仅安全项、有报告、可关闭)。

### 13. 命令行 CLI / 无人值守
- **动机**:脚本化与自动化;目前 [Program.cs](../Program.cs) 直接忽略命令行参数。
- **方案要点**:`broom --scan|--clean [safe|all] --dry-run --report out.txt --yes`;约定退出码;将扫描/清理流程从 ViewModel 下沉为可复用服务。
- **涉及**:[Program.cs](../Program.cs)、新增参数解析、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)(逻辑抽取)。
- **规模**:M。

### 14. 清理历史与累计统计
- **动机**:报告只存在内存,重启即丢;「累计已清理 X GB」是核心成就指标。
- **方案要点**:每次清理向 `%APPDATA%\broom\history.json` 追加记录(时间、规则、项数、字节数);清理页展示「本次释放 / 累计释放」,可选趋势列表。
- **涉及**:新增服务、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、清理页 UI。
- **规模**:M。

## P4 · 体验与分发

### 15. 磁盘空间前后对比
- **动机**:用户想直接看到「释放了多少」,而不仅是计入的字节数。
- **方案要点**:清理前后查询目标盘可用空间(`DriveInfo`),在报告中展示差值;可与第 14 项配合展示累计。
- **涉及**:[Services/Cleaner.cs](../Services/Cleaner.cs) / [ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[Core/Formatting.cs](../Core/Formatting.cs)。
- **规模**:S · **依赖**:可与第 14 项合并实现。

### 16. 勾选状态持久化
- **动机**:规则重建后勾选回到 `Recommended` 默认值,用户偏好被重置。
- **方案要点**:[Core/BroomSettings.cs](../Core/BroomSettings.cs) 增加「上次勾选的规则 Id 集合」;扫描/重建后恢复。
- **涉及**:[Core/BroomSettings.cs](../Core/BroomSettings.cs)、[ViewModels/RuleViewModel.cs](../ViewModels/RuleViewModel.cs)、[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)。
- **规模**:S。

### 17. 报告与清单导出
- **动机**:报告不能复制;文件明细(分页显示)无法整体导出核对。
- **方案要点**:报告区「复制」按钮;扫描结果导出 CSV / TXT(路径、大小、规则),使用 Avalonia `StorageProvider` 保存对话框。
- **涉及**:[ViewModels/MainWindowViewModel.cs](../ViewModels/MainWindowViewModel.cs)、[MainWindow.axaml](../MainWindow.axaml)。
- **规模**:S。

### 18. 多语言(i18n)
- **动机**:界面与规则文案硬编码中文。
- **方案要点**:UI 文案抽到资源字典 / resx,默认跟随系统语言;规则 `DisplayName` / `Description` 是纯数据,需要资源键方案。
- **涉及**:全局(XAML + [Rules/WindowsRuleSet.cs](../Rules/WindowsRuleSet.cs))。
- **规模**:M。

### 19. 打包分发
- **动机**:目前只能 `dotnet run`;无图标、无版本号、无安装包。
- **方案要点**:应用图标与版本信息;`dotnet publish`(自包含 / 单文件);可选 Inno Setup / MSIX;便携模式(设置读写 exe 同目录);单实例互斥;可选更新检查。
- **涉及**:[broom.csproj](../broom.csproj)、[app.manifest](../app.manifest)、新增打包脚本。
- **规模**:M。

## P5 · 外延能力(需明确取舍)

### 20. 大文件 / 磁盘占用分析
- **说明**:目录树扫描 + Top N 大文件,支持定位与删除。属于「磁盘工具」范畴,与清理功能互补但工程量不小。
- **规模**:L。

### 21. 重复文件查找
- **说明**:按大小分桶 + 哈希比对。用户预期高,但同样是独立产品面。
- **规模**:L。

### 22. 卸载项 / 启动项管理
- **说明**:读取注册表卸载键与 `Run` 键,提供跳转卸载 / 禁用启动项。职责扩大到系统管理,需要更谨慎的权限与回滚设计。
- **规模**:L。

### 23. 注册表清理
- **说明**:CCleaner 式「注册表清理」。**不建议做**:现代 Windows 收益低、误删风险高;若坚持,必须默认关闭、先备份、可完整恢复。
- **规模**:M。

### 24. macOS / Linux 支持
- **说明**:引擎与平台抽象(回收站 / 提权 / 重删)已预留;需要新增规则集与各平台实现,并让 CI 覆盖多平台构建。
- **规模**:L。

## P6 · 工程基础

### 25. 单元测试项目
- **动机**:仓库目前没有任何测试;历次功能靠临时校验程序验证,不可回归。
- **覆盖建议**:Scanner(路径展开、通配符、排除)、Cleaner(取消、失败统计)、SettingsService(损坏回退)、规则数据不变量(Id 唯一、路径模板合法)。
- **规模**:S–M。

### 26. CI(构建 + 校验)
- **动机**:无 `.github`;PR 无自动构建与测试。
- **方案要点**:GitHub Actions:Windows runner 上 `dotnet build` +(第 25 项落地后)`dotnet test`。
- **规模**:S · **依赖**:第 25 项(可选,可先只做构建)。

### 27. README
- **动机**:仓库没有 README,新用户不知道如何构建与使用。
- **内容建议**:功能简介、截图、构建/运行方式、清理规则列表与风险说明、设置文件位置。
- **规模**:S。

## 建议推进顺序

1. P1 安全与可控(时间/大小过滤 → 排除增强 → 擦除/还原点);
2. P2 规则扩充(按实际用户反馈挑选类目,注意第 7 项的聊天记录排除风险);
3. P3 自动化(CLI 相对独立,可提前;历史统计是「空间对比」的前置);
4. P4 体验与分发(打包分发建议在对外发布前完成);
5. P5 外延能力需先做产品取舍,不建议直接排期;
6. P6 工程基础可与任意阶段并行,第 25 项建议在下一项功能开工前启动。
