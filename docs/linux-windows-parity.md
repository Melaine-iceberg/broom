# Linux 与 Windows 功能差距评估

> 评估对象：Broom 0.4.0（`pubspec.yaml`，0.4.0+4）
> 评估日期：2026-10-23
> 结论：Linux 已具备“规则扫描 → 预览 → 隔离区 → 撤销 / 永久释放”的完整核心闭环。剩余差距集中在四类：Windows 专属功能入口、同名功能的能力降级、规则覆盖，以及分发与验证。

## 1. 总览

| 能力 | Windows | Linux | 差距性质 |
| --- | --- | --- | --- |
| 规则扫描、预览、选择、清理 | 支持 | 支持 | 已对齐 |
| 隔离区撤销、永久释放、清理历史、保留策略 | 支持 | 支持 | 已对齐 |
| 设置、配置导入导出、排除列表、国际化 | 支持 | 支持 | 已对齐 |
| 重复文件、大文件分析 | 支持 | 支持 | 已对齐 |
| 系统缓存（Windows Update / 传递优化 / Windows.old） | 支持，需 UAC | 无入口 | 功能缺失 |
| 回收站查看与清空 | 支持 | 无入口 | 功能缺失 |
| 卸载残留检测 | 支持，依赖注册表 | 无入口 | 功能缺失 |
| 规则在线更新、签名校验、回滚 | 支持 | 无入口 | 功能缺失 |
| 应用软件更新检查 | 支持，MSIX / App Installer | 无入口 | 功能缺失 |
| NTFS 索引加速 | 支持，USN / MFT | 无等价实现 | 功能缺失 |
| 文件占用预检 | 原生通道 | 空实现 | 能力降级 |
| 原生目录枚举 | `FindFirstFileW` | `dart:io` + 逐文件 `stat` | 性能差距 |
| 元数据恢复 | 时间 / 只读 / DACL 尽力恢复 | 权限位 + 时间 | 能力降级 |
| 扫描低优先级 | 后台模式 + 低 CPU 优先级 | `nice 10` | 能力降级 |
| 自定义窗口标题栏 | 支持 | GTK 原生标题栏 | 表现差异 |
| 安装器与自动更新 | MSIX + App Installer | tar.gz | 分发差距 |
| 真实窗口集成测试 | 支持，手动触发 | 无 | 验证差距 |

## 2. 完全缺失的功能入口

Linux 上这些入口不仅没有控制器，侧边栏和设置页也会直接隐藏或跳过渲染。

### 2.1 系统缓存

Windows 侧由 `SystemCacheController` 承担，依赖 UAC 提权、Windows Update `SoftwareDistribution\Download`、传递优化 `DeliveryOptimization\Cache` 与 `Windows.old`：

- 控制器只在 Windows 分支创建：[lib/main.dart](../lib/main.dart#L197-L212)
- 平台实现只支持 Windows：[lib/core/platform/system_cache_platform.dart](../lib/core/platform/system_cache_platform.dart#L82-L86)
- 权限与目录定位只支持 Windows：[lib/core/platform/system_access.dart](../lib/core/platform/system_access.dart#L122-L125)

Linux 没有管理员系统清理模式，且 `/var`、`/snap`、`/nix` 等目录被列为保护根（[cleaner_platform.dart](../lib/core/platform/cleaner_platform.dart#L176-L193)）。因此 apt 缓存、journal 日志、Snap 旧版本等 Linux 侧系统缓存也没有对应入口。

### 2.2 回收站

Windows 通过 `broom/shell` 的 `queryRecycleBin` / `emptyRecycleBin` 提供回收站查看与清空。Linux 原生通道明确返回未实现：

- [linux/runner/native_channels.cc](../linux/runner/native_channels.cc#L271-L275)
- 侧边栏在非 Windows 隐藏入口：[lib/ui/app_sidebar.dart](../lib/ui/app_sidebar.dart#L77-L94)

Linux 的 freedesktop Trash（`~/.local/share/Trash`）没有接入；Broom 自身的隔离区可以替代“可撤销删除”，但不提供“清空系统回收站”。

### 2.3 卸载残留

Windows 依赖原生 `broom/apps` 通道读取注册表安装清单，再匹配 AppData 中的残留目录：

- 服务只在 Windows 创建：[lib/main.dart](../lib/main.dart#L146-L152)
- 非 Windows 返回不支持：[lib/core/platform/installed_apps.dart](../lib/core/platform/installed_apps.dart#L115-L118)

Linux 侧没有对应的包管理器清单（dpkg / rpm / Flatpak / Snap）与孤儿配置目录扫描。

### 2.4 规则在线更新

Windows 支持 HTTPS 清单、构建期签名校验、上一版回滚与恢复内置规则：

- 控制器只在 Windows 创建：[lib/main.dart](../lib/main.dart#L169-L183)
- 规则目录也只在 Windows 启动流程中应用：[lib/main.dart](../lib/main.dart#L207-L211)

Linux 始终使用编译进二进制的内置规则目录，当前版本为 `builtin-linux-2`；即使磁盘上存在规则目录，启动时也不会加载。设置页的“规则更新”区块因控制器为空而不渲染（[settings_page.dart](../lib/ui/settings_page.dart#L319-L330)）。

### 2.5 应用软件更新

Windows 通过 `.appinstaller` 与 MSIX 提供更新提示，应用内只展示当前版本与最新版本：

- 控制器只在 Windows 创建：[lib/main.dart](../lib/main.dart#L190-L195)

Linux 没有更新源与检查逻辑，设置页的“软件更新”区块不渲染；升级方式是重新下载 tar.gz 并替换目录。

### 2.6 NTFS 索引

Windows 可选使用 USN Journal / MFT 枚举候选文件，失败时回退逐目录扫描：

- Windows 使用 `NtfsIndexClient`，其他平台使用 `UnavailableNtfsIndex`：[lib/main.dart](../lib/main.dart#L143-L145)

Linux 没有等价的文件系统快速索引，始终走目录遍历；这不影响结果正确性，只影响大目录树的扫描耗时。

## 3. 同名功能的实现差距

### 3.1 文件占用预检

Windows 通过 `broom/file_lock` 批量探测可能被占用的文件，预览会显示“可能被占用”提示；Linux 使用空实现：

- [file_lock_probe.dart](../lib/core/platform/file_lock_probe.dart#L55-L57)

结果是 Linux 预览不会提前标记被占用文件，清理时才会暴露真实失败。功能仍可用，但可预期性低于 Windows。

### 3.2 目录枚举

Windows 的 `broom/directory_enum` 通过 `FindFirstFileW` 一次返回名称、大小、修改时间与属性：

- 通道与探测：[directory_enum.dart](../lib/core/platform/directory_enum.dart#L44-L63)
- 仅 Windows 启用：[directory_enum.dart](../lib/core/platform/directory_enum.dart#L146-L157)

Linux 回退到 `Directory.list` 加逐项 `stat`：

- [file_system.dart](../lib/core/platform/file_system.dart#L176-L198)

同样的扫描逻辑在 Linux 上会产生更多系统调用，目录树越大差距越明显。扫描结果与选择行为不受影响。

### 3.3 元数据恢复

Windows 记录并尽力恢复创建时间、修改时间、访问时间、只读属性，跨卷复制时额外抓取并恢复 DACL：

- [file_metadata.dart](../lib/core/clean/file_metadata.dart#L156-L214)

Linux 只能恢复权限位与访问 / 修改时间：

- [file_metadata.dart](../lib/core/clean/file_metadata.dart#L100-L154)

具体差异：

- POSIX 没有通过 `dart:io` 暴露创建时间，`FileMetadata.created` 在 Linux 上为空
- 所有者、所属组、POSIX ACL、扩展属性（xattr / capability / SELinux 标签）不记录也不恢复
- 同卷重命名会保留这些属性；跨卷复制会丢失，只能恢复 mode 与时间
- 只读属性由权限位的写位推导，不单独保存

### 3.4 扫描低优先级

Windows 尝试进入后台模式，失败后回退到低于正常的 CPU 优先级；Linux 只把进程 `nice` 调整到 10：

- [linux/runner/native_channels.cc](../linux/runner/native_channels.cc#L281-L321)
- [scan_priority.dart](../lib/core/platform/scan_priority.dart#L21-L50)

Linux 没有 I/O 优先级调整，磁盘密集扫描对前台程序的影响可能比 Windows 更明显。

### 3.5 窗口与外壳

Windows 使用 Flutter 自绘标题栏，支持拖动、双击最大化、最大化悬停状态与系统菜单：

- [window_chrome.dart](../lib/platform/window_chrome.dart#L27-L29)
- [window_title_bar.dart](../lib/ui/window_title_bar.dart#L16-L30)

Linux 使用 GTK 原生标题栏（GNOME 下为 header bar，其他窗口管理器为传统标题栏）：

- [linux/runner/my_application.cc](../linux/runner/my_application.cc#L29-L54)

这是符合平台习惯的差异，但视觉与交互不完全一致，Linux 不提供自绘标题栏与最大化悬停状态。

### 3.6 版本号来源

Windows 从 runner 写入的版本读取；Linux 使用 `lib/core/app_info.dart` 中的常量：

- [app_version.dart](../lib/core/platform/app_version.dart#L44-L49)
- [app_info.dart](../lib/core/app_info.dart)

发布 Linux 版本时必须同步修改 `pubspec.yaml` 与 `broomAppVersion`，否则关于页与诊断信息中的版本会不一致。

## 4. 规则覆盖

| 平台 | 规则总数 | 分类分布 |
| --- | --- | --- |
| Windows | 44 | 系统 3、浏览器 5、开发工具 28、应用 5、缩略图 1、GPU 1、日志 1 |
| Linux | 39 | 系统 2、日志 1、GPU 2、浏览器 6、应用 4、开发工具 24 |

- Windows 规则：[windows_rules.dart](../lib/core/rules/windows_rules.dart)
- Linux 规则：[linux_rules.dart](../lib/core/rules/linux_rules.dart)

Linux 目前覆盖缩略图、fontconfig、Broom 诊断日志、Mesa / NVIDIA 着色器、Chrome / Chromium / Edge / Brave / Firefox（含 Chromium `ScriptCache`）、VS Code / Discord / Slack / Spotify，以及 pip、npm、Yarn、pnpm、Bun、uv、Go、Cargo、Gradle、Pub、Maven、Playwright、Composer、Electron、Poetry、node-gyp、Deno、Corepack、NuGet、JetBrains、Hugging Face、conda、Coursier、Kotlin/Native 缓存。

Windows 侧存在但 Linux 没有对应规则的包括：

- 系统临时文件、崩溃转储、Windows 错误报告（WER）
- Teams、Docker、WSL、Scoop、vcpkg

其中一部分确实属于 Windows 专有；Linux 侧仍待补齐的主要是需要提权或特殊语义的系统级目标：

- freedesktop Trash
- systemd journal / 系统日志
- Flatpak、Snap 的旧版本与缓存
- 包管理器缓存（apt、dnf、pacman 等，需要先决定是否纳入保护根与提权模型）
- 新版 Teams 客户端与自定义安装路径的 vcpkg 尚未逐项验证

此外，Linux 只能使用内置规则，无法加载签名更新或回滚版本，因此规则修正仍需随版本发布，无法像 Windows 一样在线更新。

## 5. 分发、更新与验证

### 5.1 分发

Windows：

- 签名 MSIX、开始菜单项、卸载与就地升级
- `.appinstaller` 自动更新源
- 便携 ZIP 与 SHA-256
- 详见 [README.md](../README.md#L309-L329) 与 [packaging.md](packaging.md)

Linux：

- `flutter build linux --release` + [tool/package_linux.sh](../tool/package_linux.sh)
- 产物为 tar.gz，附带 `.desktop` 与图标，需要用户手动复制到应用目录
- 没有系统安装器、软件源、自动更新、沙箱包或签名流程

路线图仍待办：Flatpak / Snap / AppImage、Wayland 下“打开文件位置”验证、Snap 沙箱内的隔离区路径约定（[roadmap.md](roadmap.md#L234-L242)）。

### 5.2 测试与 CI

- Linux CI 执行格式校验、严格静态检查、单元 / Widget 测试、Release 构建与 tar.gz 打包（[.github/workflows/linux.yml](../.github/workflows/linux.yml)）
- Windows CI 额外提供真实窗口冒烟测试与帧率基准，手动触发（[.github/workflows/windows.yml](../.github/workflows/windows.yml#L67-L90)）
- Linux 平台逻辑已有测试覆盖：[linux_platform_test.dart](../test/linux_platform_test.dart)、[posix_quarantine_test.dart](../test/posix_quarantine_test.dart)、[linux_rule_audit_test.dart](../test/linux_rule_audit_test.dart)
- Linux 没有真实窗口的 UI 集成测试，也没有 GTK / Wayland 下的手工回归记录

## 6. 已对齐的能力

以下能力在 Linux 上已经完整可用，不应计入差距：

- 规则扫描、类别过滤、逐文件选择、搜索 / 筛选 / 排序
- 预览、扫描摘要、结果持久化与恢复
- 隔离区移动、撤销、永久释放、会话续跑、清理历史、保留策略
- 排除列表、路径守卫、配置导入导出、设置迁移
- 重复文件与大文件分析
- 39 条内置规则（27 条 Safe、12 条 Review），覆盖日志、浏览器脚本、应用缓存与常用开发工具缓存
- 磁盘空间查询（`statvfs`）
- 文件夹 / JSON 文件选择器（GTK）
- 定位文件（Gio 打开默认文件管理器）
- 扫描低优先级（`nice`）
- Windows / POSIX 路径语义、大小写敏感性、跨卷 `st_dev` 探测
- 中英文界面、主题、无障碍与键盘快捷键

## 7. 后续建议

按投入产出排序：

1. **规则目录扩容与在线更新**：第一批用户级规则已补齐（24 → 39，含 12 条 Review）；下一步补系统级目标，并复用现有签名目录与回滚机制，让 Linux 也能更新规则。
2. **文件占用预检与原生目录枚举**：前者提升预览可预期性，后者降低大目录扫描的系统调用次数。
3. **回收站与系统级缓存**：需要先确定 Linux 的提权模型、保护根调整与 freedesktop Trash 语义，再接入 UI。
4. **安装包、自动更新与 Linux 集成测试**：决定 Flatpak / Snap / AppImage 路线，并补真实窗口冒烟与帧率测试。

## 8. 代码索引

| 主题 | 位置 |
| --- | --- |
| 平台工厂与保护根 | [lib/core/platform/cleaner_platform.dart](../lib/core/platform/cleaner_platform.dart) |
| 启动时的平台分支 | [lib/main.dart](../lib/main.dart) |
| Windows 规则 | [lib/core/rules/windows_rules.dart](../lib/core/rules/windows_rules.dart) |
| Linux 规则 | [lib/core/rules/linux_rules.dart](../lib/core/rules/linux_rules.dart) |
| Linux 原生通道 | [linux/runner/native_channels.cc](../linux/runner/native_channels.cc) |
| 文件元数据 | [lib/core/clean/file_metadata.dart](../lib/core/clean/file_metadata.dart) |
| 目录枚举 | [lib/core/platform/directory_enum.dart](../lib/core/platform/directory_enum.dart) |
| 占用检测 | [lib/core/platform/file_lock_probe.dart](../lib/core/platform/file_lock_probe.dart) |
| 扫描优先级 | [lib/core/platform/scan_priority.dart](../lib/core/platform/scan_priority.dart) |
| 窗口外壳 | [lib/platform/window_chrome.dart](../lib/platform/window_chrome.dart) |
| Linux 打包 | [tool/package_linux.sh](../tool/package_linux.sh) |
| Linux CI | [.github/workflows/linux.yml](../.github/workflows/linux.yml) |
