# Linux 系统级缓存清理：提权模型、保护根与 RPM 交付

> 状态：阶段 1 已实现（仓库侧测试通过）；pkexec 授权与安装布局的 VM 验证待维护者执行
> 日期：2026-10-23
> 范围：Linux 桌面版；最终只交付 RPM，实机验证由项目维护者在虚拟机中完成

## 1. 结论

- **采用 Polkit 作为唯一授权通道**，由 root 所有的固定功能助手执行系统级操作。
- MVP 使用 **`pkexec` + 一次性助手**，不实现常驻 D-Bus 服务；后续需要进度信号、长任务或 Flatpak 支持时再迁移到 D-Bus。
- **保护根不调整**。`/var`、`/snap`、`/nix`、`/run`、`/opt` 继续由 `PathGuard` 保护；系统缓存不进入普通 `CleanerRule`，也不允许路径从 UI 穿过提权边界。
- 第一阶段只做 **DNF 包缓存**与 **systemd journal** 两个操作；APT、Flatpak、Snap、pacman、zypper 暂不实现。
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
  - 未来 APT 操作额外设置 `DEBIAN_FRONTEND=noninteractive`
  - 清除 `LD_*`、`BASH_ENV` 等可注入变量；pkexec 的环境清理不能替代助手自身的防御。
- 设置超时：DNF 10 分钟、journal 2 分钟；超时后终止整个进程组并报告失败。
- 限制捕获输出大小（例如 1 MiB），避免恶意/异常输出耗尽内存。
- 使用 `/run/broom-system-helper.lock` + `flock` 串行化 Broom 自己的系统清理。
- 不自行实现“删除目录内容”；DNF/ journald 的锁与状态由工具自己维护。
- 所有路径都在助手内固定；不读取用户提供的配置路径，不读取 `$HOME`。
- 记录日志到 syslog/stderr，不写入用户目录，不记录包内容或用户路径明文。
- 助手退出后不保留状态；重复调用必须幂等或返回可用性错误。

### 5.4 操作语义

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

## 8. Linux UI 与控制器

- 侧边栏把现有 `showWindowsTools` 拆成两个能力位：
  - `showRecycleBin`：仍然仅 Windows；
  - `showSystemCache`：Windows 或 Linux 系统助手可用时显示。
- `main.dart` 只在 Linux 助手/policy/`pkexec` 均可用时创建 `LinuxSystemMaintenance`；否则传 `null`，入口隐藏。tar.gz 便携版默认不可用。
- 可用性探测只检查助手可执行、policy 文件存在、`/usr/bin/pkexec` 存在；不要用一次真实 `pkexec` 试运行来探测，否则会无谓弹出授权框。可选地用 `pkaction --action-id` 做只读校验。
- 新增独立的 `LinuxSystemCacheController` 和页面，不复用 Windows 的逐文件 `SystemCacheController`。
- 页面卡片只包含操作级信息：
  - DNF 包缓存；
  - systemd journal（7 天）。
- 默认全部不勾选，属于 Review 级；确认框必须明确：
  - 永久删除、无隔离区、不可撤销；
  - DNF 包需要重新下载；
  - journal 日志会丢失。
- 认证取消时不做任何更改；失败按操作逐项展示，不把整批结果伪装成成功。
- 估算体积可以只读扫描 `/var/cache/dnf`、调用 `journalctl --disk-usage`；读不到时显示“需要管理员权限”，不要为了估算而先弹一次授权。
- 清理完成后可重新探测；无法准确计算释放空间时，显示操作结果而不是猜测字节数。

## 9. 第三阶段：RPM 打包

### 9.1 范围

本阶段只产出 RPM：

- 目标：Fedora / RHEL 系 x86_64；
- 不产出 deb、Flatpak、Snap、AppImage；
- 不修改现有 tar.gz 产物；tar.gz 版本隐藏系统缓存入口；
- 不在打包脚本中执行系统清理、不安装 RPM、不要求 root；
- VM 中的安装与授权验证由维护者完成。

### 9.2 包内布局

| 内容 | 路径 |
| --- | --- |
| Flutter bundle | `%{_libdir}/broom/`（含 `broom`、`lib/`、`data/`） |
| 启动入口 | `%{_bindir}/broom` → `%{_libdir}/broom/broom` |
| 桌面文件 | `%{_datadir}/applications/broom.desktop` |
| 图标 | `%{_datadir}/icons/hicolor/1024x1024/apps/broom.png` |
| 系统助手 | `%{_libexecdir}/broom/broom-system-helper` |
| Polkit policy | `%{_datadir}/polkit-1/actions/com.broom.Broom.policy` |
| 文档 | `%{_docdir}/broom/`（README、本设计文档） |

说明：

- 助手和 policy 必须由 RPM 以 root 所有权安装，不能由应用自行写入。
- 入口符号链接是否影响 Flutter 查找 `data/` / `lib/` 必须在 VM 中验证；如果 `/proc/self/exe` 解析不符合预期，改为安装一个极小的 shell wrapper 或直接 `Exec=%{_libdir}/broom/broom`。
- 图标当前为 1024×1024 PNG；如桌面环境需要其他尺寸，后续再生成多尺寸，不在本阶段阻塞。

### 9.3 Spec 草案

```spec
Name:           broom
Version:        %{broom_version}
Release:        1%{?dist}
Summary:        Safe, reversible cache cleaner for Linux desktops

License:        Proprietary
URL:            https://example.invalid/broom
Source0:        broom-bundle-%{version}.tar.gz
BuildArch:      x86_64

Requires:       polkit
Requires:       systemd
Requires:       gtk3
Requires:       glib2

%description
Broom scans declared cache locations, previews results, and moves files to a
quarantine so a clean can be undone. The optional system helper cleans DNF
package caches and the systemd journal after Polkit authorization.

%prep
%setup -q -n broom-bundle-%{version}

%install
mkdir -p %{buildroot}%{_libdir}/broom
cp -a bundle/. %{buildroot}%{_libdir}/broom/
install -Dm0755 helper/broom-system-helper %{buildroot}%{_libexecdir}/broom/broom-system-helper
install -Dm0644 packaging/broom.desktop %{buildroot}%{_datadir}/applications/broom.desktop
install -Dm0644 packaging/broom.png %{buildroot}%{_datadir}/icons/hicolor/1024x1024/apps/broom.png
install -Dm0644 packaging/com.broom.Broom.policy %{buildroot}%{_datadir}/polkit-1/actions/com.broom.Broom.policy
mkdir -p %{buildroot}%{_bindir}
ln -sf %{_libdir}/broom/broom %{buildroot}%{_bindir}/broom

%files
%{_bindir}/broom
%{_libdir}/broom/
%{_datadir}/applications/broom.desktop
%{_datadir}/icons/hicolor/1024x1024/apps/broom.png
%{_libexecdir}/broom/broom-system-helper
%{_datadir}/polkit-1/actions/com.broom.Broom.policy
%doc README.md docs/linux-system-cache.md

%changelog
* Thu Oct 23 2026 Broom maintainers <maintainers@example.invalid> - 0.4.0-1
- Initial Linux system helper packaging
```

占位项：

- `License` 必须以项目实际许可证替换；当前仓库没有 LICENSE 文件，发布前必须确认。
- `URL`、维护者邮箱与 changelog 身份为占位，正式出包前替换。
- `Source0` 的具体打包形式由脚本决定；本阶段是预构建 binary RPM，不是 Fedora 官方仓库要求的 from-source 包。
- `Version` 从 `pubspec.yaml` 读取后通过 `--define "broom_version ..."` 传给 rpmbuild。

### 9.4 构建脚本

建议新增 `tool/package_rpm.sh`：

1. 读取 `pubspec.yaml` 版本；
2. `flutter build linux --release`，得到 `build/linux/x64/release/bundle`；
3. `cmake -S linux/system_helper -B build/system-helper -DCMAKE_BUILD_TYPE=Release` 并构建助手；
4. 生成 policy（展开 `%{_libexecdir}`）；
5. 把 bundle、助手、desktop、图标、policy、文档打包到 rpmbuild 的 `SOURCES`；
6. `rpmbuild -bb packaging/rpm/broom.spec --define "_topdir ..." --define "broom_version ..."`；
7. 输出 `dist/broom-<version>-1.<dist>.x86_64.rpm` 与 `.sha256`。

约束：

- 使用普通用户运行 `rpmbuild`，不要用 root 构建；
- RPM 构建需要 Linux 环境（Fedora，或安装了 `rpm-build` 的 Ubuntu）；当前 Windows 工作区不执行 RPM 构建；
- 构建机需要 `rpm-build`、`cmake`、C++ 工具链和 Flutter；
- 构建脚本只打包，不安装、不执行助手、不运行 `dnf` / `journalctl`；
- RPM 不签名，作为本地测试包；正式分发前再接入签名；
- 现有 Ubuntu CI 是否增加 RPM 构建作为可选任务，留到打包脚本稳定后决定；本阶段的 RPM 由本地生成，VM 验证由维护者完成。

### 9.5 依赖与安装行为

- `Requires: polkit` 提供 `pkexec` 和 policy 基础设施；Fedora 上的确切包名以 `dnf provides /usr/bin/pkexec` 核对。
- `systemd` 提供 `journalctl`；没有 systemd 的系统隐藏 journal 操作。
- DNF 不建议作为强依赖：助手在运行时探测 `/usr/bin/dnf`，不存在时 `--list` 标记为不可用。若目标只面向 Fedora，可改为 `Requires: dnf`。
- GTK/GLib 运行时依赖应同时依赖 RPM 自动 ELF 依赖和显式 `Requires`；出包后用 `rpm -qpR` 核对。
- 安装后不需要启用 systemd 服务、不需要 D-Bus 重新加载、不需要 `polkitd` 重启；policy 放入标准目录即可被识别。
- 卸载 RPM 删除助手、policy 和桌面入口；`$XDG_DATA_HOME/Broom` 中的配置、隔离区与历史继续保留，遵循现有数据保留策略。
- 卸载不会恢复已被永久清理的 DNF 缓存或 journal；这一点在卸载文档与 UI 中都要说明。

## 10. 验证计划

### 10.1 仓库内自动化

阶段 1 已覆盖：

- C++ CTest：参数解析、操作白名单、未知操作、非 root 拒绝、JSON 结构与转义、自检的 root 所有权 / 权限规则。断言 `--run` 在阶段 1 不会启动任何系统工具。
- Dart 测试：可用性探测不启动进程、`--list` / `--self-test` 直接调用助手、pkexec 参数只含固定 operation id、认证取消与失败映射、部分失败与异常 JSON 的拒绝。
- policy：Linux CI 用 `xmllint` 校验 CMake 生成的 policy。

后续阶段待补：

- 超时、输出截断、忙锁与真实执行路径的单元测试。
- 建立 argv 的路径 / 命令拼接测试（阶段 2 引入执行代码后）。
- Dart UI fake 测试：入口隐藏、认证取消无副作用、部分失败、确认文案、tar.gz 构建不显示入口。
- RPM 构建冒烟：`rpm -qpl`、`rpm -qpR`、`rpm -V`。

CI 不运行真实 `pkexec` / DNF / journald；这些留给 VM。

### 10.2 VM 手工验证（维护者执行）

建议使用 Fedora Workstation（DNF5）或等效 RHEL 系虚拟机。

阶段 1 尚无 RPM，也不执行真实清理：可先运行

```bash
cmake -S linux/system_helper -B build/system-helper \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/system-helper
sudo cmake --install build/system-helper
```

再执行下面第 3、4、6 步。阶段 1 的 `--run` 在认证成功后返回 `not_implemented`（退出码 69），不会运行 DNF 或 journalctl；第 5、7、8 步留到阶段 2。

1. `dnf install ./broom-<version>-1.<dist>.x86_64.rpm`。本地测试包不签名；若 VM 的仓库策略阻止未签名包，仅在隔离 VM 中使用 `rpm -i`，不要把这个流程带到正式分发。
2. `rpm -qpl broom` 与 `rpm -qpR broom` 检查文件列表和依赖。
3. `stat` 检查助手、policy 为 root 所有、不可被普通用户写。
4. `pkaction --action-id com.broom.Broom.clean-system-cache --verbose` 应能看到 action。
5. 启动应用，确认系统缓存入口出现；普通用户触发 DNF 与 journal 清理。
6. 分别测试：取消认证、错误密码、成功、无 Polkit agent、非活跃会话（如 SSH）。
7. 成功清理 DNF 后确认只删除了包缓存，未卸载软件，仓库元数据策略符合预期。
8. 清理 journal 前后比较 `journalctl --disk-usage`，确认 7 天内/当前日志仍在。
9. 在 SELinux enforcing 下检查 `ausearch -m avc` / `journalctl -t audit`，记录是否有 AVC；如有，先修复或补策略，不带着拒绝上线。
10. 检查应用 bundle 通过 `/usr/bin/broom` 符号链接启动时，`data/`、`lib/` 与图标正常。
11. 卸载 RPM，确认助手、policy 和桌面入口被移除，用户配置/隔离区保留。
12. 用 tar.gz 版本确认系统缓存入口隐藏；用缺少 `pkexec` 或缺少 policy 的环境确认降级行为。

VM 验证中发现的问题应回写到本文件“已知风险 / 开放问题”一节，再进入下一步。

## 11. 分阶段实施与验收

### 阶段 1：助手骨架与授权链路（已实现，VM 验证待执行）

- [x] 新增 `linux/system_helper/` 的 C++ 助手骨架、CMake 构建与 CTest。
- [x] 新增 policy 模板、CMake 展开与 `/usr/libexec` / `/usr/share` 安装约定；CI 校验 XML。
- [x] 新增 Dart `LinuxSystemMaintenance` 抽象、pkexec 客户端、严格 JSON 校验与 fake。
- [x] 助手只支持 `--list` / `--self-test` / 参数校验，不执行真实清理；`--run` 返回 `not_implemented`。
- [x] 仓库内验收：CTest、Dart 单元测试、`flutter analyze` 全部通过。
- [ ] VM 验收：按第 10.2 节确认 policy 被识别，`pkexec` 能弹出认证框；阶段 1 不验证实际清理。

### 阶段 2：DNF 与 journal 操作 + UI

- 实现 `dnf-packages`、`journal-7d`；
- 新增 Linux 系统缓存页、控制器、侧边栏能力位；
- 实现确认、认证取消、部分失败、忙锁、超时；
- 验收：fake 测试覆盖全部状态；真实操作在 VM 中按第 10.2 节验证。

### 阶段 3：RPM 打包（只出包）

- 新增 `packaging/rpm/broom.spec`、`tool/package_rpm.sh`；
- 生成助手、policy、desktop、图标、bundle 的 RPM；
- 输出 `.rpm` 与 `.sha256`；
- 不在脚本中安装或运行 RPM；不实现 deb/Flatpak/Snap/AppImage；
- 验收：本地可重复构建 RPM；`rpm -qpl` / `rpm -qpR` / `rpm -V` 冒烟通过；维护者在 VM 中完成安装与授权测试。

### 后续（不在本次范围）

- Debian/Ubuntu `deb` 与 APT 操作；
- Flatpak / Snap / AppImage 分发与沙箱内宿主助手方案；
- zypper / pacman 操作；
- D-Bus system helper、进度信号、长任务；
- RPM 签名、软件源、自动更新。

## 12. 已知风险与开放问题

1. **许可证**：仓库没有 LICENSE，RPM `License` 字段暂为占位，正式发布前必须确认。
2. **SELinux**：`pkexec` 启动自定义助手后的 domain 与写入 `/var/cache/dnf`、`/var/log/journal` 的权限需要 Fedora VM 实测；若有 AVC，可能需要 SELinux policy 或改用 systemd service。
3. **DNF5 兼容性**：`dnf clean packages` 在不同版本上的行为和输出可能不同；以退出码为准，不解析本地化文本。
4. **Polkit agent**：没有 authentication agent 的桌面/远程会话无法完成授权；系统缓存入口应优雅降级。
5. **符号链接启动**：Flutter 通过 `/proc/self/exe` 定位 bundle；`/usr/bin/broom` 符号链接需在 VM 中验证，必要时改用 wrapper。
6. **授权面**：`pkexec` 本身是 setuid 组件，历史上出现过漏洞；助手必须保持最小、无可配置路径、无 shell，并跟随发行版的 polkit 更新。
7. **不可撤销**：DNF 缓存和 journal 都是永久删除，不进入隔离区；UI 必须明确说明。
8. **未来 D-Bus 迁移**：如果 Flatpak 或长任务成为近期目标，尽早切换到 D-Bus helper，避免两套授权入口长期并存。
9. **RPM 来源构建**：本阶段是预构建 binary RPM，不适合直接提交 Fedora 官方仓库；若要走官方源，需要补 from-source 构建、许可证与打包规范。
10. **阶段 1 的 VM 验证尚未完成**：仓库内自动化只能证明参数、JSON 与安装约定；popup、安装后权限和 Polkit 识别仍需在 Fedora VM 中按第 10.2 节确认。完成前不宣称授权链路已验证。

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
| Linux 系统维护契约与 pkexec 客户端 | [lib/core/platform/linux_system_maintenance.dart](../lib/core/platform/linux_system_maintenance.dart) |
| Linux 系统维护测试 fake | [test/support/linux_system_maintenance_fakes.dart](../test/support/linux_system_maintenance_fakes.dart) |
| Linux 用户规则 | [lib/core/rules/linux_rules.dart](../lib/core/rules/linux_rules.dart) |
| Linux 规则与 Windows 差距 | [linux-windows-parity.md](linux-windows-parity.md) |
| Linux 打包现状 | [tool/package_linux.sh](../tool/package_linux.sh) |
| Linux CI | [.github/workflows/linux.yml](../.github/workflows/linux.yml) |

## 14. 外部参考

- pkexec / Polkit 授权与 `exec.path` 注解：[pkexec manual](https://www.freedesktop.org/software/polkit/docs/latest/pkexec.1.html)
- Polkit 与 privileged D-Bus service 模型：[Polkit - Gentoo Wiki](https://wiki.gentoo.org/wiki/Polkit)
- Polkit 系统守护进程与 setuid 风险说明：[polkitd package description](https://packages.debian.org/trixie/amd64/polkitd)
- PackageKit 的 Polkit/D-Bus 抽象（后续评估）：[PackageKit introduction](https://www.freedesktop.org/software/PackageKit/pk-intro.html)
