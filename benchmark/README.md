# Broom 性能基准

基准直接驱动扫描引擎与 Flutter 桌面运行时，不使用真实缓存目录：文件树由 `benchmark/support/synthetic_tree_file_system.dart` 按需生成，因此结果可以重复，也不会把机器上的真实文件带入测试。

例外是 `benchmark/clean_attribution_test.dart`：清理阶段的开销几乎全部来自真实的系统调用（rename、open、Defender 过滤驱动），只能用真实文件测，因此它在系统临时目录下自建 400 个 1 KiB 文件并在结束后删除。

## 运行

```bash
# 10 万文件（流式 + 保留结果），以及 isolate 传输成本
dart run benchmark/scan_benchmark.dart

# 追加 100 万文件流式扫描（需要更多内存与时间）
dart run benchmark/scan_benchmark.dart --million

# 清理阶段每文件耗时的逐操作归因（需要 Flutter）
flutter test benchmark/clean_attribution_test.dart

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

清理阶段（400 × 1 KiB，同卷 rename，3 轮均值，2026-10-20）：

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

单次 `readAsBytes(1 KiB)` 为 437–446 µs，其中 `open + close` 已占 255 µs，`sha256` 仅 14.5 µs；`position()` 为 47.5 µs，`flush()` 为 201 µs。

## 说明

- 合成文件系统只负责枚举与 `stat`，因此这些数字代表扫描与去重逻辑的成本，不包含真实磁盘 I/O、杀毒软件扫描或 NTFS 元数据读取。
- 1M 场景默认不运行，避免在普通 CI 或低内存机器上触发 GC 抖动。需要在大内存机器上评估内存峰值时再打开。
- UI 帧测试的阈值（p95 total < 250 ms）只用于发现严重卡顿；桌面目标通常应低于 16.7 ms，具体取决于硬件与刷新率。
