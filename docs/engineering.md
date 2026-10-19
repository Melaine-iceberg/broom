# 工程、测试与诊断

本文记录 v4 之后的工程质量收口：测试层次、可注入文件系统、元数据防御、并发保护、性能基准、诊断日志、严格静态检查与 Windows CI。

## 测试层次

| 层次 | 位置 | 覆盖内容 |
| --- | --- | --- |
| 单元测试 | `test/*_test.dart` | 路径守卫、规则解析、扫描器、隔离区状态机、配置迁移、系统缓存、日志与内存文件系统 |
| Widget 测试 | `test/*_page_test.dart` | 首页、预览选择、Review 二次确认、清理进度、完成与撤销、隔离区冲突策略、设置、分析页 |
| 集成测试 | `integration_test/app_smoke_test.dart` | 真实 Windows 窗口：设置往返 → 初始化扫描 → 预览 |
| 帧率基准 | `integration_test/ui_frame_benchmark_test.dart` | 真实 Windows 窗口滚动 5,000 条预览，输出 build / raster / total p50 与 p95 |
| 性能基准 | `benchmark/scan_benchmark.dart` | 10 万 / 100 万文件扫描、RSS、isolate 往返传输 |

```bash
flutter analyze --fatal-infos
flutter test
flutter test integration_test/app_smoke_test.dart -d windows
flutter test integration_test/ui_frame_benchmark_test.dart -d windows
dart run benchmark/scan_benchmark.dart --million
```

控件测试通过注入的假平台、假隔离区服务与可控扫描服务运行，不访问真实缓存；涉及 `ExclusionStore` / `SettingsStore` 的用例使用临时目录。集成测试使用假平台，因此不会扫描或删除开发机上的真实文件。

## 可注入文件系统

`lib/core/platform/file_system.dart` 定义了扫描与隔离区需要的最小接口：

- `type` / `stat` / `list`：不跟随链接的只读遍历。
- `createDirectory` / `writeString` / `openAppend` / `openWrite`：原子会话记录与日志写入。
- `rename` / `copy` / `deleteFile` / `deleteDirectory`：同卷重命名、跨卷复制回退与隔离区释放。
- `FsFileWriter`：对应 `entries.jsonl` 的追加、截断回滚与 flush 语义。

生产路径使用 `IoFileSystem`，测试与基准使用 `lib/core/platform/memory_file_system.dart`。内存实现：

- Windows 大小写不敏感路径，与产品语义一致。
- 原子 `rename`（文件覆盖、目录子树迁移、拒绝移动到自身子目录）。
- 只读文件删除错误、缺失父目录、非空目录删除错误。
- 稀疏文件：`seedFile(size: ...)` 不会分配对应大小的缓冲区，适合百万元素以上的扫描基准。
- `onOperation` 钩子：在每次操作前插入异步屏障或异常，用于并发顺序与失败路径测试。

`test/file_system_test.dart` 验证上述契约，`test/quarantine_metadata_hardening_test.dart` 与 `test/concurrency_test.dart` 通过内存文件系统运行，不依赖真实磁盘时序。

## 元数据防御

隔离区属于用户可写目录，`session.json`、`entries.jsonl` 与 `plan.jsonl` 都可能被篡改。读取时执行以下校验：

- 会话 ID：1–64 个字符，只允许字母、数字与下划线，拒绝路径分隔符、隐藏名称、DOS 设备名与超长 ID。
- `storedName`：拒绝 `.` / `..`、路径分隔符、冒号（备用数据流）、控制字符、`<>"|?*`、尾随点 / 空格、DOS 设备名与超过 200 字符的名称。
- 条目路径：`originalPath` 与 `rootPath` 必须是绝对路径，且原路径严格位于声明的根目录内；大小必须为非负有限数且不超过 JavaScript 安全整数上限。
- 会话状态：只接受 `cleaning` / `ready` / `partial` / `restored`；未知状态不会列出、撤销或续跑。
- 计数：负数、NaN 与字符串计数会钳制或回退，不会导致列表崩溃或伪造负数占用。
- JSONL：截断或损坏的行计为“被拒绝条目”。撤销会保留会话并报告无法解析的记录数，不会因为剩余条目为空而自动删除会话；续跑遇到被拒绝条目会停止。`session.json` 损坏或版本未知时，单个会话拒绝操作，`listSessions` 静默跳过。
- 更高 schema 版本：不猜测、不迁移、不删除；保持原样等待新版 Broom。

恶意元数据测试位于 `test/quarantine_metadata_hardening_test.dart`，覆盖路径穿越、超长名称、保留设备名、未知状态、截断 JSONL、越界计划与负计数。

## 并发保护

两层防护：

1. **控制器 phase**：扫描与清理互斥；清理中忽略新的扫描、恢复上次结果与重复清理；扫描或清理中拒绝撤销；`_undoBusy` 阻止并发撤销。
2. **服务端互斥**：`QuarantineService` 使用 FIFO `AsyncMutex` 串行化 `clean` / `resumeClean` / `undo` / `purgeSession` / `purgeAllSessions`。即使绕过 UI 直接调用，清理与撤销也不会交错写入同一会话。只读查询（`listSessions` / `listEntries` / `getSession`）不加锁，会话文件通过临时文件 + 重命名原子更新，JSONL 半行会被安全忽略。

`test/concurrency_test.dart` 使用文件系统屏障验证：

- 清理仍在移动文件时，`purgeAllSessions` 不会开始删除。
- 撤销持锁期间，只读查询仍可返回当前会话；后续 purge 等待撤销结束后发现会话已被移除。
- 两次清理排队执行，各自生成独立会话，不共享序号或日志文件。
- 控制器在清理中阻止扫描 / 撤销 / 重复清理，在扫描中阻止清理 / 撤销。

## 日志与诊断

- 默认关闭，设置页“诊断与日志”可开启；日志级别固定为 `info`（包含 error / warning）。
- 文件位于 `%LOCALAPPDATA%\Broom\logs\broom.log`，单文件上限 512 KiB，保留 `broom.1.log` 与 `broom.2.log` 两个归档。
- 每条日志包含 UTC 时间、级别、分类与事件描述；错误与堆栈截断为单行，换行被转义，防止日志注入。单行上限 8 KiB。
- 不记录文件内容。允许记录路径、规则 ID、数量、字节数、错误消息与堆栈，用于定位问题。
- 写日志是 fire-and-forget，磁盘满、目录不可写或 IO 失败只会记录在内存中的 `lastWriteError`，不会让扫描、清理或撤销失败。
- 设置页可导出 `broom.diagnostics` JSON：格式版本、Broom 版本、生成时间、日志级别、系统 / 语言 / CPU 数量与拼接后的滚动日志。日志关闭时仍导出环境信息；导出由用户主动选择保存位置。
- 日志开关保存在 `settings.json` 的 `diagnosticsEnabled` 字段，旧配置文件缺少该字段时默认关闭。它不参与网络上报，Broom 仍无遥测。

测试位于 `test/app_logger_test.dart` 与 `test/settings_page_test.dart`：默认关闭、级别过滤、轮转、换行转义、写失败降级、导出格式与设置页交互。

## 性能基准

参考结果、环境与注意事项见 [benchmark/README.md](../benchmark/README.md)。基准使用合成文件系统，只测量扫描、去重与对象传输逻辑，不包含真实磁盘 I/O、杀毒扫描或 NTFS 元数据读取；1M 场景需要显式 `--million`。UI 帧测试在真实窗口运行，但集成测试绑定不提供 raster 时间，GPU 成本应使用 `flutter run --profile` 与 DevTools 时间线确认。

## 静态检查与 CI

`analysis_options.yaml` 在 `flutter_lints` 之上启用：

- `strict-casts`、`strict-inference`、`strict-raw-types`。
- 未使用的元素 / 字段 / 导入 / 局部变量、死代码与弃用 API 作为**错误**。
- 额外 lint：返回类型、单引号、尾随逗号、指令排序、final 字段、空判断、无效括号 / lambda、`BuildContext` 异步使用、`StreamSubscription` 生命周期、字面量布尔表达式等。

`.github/workflows/windows.yml` 在 `windows-latest` 上：

1. `dart format --output=none --set-exit-if-changed lib test benchmark integration_test`
2. `flutter analyze --fatal-infos`
3. `flutter test`
4. `flutter build windows --release`
5. 上传 `build/windows/x64/runner/Release/` 构建产物

桌面集成测试与 1M 基准作为 `workflow_dispatch` 的可选任务，避免每次推送都创建真实窗口或占用大量内存。
