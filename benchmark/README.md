# Broom 性能基准

基准直接驱动扫描引擎与 Flutter 桌面运行时，不使用真实缓存目录：文件树由 `benchmark/support/synthetic_tree_file_system.dart` 按需生成，因此结果可以重复，也不会把机器上的真实文件带入测试。

例外是需要在真实文件上测量的三项：`benchmark/clean_attribution_test.dart` 的开销几乎全部来自真实的系统调用（rename、open、Defender 过滤驱动）；`benchmark/ntfs_index_benchmark_test.dart` 的每个索引候选都要 `stat`；`benchmark/scan_restore_benchmark_test.dart` 需要真实的 `items.jsonl`（1M 条约 231 MiB）。三者都在系统临时目录下自建文件并在结束后删除。

`benchmark/ui_preview_benchmark.dart` 也是合成的：10 万条 `JunkItem` 在内存里生成，只测选择聚合与过滤/排序的 CPU 成本，不碰磁盘。

## 运行

```bash
# 10 万文件（流式 + 保留结果），以及 isolate 传输成本
dart run benchmark/scan_benchmark.dart

# 追加 100 万文件流式扫描（需要更多内存与时间）
dart run benchmark/scan_benchmark.dart --million

# 清理阶段每文件耗时的逐操作归因（需要 Flutter）
flutter test benchmark/clean_attribution_test.dart

# NTFS 索引路径的 stat 流水线 A/B（真实临时文件，需要 Flutter）
flutter test benchmark/ntfs_index_benchmark_test.dart

# 恢复侧解析 A/B：主 isolate vs 后台 isolate 流式解析（10 万 / 100 万条）
flutter test benchmark/scan_restore_benchmark_test.dart

# UI 侧选择聚合与过滤/排序（纯 CPU，可指定条目数）
dart run benchmark/ui_preview_benchmark.dart
dart run benchmark/ui_preview_benchmark.dart --items=1000000

# 真实 Windows 窗口中的预览滚动帧时间
flutter test integration_test/ui_frame_benchmark_test.dart -d windows

# 完整应用冒烟（真实 Windows 窗口）
flutter test integration_test/app_smoke_test.dart -d windows
```

`scan_benchmark` 输出每次扫描的耗时、文件/秒、MiB/秒、扫描前后的进程 RSS 与命中字节数；`ui_frame_benchmark_test` 输出 40 次预览滚动帧的 build / raster / total 的 p50 与 p95。

`clean_attribution_test` 输出三张表：分阶段（setup+plan / 每文件循环 / finalize）的墙钟与系统调用占比、逐操作单价与次数、以及 `dart:io` 原语的拆解（`readAsBytes` vs `open`+`read`+`close`、`position()`、`flush()`）。结论与优化项见 `docs/perf-review.md` 的 P0-5。它不在 `test/` 下，因此 `flutter test` 与 CI 都不会自动跑到。

## 参考结果（2026-10-19）

环境：Windows 10.0.26340，16 逻辑处理器，Flutter 3.47.7 / Dart 3.13.5，开发机构建。绝对数字会随磁盘、CPU 与后台负载变化，趋势与量级应在同一数量级内。

| 场景 | 文件数 | 耗时 | 吞吐 | 进程 RSS |
| --- | ---: | ---: | ---: | ---: |
| 流式扫描（`retainItems: false`） | 100,000 | 600 ms | 166k 文件/秒 · 650 MiB/s | 247 → 232 MiB |
| 保留结果（`retainItems: true`） | 100,000 | 531 ms | 188k 文件/秒 · 735 MiB/s | 232 → 229 MiB |
| 流式扫描 | 1,000,000 | 5.99 s | 167k 文件/秒 · 652 MiB/s | 229 → 274 MiB |

- RSS 为采样值，短扫描可能被 GC 掩盖而出现负增量；1M 场景更能反映去重集合与流式批次的真实内存占用。
- isolate 往返传输：100,000 个 `JunkItem`，每批 256 个，28–30 ms，约 0.26–0.31 µs/文件。扫描服务使用相同的分批边界，因此可以把该数字视为结果回传的近似成本。
- UI 帧：5,000 条预览结果、40 次滚动，build p50 1.17 ms / p95 4.24 ms，total p50 2.53 ms / p95 13.72 ms。集成测试绑定不提供 raster 时间（输出为 0），GPU 光栅成本需在 `flutter run --profile` 中查看 DevTools 时间线。

清理阶段（400 × 1 KiB，同卷 rename，3 轮均值，2026-10-20）。下表是 **P0-5a–d 改造前**的构成，用于定位优化项；改造后 `type`、`position()` 已从每文件调用中消失，日志与计划写入从 2.00 次/文件降到 1.02 次/文件：

| 项 | µs/文件 | 占比 |
| --- | ---: | ---: |
| 同卷 rename | 994.9 | 41.5% |
| `readBytes`（完整性哈希读取） | 458.6 | 19.1% |
| `stat` | 208.9 | 8.7% |
| `writeString`（撤销日志 + 清理计划） | 176.0 | 7.3% |
| `type`（finalize 复检） | 158.8 | 6.6% |
| `position()` | 63.4 | 2.6% |
| 其余系统调用 | 57.3 | 2.4% |
| 非系统调用（CPU / 分配 / GC / 调度） | 278.4 | 11.6% |
| **合计** | **2,399.5** | 100% |

单次 `readAsBytes(1 KiB)` 为 437–446 µs，其中 `open + close` 已占 255 µs，`sha256` 仅 14.5 µs；`position()` 为 47.5 µs，`flush()` 为 201 µs。改造后同一轮内交错测量：`readAsBytes` 515.5 µs vs `readBytesUpTo(size + 1)` 434.0 µs。

这台机器的端到端总时长在相邻运行之间会摆动 10% 以上（Defender 负载），因此**不要用两次整体运行的差值做 A/B**：未改动的 rename 单项在两次运行间就从 995 µs 变到 1,280 µs。可靠的比较来自调用次数与同一轮内的交错计时。

UI 侧（10 万条，合成条目，`dart run benchmark/ui_preview_benchmark.dart`，5 轮中位数，2026-10-20）。基准里保留了改造前实现的副本，因此"旧/新"两列来自同一个进程、同一批数据：

| 操作 | 旧 | 新 |
| --- | ---: | ---: |
| 三个选择聚合 getter | 22.0 ms | 0.000 ms |
| `sortResultItems(sizeDesc)` | 55.7 ms | 39.9 ms |
| `sortResultItems(pathAsc)` | 405.1 ms | 166.7 ms |
| `sortResultItems(extensionAsc)` | 2,443.6 ms | 273.8 ms |
| `sortResultItems(sizeDesc)`，全部同体积 | 452.3 ms | 369.6 ms |
| `filter + sort` 默认视图，每次重建 | 50.4 ms | 0.000 ms（缓存命中） |
| `filter + sort` 换成关键词 filter（未命中） | — | 28.8 ms |

结论与优化项见 `docs/perf-review.md` 的 P0-3 与 P0-4。`ui_preview_benchmark` 只测纯 CPU 计算，不含 Flutter 布局与绘制；帧时间仍以 `ui_frame_benchmark_test` 为准。

NTFS 索引 stat 流水线（P0-2，2026-10-21，2 万个真实文件，交错 3 轮取中位数）：

| 并发度 | 中位耗时 | µs/文件 | 相对串行 |
| ---: | ---: | ---: | ---: |
| 1（改造前逐条 `await` 的等价基线） | 2,745 ms | 137.3 | 1.00× |
| 2 | 1,366 ms | 68.3 | 2.01× |
| 4 | 1,093 ms | 54.7 | 2.51× |
| 8 | 1,080 ms | 54.0 | 2.54× |

索引枚举本身是假的（原生 USN 不在测量范围内），但每个路径都指向真实文件，每次 `stat` 都是真实的 `FileStat.stat`。1 路到 2 路收益最大，4 路接近饱和，8 路只再快 1–3%，说明剩余瓶颈在 OS 侧元数据查询排队。同日复跑（另一批 2 万文件）的 8 路为 2.64×、2 路为 2.01×，排序一致。结论见 `docs/perf-review.md` 的 P0-2。

恢复侧解析（P2-8 候选，2026-10-21，真实 `items.jsonl`，3 轮交错取中位数）：

| 条数 | 文件 | 当前 `store.load` | isolate 流式解析 | 主 isolate 纯接收上界 |
| ---: | ---: | ---: | ---: | ---: |
| 100,000 | 23.0 MiB | 588 ms | 542 ms | 7 ms |
| 1,000,000 | 230.6 MiB | 5,384 ms | 5,222 ms | 103 ms |

当前路径的解析全部落在调用方（UI）isolate；后台 isolate 方案总耗时不变或略优，主 isolate 只剩批量接收。基准不含 `_groupResults`、默认选择与首帧构建。结论见 `docs/perf-review.md` 的 P2-8。

## 说明

- 合成文件系统只负责枚举与 `stat`，因此这些数字代表扫描与去重逻辑的成本，不包含真实磁盘 I/O、杀毒软件扫描或 NTFS 元数据读取。
- 1M 场景默认不运行，避免在普通 CI 或低内存机器上触发 GC 抖动。需要在大内存机器上评估内存峰值时再打开。
- UI 帧测试的阈值（p95 total < 250 ms）只用于发现严重卡顿；桌面目标通常应低于 16.7 ms，具体取决于硬件与刷新率。
