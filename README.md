# Broom

面向 Windows 桌面的安全、可撤销垃圾清理工具。Broom 只处理由规则明确声明的缓存目录：先扫描预览，再把文件移入隔离区，清理后随时可以撤销。

当前版本 **v2**：在 v1 的 **Windows Safe 级清理 + 预览 + 隔离区撤销** 之上，新增 **Review 级回收站清空** 与 **Info 级只读分析**（重复文件、大文件）。其他平台与清理能力尚未实现，清单见 [docs/roadmap.md](docs/roadmap.md)。

## 如何定义“垃圾”

Broom 不使用启发式猜测，也不按扩展名全局搜索。垃圾文件必须同时满足一条声明式规则和一组运行时约束：

1. **规则声明位置**：每个规则用环境变量与通配符声明一组缓存根目录，例如 Chrome 的 `Cache`、`Code Cache`、`GPUCache`，以及 npm / pip / Pub / Gradle 缓存。
2. **必须位于规则根目录内**：扫描到的文件只能属于该规则的某个根目录；删除与撤销时还会再次校验，防止规则写错或路径拼接越界。
3. **可选时间与扩展名过滤**：例如用户临时文件只处理超过 24 小时的内容，崩溃转储只处理 `.dmp`。
4. **跳过符号链接 / junction**：扫描不会跟随链接，避免通过链接跳出缓存目录。
5. **不触碰受保护区域**：Windows 目录、Program Files、Program Files (x86)、ProgramData 以及 Broom 隔离区始终受保护；规则根本身不会被删除。

v1 内置的 Safe 级规则：

| 分类 | 规则 | 位置 | 额外限制 |
| --- | --- | --- | --- |
| 系统缓存 | 用户临时文件 | `%TEMP%` | 超过 24 小时 |
| 系统缓存 | 崩溃转储 | `%LOCALAPPDATA%\CrashDumps` | 仅 `.dmp` |
| 系统缓存 | Windows 错误报告 | `%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive`、`ReportQueue` | - |
| 浏览器缓存 | Google Chrome | `%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache` 等 | - |
| 浏览器缓存 | Microsoft Edge | `%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache` 等 | - |
| 浏览器缓存 | Brave | `%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Cache` 等 | - |
| 浏览器缓存 | Firefox | `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2`、`startupCache` | - |
| 开发工具缓存 | npm | `%LOCALAPPDATA%\npm-cache\_cacache` | - |
| 开发工具缓存 | pip | `%LOCALAPPDATA%\pip\Cache` | - |
| 开发工具缓存 | Pub | `%LOCALAPPDATA%\Pub\Cache` | - |
| 开发工具缓存 | Gradle | `%USERPROFILE%\.gradle\caches` | - |

浏览器规则只覆盖缓存，不包含书签、密码、Cookie 或登录状态。

## 安全模型

- **声明式规则**：只清理规则覆盖的路径，不做全盘“垃圾识别”。
- **路径守卫**：Windows 大小写不敏感地检查路径包含关系，拒绝根目录本身、`..` 越界与同前缀的兄弟目录。
- **不跟随链接**：目录遍历使用 `followLinks: false`，遇到 `Link` 直接跳过。
- **移动而非删除**：清理先把文件移动到隔离区，失败的文件保留在原处并记录原因；运行中的程序占用的文件会自动跳过。
- **跨卷兼容**：同卷优先 `rename`，跨卷退回“复制 + 删除”，删除失败时清理复制出的半成品。
- **崩溃安全**：移动每个文件前，先把撤销记录追加写入并 `flush`；即使清理中途崩溃，已移动的文件仍可撤销。
- **可撤销**：撤销前重新做路径守卫检查，不覆盖后来新建的原路径文件；冲突项保留在隔离区，可稍后重试。
- **无管理员权限**：v1 不涉及系统级目录，不需要提权。

## 使用流程

1. 点击“开始扫描”。扫描在独立 isolate 中执行，可随时取消；单次扫描最多收集 100,000 个文件，达到上限会提示截断。
2. 在预览页按规则查看文件数量、体积与文件明细，按规则勾选要清理的内容。
3. 确认后文件移入隔离区。被占用、无权限或移动失败的文件会列出原因，其余文件继续处理。
4. 清理完成后可“撤销本次清理”；部分撤销（冲突 / 失败）会在首页保留待撤销卡片，可再次尝试。

## V2：分析与审阅（Review / Info）

首页“分析与审阅”区域提供三类工具，并明确标注风险等级：

| 等级 | 含义 | 当前入口 | 数据影响 |
| --- | --- | --- | --- |
| `SAFE · 可撤销` | 缓存清理，可随时恢复 | 开始扫描 → Safe 规则 | 移入 Broom 隔离区 |
| `REVIEW · 需确认` | 可能丢失重要内容，需要独立确认 | 回收站 | 永久删除，无隔离区、无撤销 |
| `INFO · 只读` | 只分析、不修改任何文件 | 重复文件、大文件分析 | 无 |

### 回收站（Review）

- 通过 Windows Shell API（`SHQueryRecycleBinW`）读取所有磁盘回收站的条目数与占用。
- 清空调用 `SHEmptyRecycleBinW`（不显示系统确认框、进度框与音效），覆盖所有磁盘。
- 清空前必须通过独立对话框并勾选“我明白清空后无法恢复”；Broom 不提供回收站撤销。
- 不读取回收站内的文件内容。

### 重复文件（Info）

- 先按文件大小分组，再比对首尾部分指纹，最后对候选文件做完整 SHA-256；避免对所有文件全量读取。
- 默认只分析不小于 1 MB 的文件，阈值可选 100 KB / 1 MB / 10 MB / 100 MB。
- 单次最多检查 200,000 个文件，按可释放空间降序展示重复组。
- 结果只读：不自动选择保留项、不提供删除按钮，只支持“在资源管理器中显示”。

### 大文件分析（Info）

- 扫描用户选定的文件夹，列出超过阈值的文件（默认 100 MB，可选 50 MB 至 5 GB）。
- 匹配结果按体积降序展示，最多列出 200 个；汇总仍统计全部匹配项。
- 只读取文件大小与位置，不删除、不移动、不修改文件。

两类分析都在独立 isolate 中执行，支持进度展示与取消；Broom 的隔离区目录始终排除在分析范围之外。默认分析目录为当前用户的 `Downloads`。

## Windows 原生桥接

回收站、文件夹选择器与“在资源管理器中显示”通过 `MethodChannel('broom/shell')` 调用原生 Shell API；通道实现位于 `windows/runner/system_shell_channel.*`，不需要额外插件依赖。C++ 侧返回 `HRESULT` / Win32 错误码，Dart 侧会转换为可读的“Windows 错误 0x……”提示。

## 隔离区

默认位置：`%LOCALAPPDATA%\Broom\quarantine\<sessionId>\`

```text
<sessionId>/
  session.json     # 会话元数据：状态、条目数、总大小、待恢复数
  entries.jsonl    # 每个文件的原始路径、规则根、大小、隔离文件名
  restored.jsonl   # 已恢复文件的标记，重试时跳过
  files/           # 实际保存的文件（使用扁平化存储名）
```

会话全部恢复后目录会被删除；仍有冲突或失败时状态标记为 `partial`，重启后首页仍可继续撤销。恢复时只恢复到原始路径，不覆盖已存在的文件。

## 项目结构

```text
lib/
  main.dart                        # 平台检测、依赖装配
  app.dart                         # Material 主题与不支持平台页面
  core/
    models/                        # 规则、扫描、清理、撤销与分析数据模型
    rules/windows_rules.dart       # Windows Safe 规则
    platform/                      # CleanerPlatform 抽象、Windows 实现、路径解析
    safety/path_guard.dart         # 路径包含与保护规则
    scan/                          # 扫描器与 isolate 扫描服务
    clean/quarantine_service.dart  # 隔离、撤销、会话管理
    analysis/                      # 只读遍历器、重复文件、大文件与 isolate 分析服务
    shell/system_shell.dart        # 回收站 / 文件夹选择 / 定位文件通道
  ui/                              # 控制器、首页、清理页、回收站与两类分析页
windows/runner/system_shell_channel.*  # 原生 Shell API 通道
test/                              # 路径守卫、扫描、隔离区、分析、Shell 通道与页面测试
docs/roadmap.md                    # 未实现目标与非目标
```

## 开发

要求 Flutter 3.x（开发环境为 Flutter 3.47.7 / Dart 3.13.5）与 Windows 桌面构建工具链。

```bash
flutter pub get
flutter run -d windows
flutter analyze
flutter test
flutter build windows --release
```

构建产物位于 `build/windows/x64/runner/Release/`。

## 平台与移动端扩展

平台差异集中在 `CleanerPlatform` 接口中：`isSupported`、`quarantineRoot`、`rules`、`resolveRoots`。`createCleanerPlatform()` 当前只返回 Windows 实现，其他平台返回 `UnsupportedCleanerPlatform` 并显示不支持页面，因此移动端可以接入而不影响桌面逻辑。

需要注意，当前核心实现（路径守卫、隔离区、扫描器、分析遍历器）直接使用 Windows 路径语义与文件系统移动语义。接入 Android / iOS 时不能只新增一份规则：还需要为 `CleanerPlatform` 增加文件系统与路径语义抽象，并处理 SAF / MediaStore、应用沙箱、权限申请和平台专属的撤销机制。具体拆解见 [docs/roadmap.md](docs/roadmap.md)。

## 已知限制

- 仅支持 Windows；规则清理仍只使用 Safe 级；Review（回收站）与 Info（分析）作为独立工具提供，不参与规则勾选。
- 只能按规则整体勾选，不能选择单个文件；扫描范围固定为全部 Safe 规则。
- 回收站清空覆盖所有磁盘且永久生效，Broom 不提供隔离或撤销。
- 重复文件与大文件分析只读，不提供清理操作；重复文件默认只分析 ≥ 1 MB 的文件，最多检查 200,000 个文件，大文件列表最多显示 200 项。
- 分析范围一次只能选择一个文件夹，不能配置排除目录；默认目录为 `Downloads`。
- 隔离区没有保留期限、容量上限与清理入口；UI 只能看到最近一个待撤销会话。
- 撤销冲突只能跳过并重试，不能覆盖或改名；不恢复时间戳、ACL 等元数据。
- 没有设置页、排除列表、定时任务、历史记录、国际化、CLI 与自动更新。
- 单次规则扫描最多 100,000 个文件；结果在扫描结束后一次性展示。

完整路线图见 [docs/roadmap.md](docs/roadmap.md)。
