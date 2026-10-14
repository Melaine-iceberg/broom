# broom

![CI](https://github.com/Melaine-iceberg/broom/actions/workflows/ci.yml/badge.svg)

Windows 磁盘清理工具:把「什么是垃圾」写成纯数据规则,先扫描预览、再按需清理。基于 .NET 10 + [Avalonia](https://avaloniaui.net/) 构建,支持深浅色双主题。

![主窗口](docs/images/main-window.png)

## 功能特性

- **声明式清理规则**:37 条内置规则覆盖系统垃圾、浏览器、应用缓存、开发者缓存等类目;规则是纯数据([Rules/WindowsRuleSet.cs](Rules/WindowsRuleSet.cs)),路径模板支持 `%ENV%` 展开与目录名通配符
- **先看后删**:扫描只读,清理前可展开文件明细、按大小筛选、排除单个文件或整个目录;排除项持久化并自动去重校验
- **可控删除**:删除方式可选回收站 / 永久删除;可选「跳过最近 N 天内修改过的文件」;可选安全擦除(删除前用随机数据覆写)
- **可回退**:永久删除先进隔离区,可按会话还原;被占用文件可登记「重启后删除」;清理前可自动创建系统还原点
- **随时中止**:扫描 / 清理支持取消,取消时仍产出部分清理报告
- **管理员提权**:系统目录类规则标记「需要管理员权限」,可在应用内一键重启提权
- **规则管理**:自定义清理目录(含包含 / 排除模式)、搜索、风险筛选、排序,分组展示

## 构建与运行

要求:**Windows 10/11** 与 [.NET 10 SDK](https://dotnet.microsoft.com/download)。

```powershell
dotnet run                      # 开发运行(默认普通权限)
dotnet build -c Release         # 构建
dotnet test broom.slnx          # 全量单元测试
dotnet publish -c Release       # 发布(打包分发方案见 backlog 第 19 项)
```

默认以普通权限运行;清理系统目录(如 `C:\Windows\Temp`、Prefetch)需要管理员权限,清理失败时应用会提示一键重启提权。

## 清理规则总览

风险等级决定默认勾选与提示强度:**安全** = 可放心删除、默认勾选;**谨慎** = 删除后需重建 / 重新下载、默认不勾选;**高风险** = 删除后不可逆、默认不勾选(可在设置中隐藏整个高风险类目)。

| 类别 | 规则 | 风险 |
|---|---|---|
| 系统临时与日志 | 用户临时文件、系统临时文件、应用崩溃转储、系统内存转储、Windows 错误报告(用户 / 系统)、Windows 组件日志、系统升级残留与安装日志 | 安全(前 6 项默认勾选)/ 谨慎 |
| 系统缓存 | Internet 临时文件、缩略图与图标缓存、字体缓存(用户 / 系统)、Windows 更新下载缓存、预读取文件、传递优化文件 | 安全(字体缓存不默认勾选)/ 谨慎 |
| 使用痕迹 | 最近使用的文档与跳转列表 | 谨慎 |
| 浏览器缓存 | Chrome / Edge / Brave / Opera / Vivaldi / 360 / QQ 浏览器 / Firefox 的网页缓存 | 谨慎 |
| 浏览器隐私 | Cookie 与登录状态、历史与会话 | 高风险 |
| 应用缓存 | 微信、QQ、钉钉、Teams / Discord / Slack、Office / OneDrive、Spotify、商店应用(UWP) | 谨慎 |
| 开发者缓存 | NuGet、npm、pip、Yarn、pnpm、Gradle、Maven、Go、Cargo | 谨慎 |
| 自定义目录 | 设置页自行添加,含包含 / 排除模式 | 自选 |
| 回收站 | 清空回收站 | 谨慎 |
| 系统备份 | 旧系统备份与升级残留(Windows.old 等) | 高风险 |

### 安全说明

- **聊天类只清缓存子目录**:微信 / QQ 仅扫描 `FileStorage\Cache|Temp`,钉钉仅清表情 / 头像 / 聊天图片缓存;聊天记录数据库与图片 / 视频 / 文件原目录不在扫描范围内
- **浏览器隐私独立成组**:Cookie / 历史清理默认不勾选,描述中明确后果(登录状态丢失、历史不可恢复);已保存的密码永不触碰
- **高风险类目**默认不勾选:删除 `Windows.old` 后无法回滚系统;清空回收站、清除浏览器隐私均不可恢复
- **安全擦除有限性**:机械硬盘上可降低恢复可行性;SSD 与写时复制文件系统上效果有限
- 扫描是只读操作;实际删除只发生在点击「清理」之后

## 数据与配置位置

| 内容 | 位置 |
|---|---|
| 设置(自定义目录、排除规则、默认选项) | `%APPDATA%\broom\settings.json` |
| 隔离区(永久删除暂存、可还原) | `%LOCALAPPDATA%\broom\quarantine`,按清理会话分目录,按保留天数自动清理 |
| 重启后删除登记 | 由系统在下次启动时处理,无需人工干预 |

## 项目结构

```
Core/       规则与数据模型、路径模板展开、格式化
Rules/      Windows 内置规则集(纯数据)
Services/   扫描器、清理器、设置持久化
Platform/   Windows 能力:回收站、提权、隔离区、重删、还原点、安全擦除
ViewModels/ MVVM 视图模型(CommunityToolkit.Mvvm)
Styles/     主题变量与控件样式(深浅色双主题)
broom.Tests/ xUnit 单元测试
docs/       roadmap(已设计 / 已实现)与 backlog(未实现清单)
```

## 文档

- [docs/roadmap.md](docs/roadmap.md) —— 各功能的背景、方案、影响文件与验收标准(含实现记录)
- [docs/backlog.md](docs/backlog.md) —— 未完成功能清单与建议推进顺序

每项改动均配套单元测试,CI 在 `windows-latest` 上执行构建 + 全量测试([.github/workflows/ci.yml](.github/workflows/ci.yml))。
