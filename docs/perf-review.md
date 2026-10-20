# 性能评审与优化清单

本文记录 v4 之后的一次系统性能评审：测量方法、本机基线数据、按投入产出比排序的优化项，以及每一项的实施状态。文中所有数字都在同一台开发机上测得，绝对数值会随磁盘、杀毒软件与后台负载变化，但量级与相对关系可复现。

评审对象是扫描（`lib/core/scan/`）、清理（`lib/core/clean/`）、分析（`lib/core/analysis/`）与预览 UI（`lib/ui/`）四层。

## 测量方法与环境

| 项 | 值 |
| --- | --- |
| 系统 | Windows 11 Insider Preview 10.0.26340 |
| CPU | AMD Ryzen 9 7940H（16 逻辑处理器） |
| Dart | 3.13.5 / Flutter 3.47.7 |
| 构建 | 开发机 JIT，非 profile 构建 |

测量手段有三类，都在评审期间临时执行、未提交到仓库：

1. **单 API 微基准**：直接对 `dart:io` 与 `lib/core/` 中的函数做 N 次调用计时。用于量化单次元数据查询、路径规范化、过滤与排序的单价。
2. **真实目录遍历**：对 `%TEMP%` 做只读遍历，统计目录数/文件数与不同并发度下的耗时，用于判断枚举侧的剩余空间。
3. **复用既有基准**：`benchmark/scan_benchmark.dart` 的扫描吞吐与 RSS，`integration_test/ui_frame_benchmark_test.dart` 的帧时间。

需要强调的边界：微基准里的"文件数 × 单价"是算术推算，代表**可消除的固定开销**，不等于端到端耗时的全部；真实耗时还受磁盘、Defender 与文件系统过滤驱动支配。

## 基线数据

### 单次元数据查询（对本机真实文件，900 次采样均值）

| API | 单价 |
| --- | ---: |
| `FileSystemEntity.type(path, followLinks: false)` | 80.0 µs |
| `FileStat.stat(path)` | 111.8 µs |
| `File(path).stat()` | 115.9 µs |
| `File(path).length()` | 75.1 µs |

同一份 `WIN32_FILE_ATTRIBUTE_DATA` 的三种取法价格相当，都在 75–120 µs 区间。这意味着**重复查询不会因为"用的是轻量 API"而变便宜**，能省的是"次数"，不是"接口选型"。

### 目录枚举（`%TEMP%`：5,907 个目录 / 14,440 个文件）

| 并发度 | 耗时 |
| ---: | ---: |
| 1 | 1,949 ms |
| 2 | 1,972 ms |
| 4 | 2,215 ms |
| 8 | 2,021 ms |
| 16 | 1,983 ms |

并发从 1 提到 16 没有任何收益（差异在噪声内），说明该目录树的枚举成本由 OS 侧串行因素支配（Defender 过滤驱动是常见原因），**不是 Dart 侧的调度或延迟问题**。结论：扫描引擎的并行度已经饱和，继续加 worker 或 isolate 不会更快，优化必须从"减少调用次数"和"减少每文件工作量"入手。

### 扫描吞吐（既有基准，合成文件系统）

| 场景 | 文件数 | 耗时 | 吞吐 |
| --- | ---: | ---: | ---: |
| 流式扫描 | 100,000 | 600 ms | 166k 文件/秒 |
| 流式扫描 | 1,000,000 | 5.99 s | 167k 文件/秒 |

合成文件系统不含真实 I/O，因此 6 µs/文件代表扫描引擎自身的 CPU 成本。`PathSemantics.key()` 实测 0.21 µs（`normalize(absolute(canonical)).toLowerCase()`），被调用两次/文件，约占 7%——不是主要矛盾，但仍有压缩空间。

### UI 侧聚合与排序（10 万条结果）

| 操作 | 耗时 |
| --- | ---: |
| `filterResultItems`（空过滤） | 3.1 ms |
| `filterResultItems`（关键词） | 25.0 ms |
| `sortResultItems(sizeDesc)` | 32.5 ms |
| `sortResultItems(pathAsc)` | 207.3 ms |
| `visibleResultItems`（空过滤 + sizeDesc） | 29.7 ms |
| 单次 O(N) 选中体积扫描 | 5.2 ms |
| `availableExtensions` | 46.6 ms |

`pathAsc` 比其他排序慢 6 倍，原因是比较器内部对两个路径做 `.toLowerCase()`（`lib/ui/result_filters.dart:124/129`），一次排序产生数十万次字符串分配。

### 内存（100 万条结果，`JunkItem`）

| 结构 | 增量 |
| --- | ---: |
| `List<JunkItem>`（100 万） | +328 MiB |
| 再加 `Map<String, JunkItem>`（`_itemsByPath`） | +48 MiB |
| 再加 `Set<String>`（`_selectedPaths`） | +9 MiB |

单条约 328 B。其中 `ruleId` 与 `rootPath` 对同一规则的所有条目是完全相同的字符串副本，而两者都可以从 `RuleResult` 的分组关系推导出来。

## 优化项

### P0-1 清理阶段每个文件做 3 次元数据查询（已实施）

**现象**：`lib/core/clean/quarantine_service.dart` 的清理主循环（改造前行号）对每个待清文件依次调用：

| 位置 | 调用 | 单价 | 用途 |
| --- | --- | ---: | --- |
| `:505` | `_files.type()` | 80 µs | 判断是否为普通文件 |
| `:520` | `_files.stat()` | 112 µs | 取体积 |
| `:527` | `_captureMetadata()` → `File.stat()` | 116 µs | 撤销记录的时间戳/只读位 |

三次调用读的是同一份 `WIN32_FILE_ATTRIBUTE_DATA`。冷缓存下三次合计 308–520 µs/文件（本机实测区间），其中至少两次是纯冗余：任何一次的结果都足以喂饱另外两处的需求。

**改法**：让 `BroomFileSystem.stat()` 成为唯一元数据来源，`FileMetadataAccess` 只补它没有的部分（跨卷时的 DACL）。

- `FsStat` 增加 `accessed` / `changed` 两个可选字段（`IoFileSystem.stat` 从 `FileStat` 直接带出，无新增系统调用）。
- `FileMetadataAccess.read` 改为 `read(path, {required FsStat stat, required bool captureAcl})`：不再自己 stat，只按 `stat` 组装可恢复值；`MethodChannelFileMetadataAccess` 仅在 `captureAcl` 为真时才发起 ACL 通道调用。
- 清理循环改为单次 `stat()`：类型判断、体积、时间戳一次性拿全，缺失/非普通文件仍记为"跳过"并保持原有文案。

**收益（本机实测，400 个 1 KiB 文件的端到端 `clean()`，两轮取均值）**：

| 阶段 | 改造前 | 改造后 |
| --- | ---: | ---: |
| 元数据子阶段（type + stat + 元数据层 stat vs 单次 stat） | 520 µs/文件 | 179 µs/文件 |
| `clean()` 端到端 | 3,111 µs/文件 | 2,730 µs/文件 |

即每文件省约 **380 µs（-12%）**，与移除的两次系统调用（约 340 µs）吻合。绝对节省随文件数线性增长，但**不能把元数据开销当清理耗时的主体**——端到端里它只占约 12%，见 P0-5。

**风险**：低。类型判断仍不跟随重解析点（`stat` 对 reparse point 返回 `FsEntityType.link`，与原先 `type(followLinks: false)` 一致）；ACL 捕获条件不变。回归测试：`test/quarantine_metadata_hardening_test.dart` 新增"每文件只查询一次"用例（用 `onOperation` 钩子统计 `stat` 次数、断言没有 `type`），`test/quarantine_service_test.dart` 新增"从传入的 stat 推导撤销元数据"用例。

### P0-5 清理阶段每文件 2.7 ms 的构成（待调查，收益可能大于 P0-1）

P0-1 落地过程中对同一批 400 个 1 KiB 文件做了单步归因，端到端 2,730 µs/文件大致拆成：

| 步骤 | 单价 | 占比 |
| --- | ---: | ---: |
| 同卷 rename（真正的搬运） | ~900 µs | 33% |
| `readAsBytes(1 KiB)`（完整性哈希的读取） | ~458 µs | 17% |
| `stat` | ~173 µs | 6% |
| 撤销日志追加（每 32 条 flush 一次） | ~168 µs | 6% |
| SHA-256（1 KiB） | ~23 µs | 1% |
| 其余（路径守卫、JSON 编码、进度回调、`position()` 等） | ~1,000 µs | 37% |

两点值得继续查：

1. **完整性哈希要先单独打开并读一遍文件**（`_tryHashFile`），对 1 KiB 文件来说，打开+读取（458 µs）比哈希本身（23 µs）贵 20 倍，且这部分开销里很大一块是杀毒软件对文件打开的介入。可考虑：把哈希改成采样（头尾各 32 KiB，和 `DuplicateFinder` 一致）以缩短读取；或在跨卷复制路径上直接对已读入的缓冲区做哈希，避免二次打开。
2. **"其余"约 1 ms 尚未归因**，需要按操作粒度再拆一次（`writer.position()` 是否触发了额外系统调用是首要怀疑对象）。

同卷 rename 的 ~900 µs 是必要工作，但如果 Defender 对每次 rename 都做扫描，可以考虑在清理期间申请扫描豁免（`Add-MpPreference -ExclusionPath` 属于用户级安全设置，不能由程序擅自修改，因此这条只作为诊断结论保留）。

### P0-2 NTFS 索引路径逐条串行 stat（待实施）

`lib/core/scan/junk_scanner.dart:286-310` 在 `await for (ntfsIndex.enumerate(...))` 中逐条 `await processCandidate()`，而 `processCandidate` 内部是 `await fileSystem.stat(path)`（`:300`）。USN 索引只给出名称与 FRN，体积和时间必须逐个 stat，于是索引省下的枚举时间又被串行 stat 还回去：10 万候选项 × 112 µs ≈ **11 s**。

同一文件的目录遍历路径已经把 stat 做成了 8 路流水线（`processFiles`，`:191`），索引路径没有复用。改法是让 `enumerate` 的产出累积成 512 条一批，走同一个 `processFiles`。

**注意**：目录枚举的并发实验显示 OS 侧会串行化，因此这里不要假设 8 路能拿到 8 倍；先用 `benchmark/scan_benchmark.dart` 验证再投入。保守预期是 2–4 倍。

### P0-3 UI 每帧重复做 O(N) 聚合（待实施）

`CleanController` 的三个聚合 getter 每次 `build` 都会全量遍历：

| 位置 | 实现 | 10 万条成本 |
| --- | --- | ---: |
| `lib/ui/clean_controller.dart:242` | `selectedBytes` → `selectedItems` 先**分配全长列表**再 fold | 5.2 ms + 分配 |
| `lib/ui/clean_controller.dart:213` | `selectedPossiblyLockedCount` 双层循环 + `Set.contains` | ~5 ms |
| `lib/ui/clean_controller.dart:291` | `selectedBytesForRule` 单规则全量 | ~5 ms |

调用点都在 `build` 里：`lib/ui/home_page.dart:2592/2598`、`lib/ui/rule_detail_page.dart:178`。而扫描结束后锁探测以 250 ms 节奏 `_notify()`（`clean_controller.dart:1215-1224`），于是 10 万条结果时每帧约 10 ms 纯浪费，100 万条时约 100 ms——用户感知即"结果出来了但界面发黏"。

**改法**：改为增量维护。新增 `_selectedBytes`、`_selectedBytesByRule`、`_selectedLockedCount`，在 `toggleItem` / `_setRuleSelected` / `_selectAllItems` / `_resetSelection` / `_markPossiblyLocked` 中同步更新，getter 变成 O(1) 读字段。

**风险**：中低。选择状态有多条写路径（全选、反选、规则级勾选、恢复上次扫描），需要用现有 widget 测试（`test/home_page_test.dart` 等）守住一致性；任何一条漏更新都会显示错误的体积。

### P0-4 规则详情页每次重建都重新过滤+排序（待实施）

`lib/ui/rule_detail_page.dart:181` 在 `build` 里调用 `visibleResultItems(result.items, ...)`：空过滤 + 默认排序即 29.7 ms，用户切到"路径 A–Z"后为 207 ms/次。叠加 P0-3 的 250 ms 通知节奏，就是可见的卡顿。

**改法**：两件事分开做。

1. 按 `(filter, sort, 数据版本号)` 缓存可见列表，只在输入变化时重算；`_markPossiblyLocked` 会改动条目，因此需要一个单调递增的版本号参与缓存键。
2. 排序改为装饰-排序：先为每条算出一次小写路径或扩展名作为排序键，再按 key 排序，避免比较器内部重复 `toLowerCase()`。预计把 `pathAsc` 从 207 ms 降到 15 ms 量级。

### P1-5 分析工具没有复用扫描引擎的枚举能力（待实施）

`lib/core/analysis/file_tree_walker.dart:119-146` 用 `Directory.list` + 逐条 `await entity.stat()`，每文件一次 112 µs。`%TEMP%` 的 14,440 个文件仅 stat 就是 ~1.6 s；20 万文件的目录约 22 s。

而 `MethodChannelDirectoryEnumerator`（`FindFirstFileW`，一次返回名称/大小/时间/属性）已经存在并被扫描器使用，`IoFileSystem` 也已经实现了 `DetailedDirectoryListing`。把 walker 切到 `listDetailed` 可以整块消掉这项成本。注意 walker 同时被 `LargeFileScanner` 与 `DuplicateFinder` 使用，切换后需确认大文件阈值仍按 `stat.size` 过滤。

### P1-6 结果对象内存放大（待实施）

1M 条 328 MiB，其中 `ruleId`、`rootPath` 完全冗余；`DateTime` 对象也远大于 `int` 微秒。改法：

- `JunkItem` 不再逐条存 `rootPath`，改由 `RuleResult.rootPath`（或 `ruleId → rootPath` 映射）提供；`ruleId` 改为整型规则下标。
- 时间戳存 `int`（微秒），需要显示时再构造 `DateTime`。
- 删掉 `_itemsByPath`（`clean_controller.dart:129`），它只用于由 path 反查 `ruleId`，而这个信息在 UI 侧本来就手上有。

预期 1M 条从 400 MiB+ 降到 200 MiB 量级。对常驻后台的清理工具，这是体验层面的硬指标。

### P1-7 全局去重集合存整串路径（待实施）

`lib/core/scan/scan_service.dart:379` 用 `_seenPaths` 存每条结果的小写路径副本做跨规则去重，1M 条约 +100 MiB 常驻。可改为 64 位指纹（如 FNV-1a 或 xxHash）集合，碰撞概率在 1M 量级可忽略；或者按"根目录分区"在 worker 侧完成去重，只保留跨规则重叠的少量复核。

### P2-8 持久化 JSON 编码留在 UI isolate（待实施）

`lib/core/scan/scan_result_store.dart:348` 的 `addItems` 在 UI isolate 上逐条 `jsonEncode` + `utf8.encode`，1M 条就是 100 万次编码，以 256 条一批的节奏穿插在扫描通知之间。可移到专用 isolate，通过 `SendPort` 单向投递（结果只用于落盘，无需回传）。

### P2-9 目录枚举通道按目录逐个往返（待实施）

原生侧 `listDirectory` 每次只接受一个路径（`windows/runner/directory_enum_channel.cpp:132`）。本机 `%TEMP%` 单目录均摊 340 µs，其中通道往返占几十微秒量级，比例有限，因此优先级低于前几项。若要进一步压缩，可让原生侧接受路径数组，或提供"递归枚举 + 批量回调"。

### P2-10 系统缓存清理器的 type + length 双查询（待实施）

`lib/core/clean/system_cache_cleaner.dart:144-173` 先 `FileSystemEntity.type()` 再 `File.length()`，可合并为一次 `FileStat.stat()`（112 µs vs 155 µs）。唯一的顾虑是 `FileStat.stat` 无法区分符号链接，而现有代码显式跳过链接；直接替换会改变链接语义，因此需要先确认 `stat` 的链接行为再做，暂不纳入本轮。

## 不建议做的

- **继续提高扫描并行度**。实测目录枚举 1→16 并发无差异（1.95 s vs 1.98 s），瓶颈在 OS 侧且已饱和。加 worker、加 isolate、调 `statConcurrency` 都不会更快。
- **继续优化 `PathSemantics.key()`**。0.21 µs/次、约占单文件成本 7%，改进它需要动路径语义抽象，收益与风险不成比例。
- **把 `batchSize` 从 256 调大**。既有基准测得 isolate 传输成本为 0.26–0.31 µs/文件，1M 条合计约 0.3 s，调大批次省下的是消息条数而非总量级。

## 落地顺序

1. **P0-1**（已实施）：纯浪费，改动局部，风险最低；实测 -12% 端到端清理耗时。
2. **P0-5**：清理阶段还有约 1 ms/文件的未归因开销，且完整性哈希的读取比哈希本身贵 20 倍。这里的上限比 P0-1 更大，先按操作粒度再拆一次。
3. **P0-3 + P0-4**：都是 UI 侧"重复计算"，合计能把预览页的可感知卡顿消掉，且能靠现有 widget 测试守住。
4. **P1-5**：一次改动同时提速重复文件与大文件分析，收益明确。
5. **P1-6 + P1-7**：内存优化，涉及模型调整，放在功能稳定后做。
6. **P0-2 / P2-8 / P2-9**：需要基准验证或涉及原生侧，按实测收益排期。

## 变更记录

- **P0-1 已落地**：`FsStat` 增加 `accessed` / `changed`；`FileMetadataAccess.read` 改为接收调用方已有的 `FsStat` 且不再自行查询；清理主循环合并为单次 `stat()`。`flutter analyze --fatal-infos` 与全量 `flutter test`（386 项）通过。
- 评审过程中修正了一个判断：最初按单价推算认为"清理时间几乎全花在重复元数据查询上"，端到端 A/B 证明元数据只占约 12%，rename 与文件读取才是主体。文档中的收益数字以实测为准，未采用推算值。
