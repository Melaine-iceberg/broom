# 打包与分发

本文说明如何把 Broom 打成可分发的 Windows 产物：签名 MSIX 安装包、便携 ZIP，以及安装 / 升级 / 卸载的完整路径。打包流程建立在微软的 Windows App CLI（`winapp`）之上，清单、磁贴资源与打包脚本都在仓库内，可重复执行。

Linux 的 tar.gz、deb、AppImage 与 RPM 打包、签名和更新清单是独立流程，见 [README 的 Linux 构建与打包](../README.md#linux-构建与打包) 与 [linux-system-cache.md](linux-system-cache.md#9-第三阶段rpm-与-deb-打包已实现)。

## 产物

| 文件 | 用途 | 说明 |
| --- | --- | --- |
| `broom_<版本>_x64.msix` | 安装包 | 含开始菜单入口、卸载入口与升级路径 |
| `broom.appinstaller` | 自动更新源 | 传 `-UpdateFeedUrl` 时生成；用户通过它安装后，系统按其中的 `UpdateSettings` 自动更新 |
| `Broom.cer` | 公钥证书 | 供用户信任签名用。**私钥 `signing/broom-release.pfx` 永不分发** |
| `broom_<版本>_win-x64-portable.zip` | 便携版 | 解压即用，不写入注册表、不需安装 |
| `SHA256SUMS.txt` | 校验和 | 上述文件的 SHA-256 |

版本号由 `pubspec.yaml` 推导：`version: 0.5.1+6` → MSIX `0.5.1.6`。MSIX 要求四段版本且只能递增，因此把语义化版本的 build 号映射为第四段（revision）是自然选择，发布时只需改 `pubspec.yaml`。

## 前置条件

- Flutter 3.47.7 / Dart 3.13.5，以及 Visual Studio 的「使用 C++ 的桌面开发」工作负载（`flutter build windows` 的常规要求）。
- Windows App CLI 0.7.1 或更高：

```powershell
winget install --id Microsoft.WinAppCli
winapp --version
```

`winapp package` 首次运行会自动下载 `Microsoft.Windows.SDK.BuildTools`（使用 `makeappx` / `signtool`），不需要单独安装 Windows SDK。

## 一键打包

```powershell
pwsh -File tool/package_windows.ps1
```

脚本依次执行：`flutter build windows --release` → 把 Release 产物与 `windows/packaging/` 下的清单、磁贴资源暂存到 `build/windows/msix/stage` → 按 `pubspec.yaml` 重写暂存清单的版本号 → `winapp package` 签名出包 → 生成便携 ZIP → 写入校验和。产物输出到 `dist/`（已在 `.gitignore` 中忽略）。

常用参数：

| 参数 | 作用 |
| --- | --- |
| `-SkipBuild` | 复用已有 Release 产物，只重新打包 |
| `-UpdateFeedUrl https://.../broom.appinstaller` | 生成自动更新源 `broom.appinstaller`，必须 https；省略则不生成 |
| `-Version x.y.z.b` | 覆盖版本号（默认由 `pubspec.yaml` 推导），用于 CI 或发布候选验证 |
| `-Publisher "CN=..."` | 仅在**首次**生成签名证书时生效，须与清单 `Identity/@Publisher` 一致 |
| `-CertificatePath` / `-CertificatePassword` | 改用指定证书签名（商业证书）；默认复用 `signing/broom-release.pfx` |
| `-SkipMsix` / `-SkipPortable` | 只产出其中一种 |

只想重新生成磁贴图标时：

```powershell
winapp manifest update-assets assets/icon/app_icon.png --manifest windows/packaging/Package.appxmanifest
```

## 包标识

清单位于 `windows/packaging/Package.appxmanifest`：

| 字段 | 值 |
| --- | --- |
| `Identity/@Name` | `Broom` |
| `Identity/@Publisher` | `CN=Broom` |
| `Identity/@Version` | 由 `pubspec.yaml` 覆盖，源文件中的值仅为占位 |
| `Application/@Executable` | `broom.exe` |
| 入口 | `Windows.FullTrustApplication`（完整信任的 Win32 桌面应用） |
| 能力 | `runFullTrust`、`allowElevation` |

`Name` 与 `Publisher` 共同构成包标识：两者任一变更，Windows 都会视为另一个应用，新包不会覆盖升级旧包，而是并存安装。发布后如需更换签名证书，必须保留相同的 `CN`。

## 签名

三条路径，按分发范围选择：

1. **自签名（当前默认）**：首次打包时脚本用 `winapp cert generate` 生成 `signing/broom-release.pfx`（有效期 10 年），之后每次发布都复用它。适合内部与自测。使用者必须先把公钥证书加入机器级受信任存储（见下节），否则安装会以 `0x800B0109`（证书链不受信任）失败。
2. **商业代码签名证书**：`-CertificatePath .\signing\prod.pfx -CertificatePassword <密码>`。用户无需手动信任证书，也不触发 SmartScreen「未知发布者」。生产构建建议在 `winapp sign --timestamp` 上加时间戳，使证书到期后已发布的包仍然有效。
3. **Microsoft Store**：提交未签名包（`winapp package --no-sign`），由 Store 重新签名。注意 Store 基本不会批准 `allowElevation` 这类受限能力，因此需要管理员权限的系统缓存工具在 Store 版本中可能无法使用。

**签名身份必须跨版本固定，这是自动更新的前提。** 早期脚本每次都用 `--generate-cert` 新建证书，那会导致每个版本都由不同证书签名：用户每升一次就要重新信任一次，App Installer 也会因签名与已安装包的信任链不一致而拒绝升级。现在证书只在 `signing/broom-release.pfx` 不存在时生成一次，请把该文件与密码一起备份；丢失后无法以相同身份继续发布，只能要求所有用户重新信任新证书。

私钥不进入版本库：`.gitignore` 忽略 `signing/`；`dist/` 内只放导出的公钥 `Broom.cer`。

## 发版流程：CI 发布与本地签名

推送 `vX.Y.Z` 标签会触发 [`.github/workflows/release.yml`](../.github/workflows/release.yml)：

1. 复用 `linux.yml` / `windows.yml` 执行格式校验、严格静态检查与完整测试；
2. 构建 Linux 的 tar.gz / deb / AppImage / RPM，汇总 `SHA256SUMS` 与 `broom-linux.json`；
3. 构建 Windows 便携 ZIP；
4. 校验标签与 `pubspec.yaml` 前三段版本一致后，创建或更新该标签的 GitHub Release，并上传上述产物。

标签必须与 `pubspec.yaml` 前三段一致，否则第 4 步会直接失败；因此顺序始终是**先提交并推送 `version` 的 bump，再打标签**。

MSIX **不在 CI 构建**：签名私钥 `signing/broom-release.pfx` 被 `.gitignore` 排除，只保存在发布机器上，CI 无法以固定身份签名。因此需要在发布机器上完成签名，再把 MSIX 附加到同一个 Release：

```powershell
# 1. 检出与标签一致的提交（v0.5.1 ↔ pubspec 0.5.1+6）
git fetch --tags
git checkout v0.5.1

# 2. 本地签名：0.5.1+6 → MSIX 0.5.1.6。便携 ZIP 已由 CI 发布，这里跳过
pwsh -File tool/package_windows.ps1 -SkipPortable

# 3. 附加到 Release
gh release upload v0.5.1 `
  dist/broom_0.5.1.6_x64.msix `
  dist/Broom.cer
```

- 需要自动更新源时，在打包命令加 `-UpdateFeedUrl https://<你的域名>/broom/broom.appinstaller`，并额外上传 `dist/broom.appinstaller`；**先传 MSIX、后传 `.appinstaller`**，避免清单指向尚不存在的包。
- 不要把本地的 `SHA256SUMS.txt` 上传到 Release：CI 那份是便携 ZIP 的校验和，本地这份只覆盖签名产物，同名会互相覆盖。MSIX 的完整性由包签名保证；如需校验和，用 `Get-FileHash dist\broom_0.5.1.6_x64.msix -Algorithm SHA256` 单独记录。
- 发布后用 `gh release view vX.Y.Z` 确认资产齐全，并按「安装」一节实际安装一次签名包。

## 安装

MSIX 的签名由部署服务（以 SYSTEM 身份运行）校验，因此**信任证书与安装包注册都需要管理员权限**，即使用户级安装本身不需要。

在管理员 PowerShell 中：

```powershell
# 推荐：通过 App Installer 源安装，这样系统会记住更新源并自动升级
.\tool\install_msix.ps1 -AppInstaller .\dist\broom.appinstaller -Certificate .\dist\Broom.cer

# 或者只装单个包（之后不会自动更新）
.\tool\install_msix.ps1 -Package .\dist\broom_0.4.0.4_x64.msix -Certificate .\dist\Broom.cer
```

等价的手工步骤：

```powershell
certutil -f -addstore Root .\dist\Broom.cer
certutil -f -addstore TrustedPeople .\dist\Broom.cer
Add-AppxPackage -Appinstaller .\dist\broom.appinstaller
```

安装后从开始菜单启动 Broom。证书只需信任一次，之后同一证书签名的升级包可以直接安装。

## 升级

同 `Identity`（`Name` + `Publisher`）、版本号更高的包即完成就地升级，用户数据保留：

```powershell
Add-AppxPackage -Path .\dist\broom_0.5.1.6_x64.msix
```

版本号更低会被拒绝。若要同时保留旧版本并排安装，需要改为不同的 `Identity/@Name`。

手工升级只是兜底手段；正常路径见下节的自动更新。

## 自动更新

### 方案对比

| 方案 | 需要应用代码 | 前提 | 评价 |
| --- | --- | --- | --- |
| App Installer（`.appinstaller`） | 不需要 | 用户通过 `.appinstaller` 安装；HTTPS 托管 | 当前选择。系统托管检查、下载、安装与回滚，零自我更新逻辑 |
| 应用内检查 + 提示 | 需要 | 读取更新源版本号，加一个「有新版本」入口 | 可选增强，用于让用户知情 |
| 包内 `PackageManager` 自更新 | 需要 | 需声明 `packageManagement` 受限能力 | 与 Store 提交冲突，且要在应用内自己处理下载与安装，不推荐 |

### 工作原理

`.appinstaller` 是一个 XML 清单，声明包的身份、版本、下载地址与更新策略。用户**打开这个文件**安装后，Windows 会在 App Installer 仓库里登记一条记录（含更新源 URI 与策略）；此后由系统按策略检查同一 URI，发现更高版本就后台下载并替换，不需要应用参与。

关键限制：**只有通过 `.appinstaller` 安装的应用才会自动更新**。用 `Add-AppxPackage` 直接装 `.msix` 的机器不在仓库里，不会收到自动更新——这也是安装脚本把 `.appinstaller` 作为推荐入口的原因。

### 当前策略

脚本生成的清单（2021 schema）内容为：

```xml
<UpdateSettings>
  <OnLaunch HoursBetweenUpdateChecks="0" ShowPrompt="false" UpdateBlocksActivation="false" />
  <AutomaticBackgroundTask />
</UpdateSettings>
```

含义：

- `HoursBetweenUpdateChecks="0"`：每次启动都检查，但仍在后台下载安装，不阻塞启动。
- `ShowPrompt="false"` / `UpdateBlocksActivation="false"`：不弹更新窗口，不强制先更新才能用。对 Broom 这类工具来说，清理中途被强制升级会打断隔离区操作。
- `AutomaticBackgroundTask`：应用没运行时也约每 8 小时检查一次。
- 未启用 `ForceUpdateFromAnyVersion`，因此**只升不降**；要回滚得手动卸载重装，或另发一版并临时打开该开关。

该 schema 与上述属性要求 Windows 10 2004（19041）及以上；`.appinstaller` 文件自身必须是 UTF-8 且不带 BOM，否则 App Installer 会以 `0xC00CEE2D`（XML 不合法）拒绝——脚本已按无 BOM 写出。

### 发布流程

1. 修改 `pubspec.yaml` 的 `version`（如 `0.5.1+6`）。
2. 打包时给出更新源地址：

```powershell
pwsh -File tool/package_windows.ps1 -UpdateFeedUrl https://<你的域名>/broom/broom.appinstaller
```

3. 把 `dist/broom.appinstaller` 与 `dist/broom_0.5.1.6_x64.msix` 上传到同一目录，文件名必须与清单里的一致：

```
https://<你的域名>/broom/broom.appinstaller
https://<你的域名>/broom/broom_0.5.1.6_x64.msix
```

4. 旧版本的 `.msix` 建议保留一段时间，正在下载旧包的客户端仍可能请求它。

注意事项：

- **必须 HTTPS**：脚本会校验 `-UpdateFeedUrl`，非 https 直接报错退出。
- **先传包、后传清单**：避免用户拿到指向尚不存在包的清单。
- **不要改标识与签名证书**：`Name`、`Publisher` 和签名证书必须跨版本一致，否则不是「升级」而是「另一个应用」。
- **`ms-appinstaller:` 协议已失效**：微软自 2023 年 12 月起默认禁用该协议（曾被恶意软件滥用），所以不能做网页一键安装，只能让用户下载 `.appinstaller` 后打开。企业可通过组策略重新启用，不应把它当作分发前提。

### 当前发布状态

- **Linux 与便携版已随 tag 自动发布**：`release.yml` 会把 Linux 的四种包、`SHA256SUMS`、`broom-linux.json` 与 Windows 便携 ZIP 附加到对应 GitHub Release。
- **MSIX 不随 Release 自动发布**：签名私钥只在发布机器上，需按「发版流程」手工签名并附加。当前签名仍是自签名 `CN=Broom`，一旦对外分发，每个下载者都要手动把 `Broom.cer` 装进受信任根，并持续面对 SmartScreen「未知发布者」——对一款删文件的工具，这是在训练用户无脑信任证书。**首次公开发布 MSIX 前应换成商业代码签名证书**（`-CertificatePath`），并同步更新清单的 `Identity/@Publisher`。此时换证书的代价只是重装一次；一旦有外部用户，换证书就等于换发布身份，已有安装无法升级。
- **Pages 尚未启用**：`https://melaine-iceberg.github.io/broom/` 目前返回 404，应用内默认更新源仍不可达；Release 中的 `broom-linux.json` 可手动下载，或通过 `--dart-define=BROOM_LINUX_UPDATE_FEED=...` 指向其他 HTTPS 源。清单里的 `.appinstaller` `Uri` 同样指向 Pages，未上线时应用内「检查更新」会以网络错误结束，不影响任何本地功能。
- **GitHub Release 直接作为 App Installer 更新源尚未验证**：`.appinstaller`、`.msix` 与清单里的包地址必须位于同一稳定 HTTPS 目录；正式启用自动更新前仍建议独立托管，并先传包、后传清单。

拿到商业证书后的动作：

1. 改 `windows/packaging/Package.appxmanifest` 的 `Identity/@Publisher` 为证书实际 DN。
2. `pwsh -File tool/package_windows.ps1 -CertificatePath .\signing\prod.pfx -CertificatePassword <密码> -UpdateFeedUrl https://<域名>/broom/broom.appinstaller`
3. 先上传 MSIX，再上传 `.appinstaller`；启用 Pages 或把应用内默认更新源替换为该目录。

### 用户侧操作

1. 首次安装：管理员 PowerShell 信任 `Broom.cer`，然后双击 `broom.appinstaller`。之后不再需要任何手动操作。
2. 关闭自动更新：设置 → 应用 → 已安装的应用 → Broom → 高级选项 → 关闭「应用更新」。
3. 查看当前策略：`Get-AppxPackageAutoUpdateSettings -PackageFullName <PackageFullName>`。

### 应用内「检查更新」

设置页的「软件更新」区块会显示当前版本、更新源地址与一个「检查更新」按钮。它的做法比规则更新简单：通过 HTTPS 取回更新源里的 `.appinstaller`，读取根节点的 `Version`，与本机版本做四段数字比较（`0.4.0.10` 大于 `0.4.0.9`，不是字符串比较）。

当前版本来自编译期写入的 `FLUTTER_VERSION`（`windows/runner/CMakeLists.txt` 注入，经 `broom/system` 通道的 `appVersion` 方法读取），因此与 MSIX 身份一致，且便携版同样可用——不需要查询包图，那条路只在已安装 MSIX 时有效。

这里**不需要再引入一套签名清单**：该 XML 只用于提示用户，真正的安装与完整性校验由 Windows 用 MSIX 签名完成，伪造清单无法让系统装上一个未签名的包。相比之下，规则目录更新之所以要 HMAC 校验，是因为规则直接影响「删什么文件」，而 MSIX 的签名已经覆盖了应用本身。

实现细节：

- 更新源地址默认为 `https://melaine-iceberg.github.io/broom/broom.appinstaller`，可用 `--dart-define=BROOM_UPDATE_FEED_URL=...` 覆盖（见 `AppUpdateService.compiledFeedUrl`）。
- 只接受 HTTPS，不跟随重定向，响应上限 64 KiB，连接与读取各有超时；含 `<!DOCTYPE>` / `<!ENTITY>` 的文档直接拒绝。
- 检查失败只影响提示，不影响任何清理功能；应用从不下载或执行安装程序。

## 卸载

```powershell
Get-AppxPackage -Name Broom | Remove-AppxPackage
```

**卸载不会清理用户数据。** Broom 的隔离区、配置、扫描结果与清理历史都写在 `%LOCALAPPDATA%\Broom`，这是真实目录，不受 MSIX 容器管理，卸载后仍然存在——这正是「清理后可撤销」所依赖的语义。因此卸载前应先打开隔离区，把需要保留的文件恢复，或确认后永久释放，否则这些文件会继续占用磁盘。

如需一并移除证书信任：

```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq 'CN=Broom' } | Remove-Item
Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object { $_.Subject -eq 'CN=Broom' } | Remove-Item
```

## 便携版

`broom_<版本>_win-x64-portable.zip` 解压后直接运行 `broom.exe`，不注册包标识、不创建开始菜单项。隔离区与配置同样位于 `%LOCALAPPDATA%\Broom`，与安装版共用——两个版本交替运行时看到的是同一份数据，不要同时运行。

便携版适合无法信任证书或不允许安装 MSIX 的环境。缺点是没有任何自动更新与卸载入口，删除目录即视为卸载（同样不清理用户数据）。

## 权限模型

Broom 的普通扫描与清理以当前用户权限运行；只有独立的「系统级缓存」工具（Windows Update 缓存、传递优化缓存、Windows.old）需要管理员权限，通过 `ShellExecuteExW` 加 `runas` 重新启动自身并传入 `--system-cache`。

打包应用默认不允许自我提权，因此清单声明了 `rescap:allowElevation`：该受限能力允许包内进程使用 `runas` 动词动态提权。侧载（sideload）分发无需审批即可使用该能力，这是它能出现在本包中的原因。副作用是提权后的进程不再持有包标识，对 Broom 没有影响——它只使用 Win32 API 与 `%LOCALAPPDATA%`，不依赖包 API。

## 已验证与待验证

在本机（Windows 11 26340，Flutter 3.47.7，winapp 0.7.1）已确认：

- `flutter build windows --release` 通过，产物 57 MB。
- `winapp package` 成功产出 31.6 MB 签名 MSIX 与 30.5 MB 便携 ZIP（便携版内 `broom.exe` 位于根目录，`data/` 完整）。
- 解包后包内清单正确：`Identity = Broom / CN=Broom / 0.4.0.4`、`Executable = broom.exe`、能力含 `runFullTrust` 与 `allowElevation`。
- **MSIX 安装成功**：`Add-AppxPackage` 后 `Get-AppxPackage` 返回 `Version 0.4.0.4`、`Status Ok`，安装位置 `C:\Program Files\WindowsApps\Broom_0.4.0.4_x64__mba8f2qv6fhee`。
- **打包形态可正常运行**：通过应用模型（`shell:AppsFolder\Broom_mba8f2qv6fhee!Broom`）启动，进程路径为 `WindowsApps` 下的 `broom.exe`，窗口标题 `Broom`、响应正常，界面完整渲染（深色主题、首页、工具卡片均正常）。
- 暂存目录中的 `broom.exe` 可直接启动，说明打包不会引入对安装位置的依赖。
- **更新源清单可被系统解析**：`Add-AppxPackage -Appinstaller` 处理生成的 `.appinstaller` 时能正确读取身份与包地址（先请求清单、再请求 `.msix`），失败点落在下载阶段而非 XML 解析，说明 2021 schema 与 `UpdateSettings` 结构有效。
- **应用内检查更新可用**：设置页「软件更新」能显示当前版本（取自原生 `appVersion`）与更新源，点击后按四段版本比较给出「已是最新」或「发现新版本」。`flutter analyze --fatal-infos` 无告警，`flutter test` 517 项全部通过，其中 `test/app_update_service_test.dart` 覆盖解析、比较、HTTP 拒绝与实体声明拒绝，`test/settings_page_test.dart` 覆盖区块渲染与检查流程。
- **签名证书已固定并延长有效期**：`signing/broom-release.pfx` 为 `CN=Broom`、有效期至 2036-10-18（指纹 `6E6A67635BBA9F892CECA62917EF729031E5528F`）；重复打包复用同一张证书，`Broom.cer` 由私钥导出。此前 1 年期证书（无时间戳）会在 2027 年到期后让所有新包的签名校验失败，因此趁尚无外部用户时一次性换成了 10 年期证书，并已在本机完成卸载旧包 → 清除旧根证书 → 信任新证书 → 重装，`Status` 仍为 `Ok`。

尚未闭环的部分：

- **完整的自动更新链路**：需要把 `.appinstaller` 与 `.msix` 放到 HTTPS 站点，再用该清单安装一次，才能验证系统登记更新源、按 `OnLaunch` 检查、下载并替换的完整过程。本地用 `python -m http.server` 尝试过：清单能被拉取，但该服务器不支持 Range 请求，App Installer 下载 `.msix` 时连接被重置（`0x80D05011`），属于测试环境限制而非清单问题。另外 `.appinstaller` 的 `Uri` 不接受 `file://`，本地文件方式无法替代真实托管。
- **打包形态下的自我提权**：清单已声明 `allowElevation`，这是侧载 MSIX 允许 `runas` 动态提权的前提；但点按「以管理员身份重新启动」后的 UAC 往返必须由人在场确认，自动化环境无法代替。验证方法：打开「系统级缓存」→ 点击提权按钮 → 确认 UAC 后应出现一个只打开该页面的新窗口。若被拒，应用会按既有逻辑映射为「未提权」而不是报错。
- **未签名 / 商业证书签名**：仅验证了自签名路径。
- **无管理员账户安装**：本机执行安装的用户属于管理员组，标准用户安装 MSIX 未测试。

## 尚未实现

- 正式更新源未上线（见「当前发布状态」）：Linux 清单已随 Release 发布，但 Pages 未启用、应用内默认源不可达；Windows `.appinstaller` 仍依赖外部 HTTPS 目录。上线时用独立的 `gh-pages` 分支并每次单提交覆盖，否则每版 30 MB 的二进制会迅速撑大仓库历史；同时需在仓库设置中启用 Pages。
- MSIX 发布会话的自动化：Linux 包与便携 ZIP 已随 tag 自动发布，但签名 MSIX 的上传、`.appinstaller` 替换顺序与旧包保留仍靠手工执行。
- winget 清单提交、官网下载页与发布渠道自动化。
- ARM64 与 x86 包：Flutter Windows 默认只构建 x64，`winapp package` 需要对应的产物目录。
- SmartScreen 声誉：自签名包仍会提示「未知发布者」，只有受信任的商业证书配合时间戳与下载量积累才会消除。
- Microsoft Store 提交材料（截图、隐私策略、`allowElevation` 的替代方案）。
