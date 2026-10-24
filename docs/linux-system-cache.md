# Linux 系统级缓存清理：提权模型、保护根与 RPM 交付

> 状态：阶段 1–3 已实现；仓库测试、Fedora WSL 构建与 Fedora Hyper-V VM 验证（GNOME/KDE 的安装、入口、pkexec 认证、DNF/journal 清理与图标）均已通过。APT、SELinux enforcing、卸载回滚与负向认证场景仍待补测。
> 日期：2026-10-24
> 范围：Linux 桌面版；最终只交付 RPM，实机验证由项目维护者在虚拟机中完成

## 1. 结论

- **采用 Polkit 作为唯一授权通道**，由 root 所有的固定功能助手执行系统级操作。
- MVP 使用 **`pkexec` + 一次性助手**，不实现常驻 D-Bus 服务；后续需要进度信号、长任务或 Flatpak 支持时再迁移到 D-Bus。
- **保护根不调整**。`/var`、`/snap`、`/nix`、`/run`、`/opt` 继续由 `PathGuard` 保护；系统缓存不进入普通 `CleanerRule`，也不允许路径从 UI 穿过提权边界。
- 当前实现三个操作：**APT 包缓存**、**DNF 包缓存**与 **systemd journal**；Flatpak、Snap、pacman、zypper 暂不实现。APT 与 DNF 是否出现在 UI 中由助手探测固定工具路径后决定，不按发行版名称硬编码。
- 第三阶段只产出 **RPM**，不产出 deb、Flatpak、Snap 或 AppImage；不在打包过程中安装或运行系统级操作，VM 中的安装、授权、SELinux 与回滚验证由维护者执行。

## 2. 背景与约束

Linux 端目前只做用户级缓存清理。系统级缓存入口在 Linux 上被隐藏，原因不是 UI 缺失，而是还没有确定：

1. 如何把一次清理请求安全地交给 root；
2. 如何避免普通规则、扫描结果或 UI 错误扩大 root 删除面；
3. 如何在不破坏包管理器状态的前提下清理系统缓存；
4. 如何分发需要安装到系统目录的助力和 Polkit policy。

现有 Windows 系统缓存实现不能直接复用到 Linux：

- `SystemCacheRule` / `SystemCacheLocation` 是 Windows 固定目录模型；
- `SystemAccess` 依赖 UAC 和 `--system-cache` 自重启；
- `FileSystemCacheCleaner` 逐文件永久删除，适合固定目录，不适合包管理器和 journald；
- Linux 的 `/var`、`/snap` 等目录属于保护根，不应为了系统缓存而放开给普通文件引擎。

## 3. 方案比较

| 方案 | 结论 |
| --- | --- |
| Polkit + `pkexec` + 固定操作助手 | **采用**。一次性 root 进程、无常驻服务、打包相对简单 |
| Polkit + D-Bus system helper | 后续演进。适合进度信号、长任务、Flatpak 宿主集成 |
| Flutter 直接 `pkexec apt-get clean` | 拒绝。应用获得任意 root 命令执行面 |
| `sudo` + NOPASSWD / setuid 助手 | 拒绝。绕过 Polkit、审计差、风险高 |
| 把 `/var` 从保护根移除，复用普通扫描 | 拒绝。普通规则错误会直接影响系统目录 |
| PackageKit 作为唯一后端 | 不采用。缓存清理语义因后端而异，且不覆盖 journald |
| 不做提权，只展示提示 | 可作为 tar.gz / Flatpak 版本的降级行为，但不是完整功能 |

### 3.1 为什么选择 `pkexec` 而不是 D-Bus

- 两个操作都是短时的一次性任务，不需要常驻进程。
- `pkexec` 直接完成“认证 + 以 root 执行一次”的流程，代码量和打包项都更少。
- 助手的授权通过 `org.freedesktop.policykit.exec.path` 绑定到专用 Polkit action，不使用通用的 `org.freedesktop.policykit.exec`。
- 官方 `pkexec` 没有 `--action-id` 参数；网上部分示例使用它并不可靠。正确做法是让 action 的 `exec.path` 注解指向助手绝对路径。
- 代价是：无法在助手运行期间通过 D-Bus 发送进度；MVP 用一次性 JSON 结果即可。Flatpak / Snap 沙箱不能直接调用 `pkexec`，这些版本继续隐藏系统缓存。

## 4. 信任边界与调用链

```text
Flutter UI（普通用户）
  │  只传固定的 operation id，不传路径、不传 shell 命令
  ▼
/usr/bin/pkexec
  │  Polkit 通过 com.broom.Broom.clean-system-cache 授权
  ▼
/usr/libexec/broom/broom-system-helper（root，一次性进程）
  │  只接受白名单操作；拒绝任意参数
  ├─ /usr/bin/apt-get clean            （DEBIAN_FRONTEND=noninteractive）
  ├─ /usr/bin/dnf clean packages
  └─ /usr/bin/journalctl --vacuum-time=7d
  ▼
JSON 结果 → Flutter UI
```

关键原则：

- **UI 与 root 之间只传枚举操作名**，不传文件路径、不传命令、不传环境变量。
- 助手不接受“清理某个目录”这样的参数；DNF 和 journald 的路径由助手自己固定解析。
- 助手不直接遍历并删除 `/var` 下的文件，而是调用对应的系统工具，保留包管理器/ journald 自身的元数据与锁语义。
- 普通扫描器和 `PathGuard` 不接触这些路径；系统缓存有独立的操作白名单。

## 5. 特权助手设计

### 5.1 安装位置与权限

| 项目 | 路径 / 权限 |
| --- | --- |
| 助手 | `%{_libexecdir}/broom/broom-system-helper`，Fedora 为 `/usr/libexec/broom/broom-system-helper` |
| 助手权限 | `root:root`，`0755`，非 setuid |
| Polkit policy | `%{_datadir}/polkit-1/actions/com.broom.Broom.policy` |
| policy 权限 | `root:root`，`0644` |
| 应用 ID | `com.broom.Broom`（与 `linux/CMakeLists.txt` 的 `APPLICATION_ID` 一致） |

助手必须位于 root 所有、普通用户不可写的目录；不允许放在用户主目录、`/tmp` 或应用自身的 `bundle` 中再通过 `pkexec` 执行。

阶段 1 的独立构建使用 CMake 的 `GNUInstallDirs`，并以 `-DCMAKE_INSTALL_PREFIX=/usr` 对齐上表路径。policy 模板在同一次配置中展开助手绝对路径，避免打包时再做文本替换。CI 只构建和测试，不执行安装。

### 5.2 CLI 契约

```text
broom-system-helper --list --json
broom-system-helper --run dnf-packages,journal-7d --json
broom-system-helper --self-test
```

- `--list` / `--self-test` 可以普通用户运行，只做能力探测和只读校验。
- `--run` 必须以 root 运行；非 root 返回明确的错误码，不尝试自我提权。
- 操作使用稳定 id：
  - `apt-cache`
  - `dnf-packages`
  - `journal-7d`
- 不接受 `--path`、`--command`、`--shell` 或任意自由文本参数。
- 一次调用最多执行一组已列出的操作，去重后按固定顺序执行；Polkit 只认证一次。
- 输出只走 stdout，诊断走 stderr；stdout 必须是可解析 JSON。

建议结果格式：

```json
{
  "schemaVersion": 1,
  "operations": [
    {
      "id": "dnf-packages",
      "status": "ok",
      "exitCode": 0,
      "freedBytes": 123456789,
      "message": "dnf clean packages completed"
    },
    {
      "id": "journal-7d",
      "status": "skipped",
      "exitCode": null,
      "freedBytes": null,
      "message": "Journal vacuum is not available"
    }
  ]
}
```

状态至少区分：`ok`、`failed`、`busy`、`skipped`、`unavailable`。

### 5.3 助手内部约束

- 只接受编译期枚举的操作，未知 id 立即失败。
- 使用固定的绝对二进制路径，并检查目标存在、可执行、所有者为 root、不可被组/其他用户写。
- 使用 `fork` / `execve`（或 `posix_spawn`）直接执行，**不经过 shell**，不使用 `system()` / `popen()`。
- 环境变量最小化：
  - `PATH=/usr/sbin:/usr/bin:/sbin:/bin`
  - `LC_ALL=C`、`LANG=C`
  - APT 操作额外设置 `DEBIAN_FRONTEND=noninteractive`
  - 清除 `LD_*`、`BASH_ENV` 等可注入变量；pkexec 的环境清理不能替代助手自身的防御。
- 设置超时：APT / DNF 10 分钟、journal 2 分钟；超时后终止整个进程组并报告失败。
- 限制捕获输出大小（每路 1 MiB），避免恶意/异常输出耗尽内存。
- 使用 `/run/broom-system-helper.lock` + `flock` 串行化 Broom 自己的系统清理；锁被占用时逐项返回 `busy`。
- 不自行实现“删除目录内容”；APT / DNF / journald 的锁与状态由工具自己维护。
- 每个操作执行前再次校验固定工具路径；某个工具不可用时该项返回 `unavailable`，其他操作继续。
- 释放空间通过操作前后 `statvfs` 估算；无法测量时 `freedBytes` 为 `null`，UI 只显示操作结果。
- 所有路径都在助手内固定；不读取用户提供的配置路径，不读取 `$HOME`。
- 记录日志到 syslog/stderr，不写入用户目录，不记录包内容或用户路径明文。
- 助手退出后不保留状态；重复调用必须幂等或返回可用性错误。

### 5.4 操作语义

#### `apt-cache`

执行：

```text
/usr/bin/apt-get clean
```

- 额外设置 `DEBIAN_FRONTEND=noninteractive`，不通过 shell，也不接受额外参数。
- 只清理 `/var/cache/apt/archives` 中已下载的 `.deb` 包，不执行 `autoremove`，不卸载任何已安装软件。
- 固定工具路径为 `/usr/bin/apt-get`；Debian / Ubuntu 之外通常标记为不可用，UI 不显示这一项。
- Review 级：已下载包会被永久删除，之后重新安装需要重新下载；已安装软件不受影响。
- 包管理器正被占用时返回 `busy`，不等待、不杀其他进程。

#### `dnf-packages`

执行：

```text
/usr/bin/dnf clean packages
```

- 只清理已下载的包缓存，不执行 `autoremove`，不卸载任何已安装软件。
- 不使用 `dnf clean all`，避免同时删除仓库元数据、拖慢后续搜索/安装。
- 需要兼容 DNF5：Fedora 新版 `/usr/bin/dnf` 可能指向 dnf5，VM 中必须确认 `clean packages` 的退出码与行为。
- Review 级：已下载包会被永久删除，之后重新安装需要重新下载；已安装软件不受影响。
- DNF 正被占用时返回 `busy`，不等待、不杀进程。

#### `journal-7d`

执行：

```text
/usr/bin/journalctl --vacuum-time=7d
```

- 只清理系统 journal 中超过 7 天的归档日志；当前 journal 和 7 天内日志保留。
- 固定 7 天，MVP 不开放任意天数输入，避免参数验证和误操作面扩大。
- Review 级：日志永久丢失，可能影响问题排查；不进入隔离区，不能撤销。
- 只处理系统 journal，不处理用户 journal、`/var/log` 下的普通文本日志或应用日志。

### 5.5 错误与退出码

| 情况 | 行为 |
| --- | --- |
| 用户取消 Polkit 认证 | `pkexec` 返回非零；应用不执行任何操作 |
| 用户无管理员权限 | 认证失败；显示明确原因 |
| 助手不存在 / policy 不存在 / `pkexec` 不存在 | 系统缓存入口隐藏，或显示“未安装系统助手” |
| 助手参数非法 | 助手返回非零，不执行任何工具 |
| DNF 锁被占用 | 返回 `busy`，提示稍后再试 |
| SELinux 拒绝写入 | 返回失败和 stderr 摘要；VM 验证阶段记录 AVC |
| 工具执行失败 | 保留其他已执行操作的结果，逐项报告 |

## 6. Polkit policy

草案（文件名 `com.broom.Broom.policy`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/software/polkit/policyconfig-1.dtd">
<policyconfig>
  <vendor>Broom</vendor>
  <icon_name>broom</icon_name>

  <action id="com.broom.Broom.clean-system-cache">
    <description>Clean system package and journal caches</description>
    <message>Authentication is required to clean system caches</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>auth_admin</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/libexec/broom/broom-system-helper</annotate>
  </action>
</policyconfig>
```

仓库中的模板位于 `linux/system_helper/policy/com.broom.Broom.policy.in`，`@BROOM_HELPER_INSTALL_PATH@` 由 CMake 在配置时展开；CI 用 `xmllint` 校验生成的 policy。

约定：

- 只允许本地活跃会话发起；`allow_inactive=no` 拒绝远程/非活跃会话。
- 使用 `auth_admin`，不使用 `auth_self` 或 `yes`；默认不做 5 分钟免密缓存。
- 不随包安装 `/etc/polkit-1/rules.d` 规则；管理员可自行覆盖默认策略。
- policy 中的 `exec.path` 必须与最终安装路径完全一致。RPM 在不同发行版上 `%{_libexecdir}` 可能不同，因此打包时从模板生成 policy，或在 spec 中展开路径。
- 桌面必须存在 Polkit authentication agent；缺少 agent 时返回可读错误，不降级到自定义密码输入。
- 不通过 `pkexec` 执行 `dnf` / `journalctl` 本体；`exec.path` 只指向本助手。

## 7. 保护根策略

### 7.1 保持不变

`LinuxCleanerPlatform.protectedRoots` 继续包含：

```text
/usr /etc /boot /dev /proc /sys /run /bin /sbin /lib /lib64 /opt /var /snap /nix
```

理由：

- 普通规则、扫描器、隔离区、撤销与分析器都依赖 `PathGuard`；放开 `/var` 会让任意规则 bug 或路径构造错误获得系统级删除面。
- 系统缓存不需要把路径交给普通文件引擎。助手执行的是工具级操作，不是逐文件操作。
- 不把 `/var/cache/dnf`、`/var/log/journal` 加入普通规则，也不把 `SystemCacheRule` 扩展成 Linux 版本。

### 7.2 独立的操作白名单

- 助手内部维护操作 id 到固定命令的映射，不维护可配置路径。
- UI 只通过 `--list` 读取能力与可用性，不读取“可删除路径列表”。
- 系统缓存页不提供逐文件选择、不显示可被提交回 root 的绝对路径。
- 如果未来需要显示体积，只做只读探测；探测结果不作为删除输入。
- 需要一个回归测试，明确断言 `/var/cache/dnf`、`/var/log/journal`、`/snap/...` 仍是受保护路径，防止后续“为了方便”误放开。

## 8. Linux UI 与控制器（已实现）

- 侧边栏拆成两个能力位：
  - `showRecycleBin`：仍然仅 Windows；
  - `showSystemCache`：Windows 或 Linux 系统助手可用时显示。
- `main.dart` 只在 Linux 助手/policy/`pkexec` 均可用时创建 `LinuxSystemCacheController`；否则不创建控制器，入口隐藏。tar.gz 便携版默认不可用。
- 可用性探测只检查助手可执行、policy 文件存在、`/usr/bin/pkexec` 存在；不要用一次真实 `pkexec` 试运行来探测，否则会无谓弹出授权框。
- 独立的 `LinuxSystemCacheController` 和 `LinuxSystemCachePage`，不复用 Windows 的逐文件 `SystemCacheController`。
- 页面卡片只包含助手报告为可用的操作：
  - APT 包缓存（Debian / Ubuntu）；
  - DNF 包缓存（Fedora / RHEL）；
  - systemd journal（7 天）。
- 默认全部不勾选，属于 Review 级；确认框明确：
  - 永久删除、无隔离区、不可撤销；
  - APT / DNF 包需要重新下载；
  - journal 日志会丢失。
- 认证取消时不做任何更改，保留当前选择并提示；失败按操作逐项展示，不把整批结果伪装成成功。
- 助手缺失、policy 缺失、`pkexec` 缺失或助手探测失败时，页面显示对应降级说明与“重新检测”，不展示可执行操作。
- 清理完成后可重新检测；无法准确计算释放空间时，显示逐项操作结果而不是猜测字节数。

## 9. 第三阶段：RPM 打包（已实现）

### 9.1 范围

本阶段只产出 RPM：

- 目标：Fedora / RHEL 系 x86_64；
- 不产出 deb、Flatpak、Snap、AppImage；
- 不修改现有 tar.gz 产物；tar.gz 版本隐藏系统缓存入口；
- 不在打包脚本中执行系统清理、不安装 RPM、不要求 root；
- VM 中的安装与授权验证由维护者完成。

实现文件：

- `packaging/rpm/broom.spec`：安装预构建 bundle、助手、policy、desktop、图标与文档；
- `tool/package_rpm.sh`：构建 Flutter bundle（可跳过）与助手，生成 policy，调用 `rpmbuild -bb`，输出 `.rpm` 与 `.sha256`。

### 9.2 包内布局

| 内容 | 路径 |
| --- | --- |
| Flutter bundle | `%{_libdir}/broom/`（含 `broom`、`lib/`、`data/`） |
| 启动入口 | `%{_bindir}/broom` → `%{_libdir}/broom/broom` |
| 桌面文件 | `%{_datadir}/applications/com.broom.Broom.desktop` |
| 图标 | `%{_datadir}/icons/hicolor/{256x256,512x512,256x256@2,512x512@2}/apps/broom.png` |
| 系统助手 | `%{_libexecdir}/broom/broom-system-helper` |
| Polkit policy | `%{_datadir}/polkit-1/actions/com.broom.Broom.policy` |
| 文档 | `%{_docdir}/broom/`（README、本设计文档） |
| 许可证 | `%{_datadir}/licenses/broom/LICENSE` |

说明：

- 助手和 policy 必须由 RPM 以 root 所有权安装，不能由应用自行写入。
- 入口符号链接是否影响 Flutter 查找 `data/` / `lib/` 必须在 VM 中验证；如果 `/proc/self/exe` 解析不符合预期，改为安装一个极小的 shell wrapper 或直接 `Exec=%{_libdir}/broom/broom`。
- 图标按 256 / 512 以及对应的 `@2` 目录安装；不要在 `hicolor` 下新建 1024×1024 目录，Fedora 的 `index.theme` 不索引它，GTK 会直接忽略该图标。

### 9.3 Spec

实际 spec 位于 [packaging/rpm/broom.spec](../packaging/rpm/broom.spec)。关键约束：

- `Version` 由脚本从 `pubspec.yaml` 读取，通过 `--define "broom_version ..."` 传入；`Release` 为 `1%{?dist}`，因此 Fedora 上产物类似 `broom-0.4.0-1.fc44.x86_64.rpm`。
- `BuildArch: x86_64`；本阶段是预构建 binary RPM，不是 Fedora 官方仓库要求的 from-source 包。
- `AutoReqProv: no` + 显式 `Requires: polkit systemd gtk3 gtk-update-icon-cache glib2 libstdc++ xz-libs`；关闭 RPM 的 strip / rpath 后处理，避免改动 Flutter 预构建库。
- 助手安装为 `%{_libexecdir}/broom/broom-system-helper`（`%attr` 固定 0755，root:root），policy 安装为 `%{_datadir}/polkit-1/actions/com.broom.Broom.policy`（0644，root:root）；desktop 与各尺寸图标也用 `%attr` 固定 0644。
- 桌面文件安装为 `com.broom.Broom.desktop`，与 `linux/CMakeLists.txt` 的 `APPLICATION_ID` 一致，面板和任务栏才能把运行中的窗口关联到应用图标；`%post` / `%postun` 刷新 hicolor 图标缓存与 desktop database。
- 应用入口使用相对于 `%{_bindir}` 计算的符号链接（Fedora 上为 `../lib64/broom/broom`），避免绝对符号链接告警，也不假设 `%{_libdir}` 的具体布局。
- `License: MIT`；仓库根目录的 `LICENSE` 通过 `%license` 安装到 `%{_datadir}/licenses/broom/LICENSE`。
- `URL`、维护者邮箱与 changelog 身份仍需在正式出包前替换。

### 9.4 构建脚本

`tool/package_rpm.sh` 的流程：

1. 读取 `pubspec.yaml` 版本，校验 Linux x86_64 与 `rpmbuild` 等依赖；
2. 默认执行 `flutter build linux --release`；`--skip-flutter-build` 可复用已有 bundle；
3. `cmake -S linux/system_helper -B build/system-helper-rpm -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr` 并构建助手；
4. 生成 policy（展开 `%{_libexecdir}`），并用 `rpm --eval '%{_libexecdir}/broom/broom-system-helper'` 校验它指向本发行版的实际安装路径；
5. 把 bundle、助手、desktop、图标、policy、README 与本设计文档暂存为 `broom-bundle-<version>.tar.gz`；
6. `rpmbuild -bb packaging/rpm/broom.spec --define "_topdir ..." --define "broom_version ..."`；
7. 输出 `dist/broom-<version>-1.<dist>.x86_64.rpm` 与 `.sha256`；
8. 可选：设置 `BROOM_RPM_SIGN_KEY` 时用 `rpm --addsign` 签名，并重新生成 `.sha256`。

约束：

- 使用普通用户运行 `rpmbuild`，不要用 root 构建；
- 仓库必须位于 Linux 原生文件系统。WSL 的 `/mnt/...` 是 9p/v9fs，`chmod` 会被静默忽略，导致包内所有文件记录为 0777；脚本会检测文件系统类型和 `chmod` 是否生效，检测失败时直接退出；
- RPM 构建需要 Linux 环境（Fedora，或安装了 `rpm-build` 的 Ubuntu）；当前 Windows 工作区不执行 RPM 构建；
- 构建机需要 `rpm-build`、`cmake`、C++ 工具链和 Flutter；
- 构建脚本只打包，不安装、不执行助手、不运行 `pkexec`、`dnf`、`apt-get` 或 `journalctl`；
- RPM 默认作为未签名的本地测试包；正式分发前用维护者 GPG 密钥签名。
- RPM 默认不签名；安装 `rpm-sign`、配置并解锁 GPG 密钥后，用 `BROOM_RPM_SIGN_KEY="<key-id>" bash tool/package_rpm.sh` 签名。密钥不进入仓库。
- CI 在 Ubuntu 上跑测试并构建 tar.gz；另有 Fedora 44 容器任务复用该 bundle 构建 RPM，校验 License、权限与 desktop 路径。`pkexec` 与真实清理仍在 VM 中验证。

### 9.5 依赖与安装行为

- spec 显式声明 `Requires: polkit systemd gtk3 glib2 libstdc++ xz-libs`。`polkit` 提供 `pkexec` 和 policy 基础设施；Fedora 上的确切包名以 `dnf provides /usr/bin/pkexec` 核对。
- `systemd` 提供 `journalctl`；没有 systemd 的系统隐藏 journal 操作。
- APT / DNF 不作为强依赖：助手在运行时探测 `/usr/bin/apt-get` 与 `/usr/bin/dnf`，不存在时 `--list` 标记为不可用，UI 不显示该项。
- 预构建 bundle 关闭了 RPM 的自动 ELF 依赖生成（`AutoReqProv: no`），因此 GTK/GLib 运行时依赖由上面的显式 `Requires` 承担；出包后用 `rpm -qpR` 核对。
- 安装包中的助手为 `0755 root:root`，policy 为 `0644 root:root`，均不 setuid。
- 安装后不需要启用 systemd 服务、不需要 D-Bus 重新加载、不需要 `polkitd` 重启；policy 放入标准目录即可被识别。
- 卸载 RPM 删除助手、policy 和桌面入口；`$XDG_DATA_HOME/Broom` 中的配置、隔离区与历史继续保留，遵循现有数据保留策略。
- 卸载不会恢复已被永久清理的 APT / DNF 缓存或 journal；这一点在卸载文档与 UI 中都要说明。

## 10. 验证计划

### 10.1 仓库内自动化

阶段 1–2 已覆盖：

- C++ CTest：参数解析、操作白名单、未知操作、非 root 拒绝、JSON 结构与转义、自检的 root 所有权 / 权限规则；锁被占用时逐项报告 `busy`；固定执行器用真实 `/usr/bin/true`、`/usr/bin/false` 与超时进程验证进程组终止和状态映射。
- Dart 测试：可用性探测不启动进程、`--list` / `--self-test` 直接调用助手、pkexec 参数只含固定 operation id、APT → DNF → journal 顺序、认证取消与失败映射、部分失败与异常 JSON 的拒绝。
- Dart UI fake 测试：只显示助手报告可用的操作、入口按能力位隐藏、默认不勾选、确认勾选门槛、认证取消无副作用、助手缺失降级。
- policy：Linux CI 用 `xmllint` 校验 CMake 生成的 policy。
- RPM：`test/linux_rpm_packaging_test.dart` 检查 spec 的安装路径、依赖与脚本的只读约束；Linux CI 对打包脚本执行 `bash -n`。
- Fedora WSL 冒烟（2026-10-24）：本地 `rpmbuild` 成功；`%attr` 与权限探针确保助手 `0755`、policy / desktop / 图标 `0644`；GTK 能从 hicolor 的 256×256 目录解析到应用图标。

后续阶段待补：

- 输出截断与真实包管理器忙锁的 VM 验证。
- SELinux enforcing 下的助手域与 AVC 检查。
- Debian / Ubuntu 的 APT 路径与 RPM 卸载回滚验证。

CI 不运行真实 `pkexec` / APT / DNF / journald；这些留给 VM。

### 10.2 VM 手工验证（维护者执行）

建议使用 Fedora Workstation（DNF5）或等价 RHEL 系虚拟机；APT 路径另用 Debian / Ubuntu 虚拟机验证。

> 2026-10-24 Fedora Hyper-V VM 结果：RPM 安装与覆盖安装、`/usr/bin/broom` 菜单启动、系统缓存入口、pkexec 认证框、DNF 缓存与 journal 清理、GNOME 与 KDE 的应用图标均通过。仍待补测：APT（Debian / Ubuntu）、SELinux enforcing、卸载回滚、负向认证（取消 / 错误密码 / 无 agent / 非活跃会话）、tar.gz 在无助手环境的入口隐藏。

阶段 2 已实现真实执行，仓库测试不会运行系统工具。可先运行

```bash
cmake -S linux/system_helper -B build/system-helper \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/system-helper
sudo cmake --install build/system-helper
```

再执行下面第 3、4、6 步。`--run` 在授权成功后执行白名单工具；未在 VM 中验证前不要对生产系统执行。

1. `dnf install ./broom-<version>-1.<dist>.x86_64.rpm`。本地测试包不签名；若 VM 的仓库策略阻止未签名包，仅在隔离 VM 中使用 `rpm -i`，不要把这个流程带到正式分发。
2. `rpm -qpl broom` 与 `rpm -qpR broom` 检查文件列表和依赖。
3. `stat` 检查助手、policy 为 root 所有、不可被普通用户写。
4. `pkaction --action-id com.broom.Broom.clean-system-cache --verbose` 应能看到 action。
5. 启动应用，确认系统缓存入口出现；普通用户触发 DNF 与 journal 清理（Debian / Ubuntu VM 用 APT 与 journal）。
6. 分别测试：取消认证、错误密码、成功、无 Polkit agent、非活跃会话（如 SSH）。
7. 成功清理 DNF / APT 后确认只删除了包缓存，未卸载软件，仓库元数据策略符合预期。
8. 清理 journal 前后比较 `journalctl --disk-usage`，确认 7 天内/当前日志仍在。
9. 在 SELinux enforcing 下检查 `ausearch -m avc` / `journalctl -t audit`，记录是否有 AVC；如有，先修复或补策略，不带着拒绝上线。
10. 检查应用 bundle 通过 `/usr/bin/broom` 符号链接启动时，`data/`、`lib/` 与图标正常。
11. 卸载 RPM，确认助手、policy 和桌面入口被移除，用户配置/隔离区保留。
12. 用 tar.gz 版本确认系统缓存入口隐藏；用缺少 `pkexec` 或缺少 policy 的环境确认降级行为。

VM 验证中发现的问题应回写到本文件“已知风险 / 开放问题”一节，再进入下一步。

## 11. 分阶段实施与验收

### 阶段 1：助手骨架与授权链路（已实现，VM 验证通过）

- [x] 新增 `linux/system_helper/` 的 C++ 助手骨架、CMake 构建与 CTest。
- [x] 新增 policy 模板、CMake 展开与 `/usr/libexec` / `/usr/share` 安装约定；CI 校验 XML。
- [x] 新增 Dart `LinuxSystemMaintenance` 抽象、pkexec 客户端、严格 JSON 校验与 fake。
- [x] 助手支持 `--list` / `--self-test` / 参数校验；`--run` 在阶段 1 返回 `not_implemented`（该行为已被阶段 2 替换）。
- [x] 仓库内验收：CTest、Dart 单元测试、`flutter analyze` 全部通过。
- [x] VM 验收：Fedora Hyper-V VM 中 policy 被识别，GNOME / KDE 下 `pkexec` 均能弹出认证框。

### 阶段 2：APT / DNF / journal 操作 + UI（已实现，DNF / journal 已验证；APT 待补）

- [x] 实现 `apt-cache`、`dnf-packages`、`journal-7d` 与固定执行器（root 校验、串行锁、超时、输出上限、逐项状态）。
- [x] 新增 Linux 系统缓存页、控制器、侧边栏 `showSystemCache` / `showRecycleBin` 能力位。
- [x] 实现确认、认证取消、部分失败、忙锁、超时与助手缺失降级。
- [x] 验收：fake / CTest 测试覆盖全部状态；`flutter analyze` 与仓库测试通过。
- [x] VM 验收：Fedora VM 的 DNF 缓存与 journal 清理通过；APT 路径待 Debian / Ubuntu VM 补测。

### 阶段 3：RPM 打包（已实现，VM 验证通过）

- [x] 新增 `packaging/rpm/broom.spec`、`tool/package_rpm.sh`。
- [x] 生成包含助手、policy、desktop、图标、bundle 与文档的 RPM。
- [x] 输出 `.rpm` 与 `.sha256`。
- [x] 脚本不安装或运行 RPM；不实现 deb/Flatpak/Snap/AppImage。
- [x] 仓库内验收：Fedora WSL 可重复构建；`rpm -qpl` / `rpm -qpR` / 文件权限与校验和冒烟通过。
- [x] VM 验收：安装 RPM、从 `/usr/bin/broom` 启动并验证 Polkit 授权；GNOME / KDE 的图标与认证框均正常（`rpm -V` 已在 WSL 安装验证）。

### 后续（不在本次范围）

- Flatpak / Snap / AppImage 分发与沙箱内宿主助手方案；
- zypper / pacman 操作；
- D-Bus system helper、进度信号、长任务；
- RPM 签名、软件源、自动更新。

## 12. 已知风险与开放问题

1. **许可证**：已采用 MIT，`LICENSE` 随 RPM 安装；若未来更改许可证，需要同步 spec、README 与发布产物。
2. **SELinux**：`pkexec` 启动自定义助手后的 domain 与写入 `/var/cache/dnf`、`/var/log/journal` 的权限仍需在 SELinux enforcing 的 Fedora VM 中实测；若有 AVC，可能需要 SELinux policy 或改用 systemd service。
3. **包管理器兼容性**：DNF 路径已在 Fedora VM 验证；`apt-get clean` 仍待 Debian / Ubuntu VM 验证。实现只以退出码与固定参数为准，不解析本地化文本。
4. **Polkit agent**：GNOME / KDE 的正常认证框已通过；取消、错误密码、无 agent 与非活跃会话仍需补测，系统缓存入口应优雅降级。
5. **符号链接启动**：Flutter 通过 `/proc/self/exe` 定位 bundle；`/usr/bin/broom` 已通过 GNOME / KDE 菜单启动验证。
6. **授权面**：`pkexec` 本身是 setuid 组件，历史上出现过漏洞；助手必须保持最小、无可配置路径、无 shell，并跟随发行版的 polkit 更新。
7. **不可撤销**：DNF 缓存和 journal 都是永久删除，不进入隔离区；UI 必须明确说明。
8. **未来 D-Bus 迁移**：如果 Flatpak 或长任务成为近期目标，尽早切换到 D-Bus helper，避免两套授权入口长期并存。
9. **RPM 来源构建**：本阶段是预构建 binary RPM，不适合直接提交 Fedora 官方仓库；若要走官方源，需要补 from-source 构建、许可证与打包规范。
10. **VM 验证范围**：Fedora Hyper-V VM 已覆盖安装、菜单启动、pkexec 认证、DNF / journal 清理与 GNOME / KDE 图标；APT 路径、SELinux enforcing、卸载回滚和负向认证场景仍待补测，完成前不宣称这些路径已验证。

## 13. 代码与文档索引

| 主题 | 位置 |
| --- | --- |
| Linux 保护根与平台 | [lib/core/platform/cleaner_platform.dart](../lib/core/platform/cleaner_platform.dart) |
| 启动时平台分支 | [lib/main.dart](../lib/main.dart) |
| 侧边栏能力位 | [lib/ui/app_sidebar.dart](../lib/ui/app_sidebar.dart) |
| Windows 系统缓存控制器（不复用） | [lib/ui/system_cache_controller.dart](../lib/ui/system_cache_controller.dart) |
| Linux 系统助手（C++ 骨架） | [linux/system_helper](../linux/system_helper) |
| Polkit policy 模板 | [linux/system_helper/policy/com.broom.Broom.policy.in](../linux/system_helper/policy/com.broom.Broom.policy.in) |
| 助手单元测试 | [linux/system_helper/tests/helper_tests.cc](../linux/system_helper/tests/helper_tests.cc) |
| 固定操作执行器 | [linux/system_helper/src/runner.cc](../linux/system_helper/src/runner.cc) |
| Linux 系统维护契约与 pkexec 客户端 | [lib/core/platform/linux_system_maintenance.dart](../lib/core/platform/linux_system_maintenance.dart) |
| Linux 系统缓存控制器 | [lib/ui/linux_system_cache_controller.dart](../lib/ui/linux_system_cache_controller.dart) |
| Linux 系统缓存页与确认框 | [lib/ui/linux_system_cache_page.dart](../lib/ui/linux_system_cache_page.dart)、[lib/ui/linux_system_cache_confirm_dialog.dart](../lib/ui/linux_system_cache_confirm_dialog.dart) |
| Linux 系统维护测试 fake | [test/support/linux_system_maintenance_fakes.dart](../test/support/linux_system_maintenance_fakes.dart) |
| RPM spec | [packaging/rpm/broom.spec](../packaging/rpm/broom.spec) |
| RPM 构建脚本 | [tool/package_rpm.sh](../tool/package_rpm.sh) |
| RPM 回归测试 | [test/linux_rpm_packaging_test.dart](../test/linux_rpm_packaging_test.dart) |
| Linux 用户规则 | [lib/core/rules/linux_rules.dart](../lib/core/rules/linux_rules.dart) |
| Linux 规则与 Windows 差距 | [linux-windows-parity.md](linux-windows-parity.md) |
| Linux 打包现状 | [tool/package_linux.sh](../tool/package_linux.sh) |
| Linux CI | [.github/workflows/linux.yml](../.github/workflows/linux.yml) |

## 14. 外部参考

- pkexec / Polkit 授权与 `exec.path` 注解：[pkexec manual](https://www.freedesktop.org/software/polkit/docs/latest/pkexec.1.html)
- Polkit 与 privileged D-Bus service 模型：[Polkit - Gentoo Wiki](https://wiki.gentoo.org/wiki/Polkit)
- Polkit 系统守护进程与 setuid 风险说明：[polkitd package description](https://packages.debian.org/trixie/amd64/polkitd)
- PackageKit 的 Polkit/D-Bus 抽象（后续评估）：[PackageKit introduction](https://www.freedesktop.org/software/PackageKit/pk-intro.html)
