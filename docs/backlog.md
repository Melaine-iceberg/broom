# broom 未完成功能清单(backlog)

> 更新于 2026-10-13。基于当前代码基线的缺口评审整理。roadmap 第 1–6 项(扫描/清理取消、管理员提权、重启后删除、设置页、文件级预览与单文件排除、隔离区与撤销)均已实现,不再列入本文档。
> 更新于 2026-10-14:roadmap 第 7、8 项(P1 时间过滤、排除操作增强)也已落地,同样不再列入;第 7 项未包含的「按大小过滤」保留在 P1。
> 更新于 2026-10-14:P2 第 6–8 项(系统垃圾 / 应用缓存 / 浏览器覆盖)已落地,对应 roadmap 第 14 项;第 6 项的动作型类目(事件日志 / DNS / DriverStore)保留为遗留说明。
> 使用方式:从本清单挑选条目 → 按 [roadmap](roadmap.md) 的模板补齐「背景 / 方案 / 影响文件 / 验收标准」→ 评审后实现,并在 roadmap 中记录状态。
> 优先级为建议顺序;规模为粗略估计:S ≈ 半天以内,M ≈ 1–3 天,L ≈ 3 天以上(单人)。

## P1 · 安全与可控(建议优先)

> 第 1 项的时间过滤部分与第 2 项已于 2026-10-14 立项并实现,设计与验收标准见 roadmap 第 7、8 项,不再列入本文档。

### 1. 按大小过滤(2026-10-14 定案关闭)
- **结论**:不做引擎级大小过滤 —— 「跳过小于 X」没有实际收益,「只清大文件」破坏清理完备性;对照 CCleaner 等同类工具,清理引擎只有时间阈值。
- **去向**:轻量需求由 roadmap 第 9 项「文件明细大小筛选」承接;深度的按大小分析需求归第 20 项「大文件 / 磁盘占用分析」。

### 3. 安全擦除(覆写删除)(2026-10-14 已落地)
- **去向**:设计与实现见 roadmap 第 10 项。要点:覆写落在永久删除与隔离区清理两个销毁点;覆写失败的文件保留并计入失败列表;SSD / 写时复制文件系统效果有限已在 UI 与报告中注明。

### 4. 清理前创建系统还原点(2026-10-14 已落地)
- **去向**:设计与实现见 roadmap 第 11 项。要点:P/Invoke `SRSetRestorePointW`,默认关闭、失败(未提权 / 系统保护未开启)只提示不阻塞;与本清单第 10 项「系统还原点与卷影副本清理」语义互斥,已在设置页说明。

## P2 · 清理覆盖面(规则扩充)

### 6. 系统垃圾规则扩充(2026-10-14 已落地)
- **去向**:设计与实现见 roadmap 第 14 项。已落地纯文件类目:Prefetch、传递优化下载缓存、`$WinREAgent` / Panther / MoSetup 升级残留、字体缓存(用户 / 系统)、Jump List / 最近使用文档。
- **遗留**:动作型类目(事件日志清空、DNS 缓存刷新、DriverStore 旧驱动包)需要引擎新增「动作型规则」模型与失败处理,与第 10、11 项(VSS / DISM)一并设计,不在本期。

### 7. 应用缓存规则扩充(2026-10-14 已落地)
- **去向**:设计与实现见 roadmap 第 14 项。要点:微信 / QQ 只清 `FileStorage\Cache|Temp`(账号目录通配展开)、钉钉只清 `defEmotion|AvatarFiles|ImageFiles`,聊天记录数据库与图片 / 视频 / 文件原目录不进扫描范围;另有 Teams / Discord / Slack(只清网页与渲染缓存)、Office / OneDrive、Spotify、UWP LocalCache(只清 `LocalCache\Local|Low|Roaming`,不碰 `LocalState` / `RoamingState`)。

### 8. 浏览器覆盖扩充(2026-10-14 已落地)
- **去向**:设计与实现见 roadmap 第 14 项。要点:缓存覆盖扩到 Brave / Opera(含 GX)/ Vivaldi / 360 / QQ 浏览器,并补 Firefox 标准配置位置(`%APPDATA%`)与 Chromium 系 `DawnCache`;隐私数据(历史 / Cookie / 会话)独立为「浏览器隐私」分组两条规则,High 风险、默认不勾选、后果写进描述,不碰已保存的密码。

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
- **补充(2026-10-14)**:这是「大小」能力的归宿;引擎级大小过滤经评审不做(见第 1 项定案),深度的按大小分析需求集中到这里。
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

### 25. 单元测试项目(2026-10-14 已落地)
- **去向**:设计与覆盖范围见 roadmap 第 12 项(`broom.Tests`,xUnit);后续新功能应在同一步补测试,替代临时校验程序。

### 26. CI(构建 + 校验)(2026-10-14 已落地)
- **去向**:工作流与验收标准见 roadmap 第 13 项(`.github/workflows/ci.yml`:Windows runner,构建 + 全量测试,最小权限)。

### 27. README
- **动机**:仓库没有 README,新用户不知道如何构建与使用。
- **内容建议**:功能简介、截图、构建/运行方式、清理规则列表与风险说明、设置文件位置。
- **规模**:S。

## 建议推进顺序

1. P1 安全与可控(时间/大小过滤 → 排除增强 → 擦除/还原点);
2. P2 规则扩充(第 6–8 项已落地,剩第 9 空文件夹、第 10 还原点 / 卷影、第 11 WinSxS;第 10、11 项依赖「动作型规则」模型);
3. P3 自动化(CLI 相对独立,可提前;历史统计是「空间对比」的前置);
4. P4 体验与分发(打包分发建议在对外发布前完成);
5. P5 外延能力需先做产品取舍,不建议直接排期;
6. P6 工程基础可与任意阶段并行,第 25 项建议在下一项功能开工前启动。
