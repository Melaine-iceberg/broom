# 扫描引擎

本文档描述 Broom 扫描引擎的数据流、持久化格式、并发与优先级、NTFS 索引、错误分类、在线规则更新和路径语义抽象。安全边界与已知限制以 [README](../README.md) 与 [路线图](roadmap.md) 为准。

## 1. 组件与数据流

```
CleanController.scan()
  ├─ 按类别 / 规则开关构建 ScanJob
  ├─ ScanResultStore.begin()  → scans/<id>/items.jsonl
  ├─ ScanService.scan()
  │    ├─ 低优先级原生通道（可选）
  │    ├─ NTFS 索引可用 → 根 isolate 内索引扫描
  │    └─ 否则 → N 个 worker isolate，每个只扫描分配到的任务
  │         └─ JunkScanner
  │              ├─ onProgress → 合并进度
  │              ├─ onItems    → 去重 / 全局上限 / 持久化 / 增量聚合
  │              └─ onIssue    → 分类汇总
  └─ writer.complete() → meta.json + latest.json
```

- `JunkScanner` 是唯一的候选文件收集器：普通路径使用逐目录遍历，索引路径只把 USN 结果当作候选集，仍会读取每个文件的真实 `stat`。
- 普通遍历优先使用原生目录枚举（见第 5 节）：一次 `FindFirstFileW` 返回名称、大小、修改时间与属性，因此一个文件只产生一次系统调用，而不是“枚举 + `stat`”两次。
- 扫描器跳过链接 / reparse point、越界路径、排除目录、被其他规则认领的子树、扩展名与修改时间不匹配的文件。
- `ScanService` 对跨 worker 的重复路径按 `PathSemantics.key` 去重；worker 不保留完整结果，避免内存与 isolate 传输双份占用。
- 控制器持有本轮唯一的内存结果集，分批聚合；最终预览与持久化都基于同一份去重结果。
- 取消会广播到所有 worker 与正在进行的索引流。取消的扫描不会发布持久化结果。
- 扫描类别开关在构建 `ScanJob` 之前生效。`leftover.*` 规则由 `LeftoverService` 在运行期生成，关闭“卸载残留”类别时既不读取注册表也不探测应用目录；这些规则的结果只存在于当前会话，不写入持久化结果。

## 2. 流式协议

`ScanService.scan` 的调用方可以注册：

| 回调 | 内容 |
| --- | --- |
| `onProgress` | 扫描文件数、去重后的发现数与字节数、错误数、耗时、worker 数、当前规则 |
| `onItems` | 已去重的 `JunkItem` 批次（默认 256 条/批） |
| `onIssue` | 单个 `ScanIssue`（路径、规则、错误类别、消息、是否目录） |

进度节流由扫描器控制（默认 300 ms）；批次由扫描器的 `batchSize` 控制。扫描结束返回的 `ScanResult` 只包含汇总与问题列表；除非调用方要求 `retainItems`，否则不重复携带全部条目。

## 3. 数量上限与磁盘保护

- 引擎**没有**固定的 100,000 条上限；`ScanOptions.maxItems` 为空表示不限制。
- 设置页提供可选上限，默认留空。上限是去重后的全局上限，由协调器执行；达到后取消剩余 worker，`ScanResult.truncated` 为 `true`，但 `cancelled` 仍为 `false`。
- 持久化写入器对 `items.jsonl` 设置 1 GiB 保护上限。达到后停止写入后续条目（当前预览不受影响），元数据记录 `persistenceLimited: true`，界面提示持久化结果可能不完整。
- 写侧在专用 isolate 中编码，并用 4 MiB 字节缓冲合并 append：累计达到阈值才 `add` + `flush`，不足一批的尾部在 `complete()` 统一写入。`items.jsonl` 只在 `meta.json` / `latest.json` 发布后才被读取，因此缓冲不改变持久化语义。
- 扫描失败、取消或用户中止时会调用 `abort()` 删除未完成的目录；崩溃留下的孤立目录不会被读取，并会在下一次成功发布的清理阶段被移除。

## 4. 并发与低优先级

- `parallelism = 0` 表示自动：按处理器数量选择 worker，上限 4 且不超过任务数。`1` 可强制单 worker。
- 任务按连续切片分配给 worker；每个 job 保留原始索引用于进度显示。
- 单个 worker 内部，每个目录的 `stat` 调用按 `statConcurrency`（默认 8）流水线并发：目录枚举只给出名字，大小与时间戳必须逐文件查询，串行 `await` 时线程完全在等 I/O 延迟。结果按枚举顺序消费，因此去重与上限判定保持确定，`maxItems` 语义不变。
- 低优先级通过 `broom/scan_priority` 只降低 **CPU** 调度优先级（`BELOW_NORMAL_PRIORITY_CLASS`），扫描结束 / 取消 / 失败时恢复。
  - 不使用 `PROCESS_MODE_BACKGROUND_BEGIN`：它同时把进程 I/O 优先级压到 very low 并触发工作集裁剪，扫描自身的读取会排在所有进程之后，界面与光栅线程也会因为缺页而掉帧——两个症状都来自这一条调用。
- 优先级调整失败不会阻塞扫描。该设置仍作用于整个进程，只是不再影响 I/O 与内存优先级。

## 5. 原生目录枚举（`broom/directory_enum`）

与设置项无关，Windows 上默认启用。

1. `ScanService` 派生 worker 之前，从根 isolate 调用一次 `ping` 探测通道是否存在；只有探测成功才允许 worker 使用它。旧版 runner、非 Windows 平台或单元测试环境探测失败时，扫描自动回落到 `Directory.list` + 逐文件 `stat`。
2. worker isolate 通过 `RootIsolateToken` + `BackgroundIsolateBinaryMessenger.ensureInitialized` 取得平台通道。没有 token 的后台 isolate 直接发平台消息会**中止 isolate**，而不是抛出可捕获异常；因此“能否使用”必须由根 isolate 决定后显式下传（`_WorkerRequest.useDetailedListing`）。
3. 原生侧在 4 个常驻线程上执行 `FindFirstFileW` / `FindNextFileW`，路径统一补 `\\?\` / `\\?\UNC\` 前缀，超过 `MAX_PATH` 的目录同样可枚举；结果通过 `PostMessage` 回到平台线程再回复通道，平台线程本身不执行枚举。
4. 返回四个并行数组：`names`（UTF-16 → UTF-8）、`sizes`（Int64List）、`modified`（Int64List，Unix 微秒）、`attributes`（Int32List）。类型在 Dart 侧按属性位映射：`REPARSE_POINT` → link（不跟随）、`DIRECTORY` → directory，其余为 file。
5. 空目录的 `FindFirstFileW` 返回 `ERROR_FILE_NOT_FOUND`，原生侧会再查一次路径属性以区分“空目录”和“路径不存在”；后者以 `PlatformException(code: win32, details: 错误码)` 返回，Dart 侧转成带 `OSError` 的 `FileSystemException`，沿用既有的错误分类。

约束与取舍：

- 每个目录一次通道往返，因此“目录少、文件多”的树收益最大（N 次 `stat` → 1 次调用）；只有一两个文件的目录与 `Directory.list` 大致持平。
- 原生返回的修改时间是 UTC 微秒，Dart 侧转本地时间，与 `FileStat.modified` 语义一致。
- 通道不可用属于降级而不是错误：两条路径共用同一套过滤、去重与上限逻辑，差异只在系统调用次数。`test/junk_scanner_detailed_listing_test.dart` 用注入文件系统断言详细枚举路径下 `stat` 调用为 0。
- 空目录时四列都为空，此时代码改为返回普通空列表：零长度的类型化数组经标准编解码往返后 Dart 侧会解析失败（`Message corrupted`），而空列只会出现在空目录这一种情况。

## 6. NTFS USN 索引（可选）

设置项 `useNtfsIndex` 默认关闭。启用后：

1. 扫描协调器先对每个根目录调用原生 `probe`。只有所有根目录都可用时才走索引路径；否则整体回退并行目录 worker，避免一半索引一半遍历的重复工作。
2. `probe` 检查：
   - 卷为本地盘符卷（UNC 与挂载点卷暂不支持）；
   - 文件系统为 NTFS；
   - 能以 `GENERIC_READ` 打开卷（通常需要管理员权限）；
   - USN 日志处于活动状态。
3. 原生线程用 `FSCTL_ENUM_USN_DATA` 枚举 MFT，构建 `文件 ID → (父 ID, 名称, 属性)` 与子索引；同一卷的索引在 5 分钟内复用。
4. 通过根目录句柄取得文件 ID，从根 BFS；跳过 reparse point；按扩展名预筛后把完整路径分批（512 条）通过 `PostMessage` + `MethodChannel.InvokeMethod` 回传根 isolate。
5. 扫描器把候选按 512 条攒批，复用目录遍历的 8 路 `stat` 流水线读取真实大小与修改时间，再应用修改时间过滤；索引不读取文件内容。本机 2 万真实文件两次实测流水线约为逐条 `stat` 的 2.5×，见 `docs/perf-review.md` 的 P0-2。
6. 任何探测 / 枚举 / 根目录 ID 不匹配错误都会以流错误返回，扫描器记录一条“NTFS 索引不可用，已回退”问题并走普通遍历。

限制：

- 索引只支持本地 NTFS；ReFS、FAT/exFAT、网络盘、只读介质不可用。
- 标准用户通常无法打开卷句柄，因此该功能默认关闭且自动回退。
- USN 索引是快照；扫描期间创建 / 删除的文件可能表现为“文件消失”或未发现，清理阶段仍会逐项校验。
- 本索引不包含文件大小与最后写入时间，不能替代 `stat`。

## 7. 扫描错误

`ScanErrorKind` 的稳定取值：

| 值 | 含义 |
| --- | --- |
| `accessDenied` | 无权限（Win32 5 / POSIX EACCES） |
| `pathTooLong` | 路径过长（206 / ENAMETOOLONG） |
| `notFound` | 文件或目录消失 |
| `deviceNotReady` | 设备未就绪 |
| `networkUnavailable` | 网络路径 / 连接不可用 |
| `writeProtected` | 只读介质 |
| `diskFull` | 磁盘空间不足 |
| `unsupported` | 文件系统不支持该操作 |
| `sharingViolation` | 被其他进程占用 |
| `invalidName` | 文件名或路径格式无效 |
| `ioError` | 其他 I/O 失败 |
| `other` | 非文件系统异常 |

扫描结果页面按类别汇总并展示最多 5 个示例路径。错误分类只影响报告，不会删除任何文件。

## 8. 结果持久化

目录：`%LOCALAPPDATA%\Broom\scans\`

```
scans/
  latest.json                 # {"schemaVersion":1,"id":"<scan-id>"}
  <scan-id>/
    items.jsonl               # 每行一个 JunkItem
    meta.json                 # 汇总、错误计数、规则版本与持久化状态
```

`items.jsonl` 行格式：

```json
{"ruleId":"browser.chrome","rootPath":"C:\\...\\Cache","path":"C:\\...\\a.tmp","size":123,"modified":"2026-10-18T10:00:00.000Z"}
```

`meta.json` 关键字段：`schemaVersion`、`id`、`completedAt`、`scannedFiles`、`foundFiles`、`foundBytes`、`issueCount`、`errorCounts`、`truncated`、`ruleIds`、`rulesVersion`、`persistedItemCount`、`persistenceLimited`。

策略：

- 只发布成功完成的扫描；取消 / 失败会删除临时目录。
- 写入由每个 writer 的专用 isolate 编码并落盘；恢复时在 `Isolate.run` 中完成解析、按当前规则过滤与分组排序，主 isolate 只接收分组结果。
- 首页在启动时读取 `latest.json` 与 `meta.json`，只加载轻量摘要；用户点击“查看结果”后才读取 `items.jsonl`。
- 结果超过 **24 小时**视为过期，不再提供恢复。
- `rulesVersion` 或规则 ID 与当前目录不一致时标记“规则已变化”，仍允许查看，但不自动恢复；清理前路径守卫、排除列表与隔离区逻辑会再次校验。
- 新扫描成功发布后删除旧结果目录；只保留最近一次成功结果。

## 9. 在线规则更新

### 8.1 清单格式

```json
{
  "schemaVersion": 1,
  "version": "2026.10.18",
  "publishedAt": "2026-10-18T08:00:00Z",
  "algorithm": "hmac-sha256",
  "rules": [ /* RuleCatalogCodec 编码的完整用户规则目录 */ ],
  "signature": "<64 位十六进制摘要>"
}
```

签名计算：

1. 取 `schemaVersion`、`version`、`publishedAt`、`rules` 四个字段；
2. 按键名递归排序，输出无空白 JSON（`canonicalJson`）；
3. `signature = hex(HMAC-SHA256(key, UTF8(canonicalJson)))`。

### 8.2 构建与发布

签名密钥在构建时注入：

```bash
flutter build windows --release \
  --dart-define=BROOM_RULE_SIGNING_KEY=<release-key>
```

未注入密钥的构建会禁用在线更新，并在设置页说明原因。HMAC 是对称校验，密钥内嵌于客户端，适用于防篡改与版本回滚，但不能替代代码签名 / 供应链安全。发布密钥应仅用于受控构建，并通过 HTTPS 分发清单。

### 8.3 校验与回滚

应用更新前会验证：

- HTTPS（不跟随重定向）、响应不超过 4 MiB、网络超时；
- 清单版本、签名算法与签名；
- 规则目录 `schemaVersion`、规则 ID 格式与唯一性；
- 每条规则的风险等级、路径模板、扩展名、最小保留时间；
- 每条规则必须包含双语评审说明、反向证据与至少一个审计样例；
- 新目录必须包含全部内置规则 ID（不允许静默删除规则）。

校验通过后写入 `rules/active.json`，并将原文件保存到 `rules/previous.json`。设置页支持：

- **回滚上一版**：把 `previous.json` 重新提升为 active；
- **恢复内置规则**：把当前 active 保存为 previous，然后移除 active（目录为空时加载内置规则）。

任何一步失败都保留原 active 文件。加载时如果 active 损坏，会回退内置规则并显示错误，不执行部分应用。

用户关闭的规则按稳定 ID 保存，排除列表按路径保存，二者独立于规则目录版本。

## 10. 路径语义抽象

`lib/core/platform/path_semantics.dart` 定义 `PathSemantics`：

- `canonical` / `forIo` / `ensureLongPath`：持久化路径与 Win32 长路径之间的转换；
- `normalize` / `absolute` / `join` / `dirname` / `basename` / `extension` / `rootPrefix`；
- `key`：规范化比较键（Windows 小写，POSIX 保持大小写）；
- `same` / `isWithin`：防止兄弟前缀误判与父目录穿越；
- `isReservedComponent`：Windows 保留设备名检查。

扫描器、路径守卫、规则解析器与结果存储都可以注入语义实现；默认使用 `WindowsPathSemantics`，测试使用 `PosixPathSemantics` 验证大小写敏感与分隔符差异。隔离区移动与分析遍历器仍是 Windows 专用，跨平台时需要单独的文件系统后端。

## 11. 测试

```bash
flutter analyze
flutter test
flutter build windows --debug
```

重点测试：

- `test/junk_scanner_test.dart`：流式批次、无固定上限、索引路径与失败回退；
- `test/scan_service_test.dart`：worker 并行、全局上限、低优先级、索引可用性分流；
- `test/scan_result_store_test.dart`：JSONL 发布、过期、磁盘保护与中止清理；
- `test/rule_update_test.dart`：签名、篡改拒绝、内置规则保护与回滚；
- `test/path_semantics_test.dart`：Windows / POSIX 语义；
- `test/ntfs_index_client_test.dart`：原生流协议；
- `test/clean_controller_test.dart`：类别过滤、持久化与重启恢复。
