# Linux 与 Windows 功能差距评估

> 评估对象：Broom 0.4.0（`pubspec.yaml`，0.4.0+4）
> 评估日期：2026-10-24
> 结论：Linux 已具备“规则扫描 → 预览 → 隔离区 → 撤销 / 永久释放”的完整核心闭环，并补齐回收站、卸载残留、规则在线更新与软件更新检查入口。剩余差距集中在同名功能的能力降级、系统缓存实机验证，以及分发与真实窗口测试。

## 1. 总览

| 能力 | Windows | Linux | 差距性质 |
| --- | --- | --- | --- |
| 规则扫描、预览、选择、清理 | 支持 | 支持 | 已对齐 |
| 隔离区撤销、永久释放、清理历史、保留策略 | 支持 | 支持 | 已对齐 |
| 设置、配置导入导出、排除列表、国际化 | 支持 | 支持 | 已对齐 |
| 重复文件、大文件分析 | 支持 | 支持 | 已对齐 |
| 系统缓存（Windows Update / 传递优化 / Windows.old） | 支持，需 UAC | 支持 APT / DNF 包缓存与 systemd journal，需 Polkit 助手 | Fedora VM 已验证；APT / SELinux 待补测 |
| 回收站查看与清空 | 支持 | 支持 freedesktop Trash（用户回收站 + 可访问磁盘） | 已对齐，平台语义不同 |
| 卸载残留检测 | 支持，依赖注册表 | 支持 dpkg / rpm / Flatpak / Snap 清单与桌面文件 | 已对齐，采用策划清单 |
| 规则在线更新、签名校验、回滚 | 支持 | 支持，需构建时签名密钥与 HTTPS 清单 | 已对齐，发布配置需提供 |
| 应用软件更新检查 | 支持，MSIX / App Installer | 支持 HTTPS JSON 清单，只读检查 | 已对齐，升级仍由用户完成 |
| NTFS 索引加速 | 支持，USN / MFT | 无等价实现 | 功能缺失 |
| 文件占用预检 | 原生通道 | 空实现 | 能力降级 |
| 原生目录枚举 | `FindFirstFileW` | `dart:io` + 逐文件 `stat` | 性能差距 |
| 元数据恢复 | 时间 / 只读 / DACL 尽力恢复 | 权限位 + 时间 | 能力降级 |
| 扫描低优先级 | 后台模式 + 低 CPU 优先级 | `nice 10` | 能力降级 |
| 自定义窗口标题栏 | 支持 | GTK 原生标题栏 | 表现差异 |
| 安装器与自动更新 | MSIX + App Installer | tar.gz | 分发差距 |
| 真实窗口集成测试 | 支持，手动触发 | 无 | 验证差距 |

## 2. 仍缺失或需要降级的入口

Linux 上这些入口没有控制器，侧边栏和设置页会直接隐藏或跳过渲染。

### 2.1 系统缓存（Linux 已通过独立助手实现）

Windows 侧由 `SystemCacheController` 承担，依赖 UAC 提权、Windows Update `SoftwareDistribution\Download`、传递优化 `DeliveryOptimization\Cache` 与 `Windows.old`：

- 控制器只在 Windows 分支创建：[lib/main.dart](../lib/main.dart#L197-L212)
- 平台实现只支持 Windows：[lib/core/platform/system_cache_platform.dart](../lib/core/platform/system_cache_platform.dart#L82-L86)
- 权限与目录定位只支持 Windows：[lib/core/platform/system_access.dart](../lib/core/platform/system_access.dart#L122-L125)

Linux 不复用逐文件控制器，而是通过独立的 Polkit 助手执行固定操作：APT 包缓存、DNF 包缓存与 7 天前的 systemd journal。入口只在助手、policy 与 `pkexec` 均可用时显示；`/var`、`/snap`、`/nix` 等目录仍是保护根，路径不会从 UI 穿过提权边界。实现与 VM 验证清单见 [linux-system-cache.md](linux-system-cache.md)。

### 2.2 回收站

Windows 通过 `broom/shell` 的 `queryRecycleBin` / `emptyRecycleBin` 提供回收站查看与清空；Linux 在同一通道上实现了 freedesktop Trash：

- 原生实现：[linux/runner/native_channels.cc](../linux/runner/native_channels.cc)
- 入口在 Windows 与 Linux 显示：[lib/app.dart](../lib/app.dart)

实现细节：

- 统计用户回收站（`$XDG_DATA_HOME/Trash`）与所有可访问挂载点的 `.Trash/$uid` / `.Trash-$uid`。
- 只接受属于当前用户、且组 / 其他用户不可写的真实目录；不跟随符号链接。空目录或不可访问的挂载点会被安全跳过。
- 清空只删除识别出的回收站中的 `files/` 与 `info/` 内容，保留回收站目录本身。
- 与 Windows 一样属于 Review 级：永久删除、不进入 Broom 隔离区、没有撤销入口，并且需要勾选确认。

### 2.3 卸载残留

Windows 依赖原生 `broom/apps` 通道读取注册表安装清单；Linux 使用只读包管理器清单与桌面文件：

- 安装清单：[lib/core/platform/linux_installed_apps.dart](../lib/core/platform/linux_installed_apps.dart)
- Linux 策划清单：[lib/core/rules/linux_leftover_catalog.dart](../lib/core/rules/linux_leftover_catalog.dart)
- 服务在 Windows 与 Linux 创建：[lib/main.dart](../lib/main.dart)

检测规则：

- 通过 `dpkg-query`、`rpm -qa`、`flatpak list`、`snap list` 读取已安装包；同时解析 `$XDG_DATA_HOME/applications` 与 `$XDG_DATA_DIRS` 下的 `.desktop` 文件。
- 任一包管理器存在但执行失败时，清单标记为不完整，卸载残留检测与清理前复核都会失败关闭，不猜测应用已卸载。
- 只有已策划应用的数据目录存在、且包名、显示名、Flatpak / Snap / 本地二进制安装标记全部缺失时，才生成 `leftover.*` 的 Review 规则。
- 当前覆盖 Slack、Discord、VS Code、Obsidian、Spotify、Signal 与 Zoom；数据目录限定在 XDG 配置 / 缓存目录，不会指向整个 `$HOME` 或共享目录。

### 2.4 规则在线更新

Windows 与 Linux 现在共享同一套 HTTPS 清单、构建期 HMAC 签名校验、上一版回滚与恢复内置规则：

- 控制器在 Windows 与 Linux 创建：[lib/main.dart](../lib/main.dart)
- Linux 规则目录可变：[lib/core/platform/cleaner_platform.dart](../lib/core/platform/cleaner_platform.dart)
- 启动时加载激活规则目录：[lib/main.dart](../lib/main.dart)
- 目录位置沿用 `$XDG_DATA_HOME/Broom/rules/{active,previous}.json`

Linux 的内置版本为 `builtin-linux-3`；没有激活目录时保持该版本，不会被通用 store 的 `builtin` 覆盖。设置页的“规则更新”区块现在会在 Linux 显示，但只有在构建时注入 `--dart-define=BROOM_RULE_SIGNING_KEY=...` 并填写 HTTPS 更新地址后才能实际检查和应用更新。包含扩展旧版本等版本感知规则的清单必须使用 `schemaVersion: 2`，避免旧客户端把 profile 根当成普通扫描根。

### 2.5 应用软件更新

Windows 通过 `.appinstaller` 与 MSIX 提供更新提示；Linux 读取一个只读 JSON 清单：

- Linux 清单解析：[lib/core/app/linux_app_update_service.dart](../lib/core/app/linux_app_update_service.dart)
- 控制器在 Windows 与 Linux 创建：[lib/main.dart](../lib/main.dart)

Linux 清单包含 `schemaVersion`、`version`、可选的 `publishedAt`、HTTPS 下载地址与 SHA-256。设置页展示当前版本、更新源、发现的新版本与下载地址；应用本身不下载、不执行安装程序。RPM 用户通过包管理器升级，tar.gz 用户替换解压目录。默认更新源为 `https://melaine-iceberg.github.io/broom/broom-linux.json`，可通过 `--dart-define=BROOM_LINUX_UPDATE_FEED=...` 覆盖。

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
| Linux | 48 | 系统 4、日志 3、GPU 2、浏览器 6、浏览器扩展 1、应用 6、开发工具 26 |

- Windows 规则：[windows_rules.dart](../lib/core/rules/windows_rules.dart)
- Linux 规则：[linux_rules.dart](../lib/core/rules/linux_rules.dart)

Linux 目前覆盖缩略图、fontconfig、Flatpak / Snap 用户缓存、Broom 诊断日志、应用日志与 Xorg 会话日志、Mesa / NVIDIA 着色器、Chrome / Chromium / Edge / Brave / Firefox（含 Chromium `ScriptCache` 与按 `Preferences` 保留当前版本的扩展旧版本）、VS Code / Discord / Slack / Teams / Spotify / Flatpak 应用缓存，以及 pip、npm、Yarn、pnpm、Bun、uv、Go、Cargo、Gradle、Pub、Maven、Playwright、Composer、Electron、Poetry、node-gyp、Deno、Corepack、vcpkg、AUR 助手（yay / paru / pikaur）、NuGet、JetBrains、Hugging Face、conda、Coursier、Kotlin/Native 缓存。

Windows 侧存在但 Linux 没有对应规则的包括：

- 系统临时文件、崩溃转储、Windows 错误报告（WER）
- Docker、WSL、Scoop

Linux 侧仍受平台语义限制、不能简单照搬为普通规则的目标：

- Flatpak / Snap 的系统级旧 revision、`/var/lib/flatpak`、`/var/lib/snapd` 与 `/var/cache/snapd` 仍在保护根中，由各自工具管理；普通规则只覆盖用户级缓存
- pacman 的系统缓存 `/var/cache/pacman/pkg` 属于保护根；普通规则只覆盖 yay / paru / pikaur 的用户缓存
- 回收站不作为普通清理规则，而是独立工具（见 2.2）
- systemd journal 与 `/var/log` 由系统助手处理或受保护，不进入普通规则（见 2.1）
- vcpkg 的自定义克隆路径只有在导出 `VCPKG_ROOT`、`VCPKG_DOWNLOADS` 或 `VCPKG_DEFAULT_BINARY_CACHE` 时才能被发现
- Firefox 扩展没有按版本号组织的目录，扩展旧版本规则只覆盖 Chromium 系浏览器

规则在线更新已在 Linux 接入；默认发布仍需构建时注入签名密钥并配置 HTTPS 清单，未配置时入口会明确提示而不会静默使用未验证规则。

## 5. 分发、更新与验证

### 5.1 分发

Windows：

- 签名 MSIX、开始菜单项、卸载与就地升级
- `.appinstaller` 自动更新源
- 便携 ZIP 与 SHA-256
- 详见 [README.md](../README.md#L309-L329) 与 [packaging.md](packaging.md)

Linux：

- `flutter build linux --release` + [tool/package_linux.sh](../tool/package_linux.sh)
- tar.gz 便携版，附带 `.desktop` 与图标，需要用户手动复制到应用目录
- Fedora / RHEL 系 RPM，包含系统助手与 Polkit policy，可用 `BROOM_RPM_SIGN_KEY` 签名（[tool/package_rpm.sh](../tool/package_rpm.sh)）
- 设置页提供只读软件更新检查（HTTPS JSON 清单），不自动下载或安装
- 没有软件源、自动更新安装、Flatpak / Snap / AppImage 或沙箱包

路线图仍待办：Flatpak / Snap / AppImage、Wayland 下“打开文件位置”验证、Snap 沙箱内的隔离区路径约定（[roadmap.md](roadmap.md#L235-L244)）。

### 5.2 测试与 CI

- Linux CI 执行格式校验、严格静态检查、单元 / Widget 测试、C++ 助手测试、Release 构建、tar.gz 与 Fedora RPM 打包（[.github/workflows/linux.yml](../.github/workflows/linux.yml)）
- Windows CI 额外提供真实窗口冒烟测试与帧率基准，手动触发（[.github/workflows/windows.yml](../.github/workflows/windows.yml#L67-L90)）
- Linux 平台逻辑已有测试覆盖：[linux_platform_test.dart](../test/linux_platform_test.dart)、[posix_quarantine_test.dart](../test/posix_quarantine_test.dart)、[linux_rule_audit_test.dart](../test/linux_rule_audit_test.dart)
- 新增入口的测试：[linux_installed_apps_test.dart](../test/linux_installed_apps_test.dart)、[linux_leftover_catalog_test.dart](../test/linux_leftover_catalog_test.dart)、[linux_leftover_service_test.dart](../test/linux_leftover_service_test.dart)、[linux_rule_update_test.dart](../test/linux_rule_update_test.dart)、[linux_app_update_service_test.dart](../test/linux_app_update_service_test.dart)
- Linux 没有真实窗口的 UI 集成测试，也没有 GTK / Wayland 下的手工回归记录；回收站、卸载残留与更新入口的实机行为仍由维护者验证

## 6. 已对齐的能力

以下能力在 Linux 上已经完整可用，不应计入差距：

- 规则扫描、类别过滤、逐文件选择、搜索 / 筛选 / 排序
- 预览、扫描摘要、结果持久化与恢复
- 隔离区移动、撤销、永久释放、会话续跑、清理历史、保留策略
- 排除列表、路径守卫、配置导入导出、设置迁移
- 重复文件与大文件分析
- 48 条内置规则（33 条 Safe、15 条 Review），覆盖日志、浏览器脚本与扩展旧版本、Flatpak / Snap 用户缓存、应用缓存与常用开发工具缓存
- 回收站查看与清空（freedesktop Trash，永久删除、需确认）
- 卸载残留检测（包管理器清单 + 桌面文件 + 策划 XDG 清单）
- 签名规则目录的在线更新、回滚与恢复内置规则（需要构建密钥与 HTTPS 清单）
- 软件更新检查（HTTPS JSON 清单，只读）
- 磁盘空间查询（`statvfs`）
- 文件夹 / JSON 文件选择器（GTK）
- 定位文件（Gio 打开默认文件管理器）
- 扫描低优先级（`nice`）
- Windows / POSIX 路径语义、大小写敏感性、跨卷 `st_dev` 探测
- 中英文界面、主题、无障碍与键盘快捷键

## 7. 后续建议

按投入产出排序：

1. **系统缓存实机验证**：Fedora VM 已覆盖安装、授权、DNF 与 journal；剩余 Debian / Ubuntu 的 APT、SELinux enforcing、卸载回滚与负向认证场景。见 [linux-system-cache.md](linux-system-cache.md)。
2. **文件占用预检与原生目录枚举**：前者提升预览可预期性，后者降低大目录扫描的系统调用次数。
3. **回收站、卸载残留与更新入口的实机回归**：在 GNOME / KDE 上验证 freedesktop Trash 的多磁盘与权限场景、包管理器清单与实际卸载应用，以及规则 / 软件更新清单的 HTTPS 流程。
4. **规则目录扩容与分发**：系统级 Flatpak / Snap revision 与 pacman / zypper 需要扩展提权助手；决定 Flatpak / Snap / AppImage 路线，补真实窗口冒烟与帧率测试。

## 8. 代码索引

| 主题 | 位置 |
| --- | --- |
| 平台工厂与保护根 | [lib/core/platform/cleaner_platform.dart](../lib/core/platform/cleaner_platform.dart) |
| 启动时的平台分支 | [lib/main.dart](../lib/main.dart) |
| Windows 规则 | [lib/core/rules/windows_rules.dart](../lib/core/rules/windows_rules.dart) |
| Linux 规则 | [lib/core/rules/linux_rules.dart](../lib/core/rules/linux_rules.dart) |
| Linux 原生通道（含回收站） | [linux/runner/native_channels.cc](../linux/runner/native_channels.cc) |
| 回收站页面 | [lib/ui/recycle_bin_page.dart](../lib/ui/recycle_bin_page.dart) |
| Linux 已安装应用清单 | [lib/core/platform/linux_installed_apps.dart](../lib/core/platform/linux_installed_apps.dart) |
| Linux 卸载残留清单 | [lib/core/rules/linux_leftover_catalog.dart](../lib/core/rules/linux_leftover_catalog.dart) |
| 卸载残留服务 | [lib/core/leftover/leftover_service.dart](../lib/core/leftover/leftover_service.dart) |
| 规则目录与在线更新 | [lib/core/rules/rule_catalog_store.dart](../lib/core/rules/rule_catalog_store.dart)、[lib/core/rules/rule_update_service.dart](../lib/core/rules/rule_update_service.dart) |
| Linux 软件更新检查 | [lib/core/app/linux_app_update_service.dart](../lib/core/app/linux_app_update_service.dart) |
| 文件元数据 | [lib/core/clean/file_metadata.dart](../lib/core/clean/file_metadata.dart) |
| 目录枚举 | [lib/core/platform/directory_enum.dart](../lib/core/platform/directory_enum.dart) |
| 占用检测 | [lib/core/platform/file_lock_probe.dart](../lib/core/platform/file_lock_probe.dart) |
| 扫描优先级 | [lib/core/platform/scan_priority.dart](../lib/core/platform/scan_priority.dart) |
| 窗口外壳 | [lib/platform/window_chrome.dart](../lib/platform/window_chrome.dart) |
| Linux 打包 | [tool/package_linux.sh](../tool/package_linux.sh) |
| Linux CI | [.github/workflows/linux.yml](../.github/workflows/linux.yml) |
