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

测量手段有三类：

1. **单 API 微基准**：直接对 `dart:io` 与 `lib/core/` 中的函数做 N 次调用计时。用于量化单次元数据查询、路径规范化、过滤与排序的单价。
2. **真实目录遍历**：对 `%TEMP%` 做只读遍历，统计目录数/文件数与不同并发度下的耗时，用于判断枚举侧的剩余空间。
3. **复用既有基准**：`benchmark/scan_benchmark.dart` 的扫描吞吐与 RSS，`integration_test/ui_frame_benchmark_test.dart` 的帧时间。

其中清理阶段（P0-5）的归因需要把一次 `clean()` 内部的调用逐项拆开，因此单独固化为 `benchmark/clean_attribution_test.dart`（`flutter test benchmark/clean_attribution_test.dart`，手工运行，不在 CI 的 `test/` 范围内）：它给 `BroomFileSystem` 套一层计时装饰器，按"操作 × 阶段"记账，再重放非系统调用的 CPU 工作，使端到端没有未解释的余额。其余微基准仍是一次性脚本。

需要强调的边界：微基准里的"文件数 × 单价"是算术推算，代表**可消除的固定开销**，不等于端到端耗时的全部；真实耗时还受磁盘、Defender 与文件系统过滤驱动支配。P0-5 的实测也印证了这一点——同一台机器上两次评审的端到端分别为 2,730 与 2,400 µs/文件，而单项单价基本不变。

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

这张表与后文的实施收益不是同一次运行的结果，绝对值不可直接相减。P0-3 / P0-4 的 A/B 用 `benchmark/ui_preview_benchmark.dart` 在同进程内交替测量改造前后的两套实现（旧实现作为参照副本保留在基准里），见对应小节。

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

### P0-5 清理阶段每文件 2.4 ms 的构成（已调查，四项子优化已实施）

P0-1 落地时对同一批 400 个 1 KiB 文件做过一次单步归因，当时把 2,730 µs/文件拆成六项，其中约 1,000 µs 归入"其余"未解释。本轮用可复现的方式重测：给 `BroomFileSystem` 加一层计时装饰器，把 `clean()` 发出的每一次系统调用按"操作 × 阶段"归账，再用脚本重放非系统调用的 CPU 工作，端到端误差归零。

复现命令（`benchmark/clean_attribution_test.dart`，仅在开发机手工运行）：

```bash
flutter test benchmark/clean_attribution_test.dart
```

#### 端到端总账（改造前，3 轮均值，400 × 1 KiB，同卷 rename）

| 操作 | 次数/文件 | µs/文件 | 占比 |
| --- | ---: | ---: | ---: |
| 同卷 rename（搬运） | 1.00 | 994.9 | 41.5% |
| `readBytes`（完整性哈希的读取） | 1.00 | 458.6 | 19.1% |
| `stat` | 1.00 | 208.9 | 8.7% |
| `writeString`（撤销日志 + 清理计划） | 2.00 | 176.0 | 7.3% |
| `type`（finalize 阶段的隔离文件复检） | 1.01 | 158.8 | 6.6% |
| `position()`（撤销日志） | 1.00 | 63.4 | 2.6% |
| `flush()`（每 32 条一次 + 计划尾部） | 0.04 | 24.2 | 1.0% |
| 会话 JSON 读写/改名、建目录 | — | 33.1 | 1.4% |
| 非系统调用（CPU、分配、GC、调度） | — | 278.4 | 11.6% |
| **合计** | | **2,399.5** | 100% |

分阶段看：`setup + plan` 142.2 µs/文件、每文件主循环 1,996.4 µs、`finalize` 260.9 µs。三轮的最小与最大值分别为 2,209 与 2,533 µs，波动来自 Defender 的实时扫描，而不是测量方法。

#### 三个结论

**1. `writer.position()` 确实是每文件一次独立系统调用。** 单独测量为 47.5 µs，在主循环里 63.4 µs——约为一次 `stat`（186 µs）的四分之一，但比纯 Dart 的路径与字符串操作高两个数量级，说明它走的是真正的句柄查询而不是本地计算。它只为"移动失败时回滚这条记录"服务（`_discardEntryWithoutStoredFile` 需要写入起点），而正常路径写完就 rename，从不使用这个值。这是此前"其余 1 ms"里的第一块：可以完全省掉。

**2. 此前完全没被计账的是 `type()`，来自 `finalize` 阶段的全量复检。** `_finalizeSession` 调用 `_pendingEntries`，后者对撤销日志中的**每一条**记录重新 `type(storedPath)`，确认隔离文件还在。一次 400/400 全部成功的清理，仍然付出 400 次 `type`（合计约 64 ms），得到的结论是"全部都在"。这是第二块，也是总账里占比最高的可消除项。

**3. 完整性哈希的贵在"打开"，不在"哈希"。** 拆开 `readAsBytes`：`open + close` 255 µs、`open + read + close` 332–345 µs、`readAsBytes` 437–446 µs（复测时顺序颠倒，两者差值稳定在约 110 µs，不是缓存效应）、`sha256` 仅 14.5 µs。也就是说读取与哈希的真实比例是 **30 : 1**，而 `readAsBytes` 比手写 `open`/`read`/`close` 多花的 110 µs 来自内部按 64 KiB 分块读到 EOF 再合并缓冲区，对 1 KiB 文件是纯固定开销。

与 P0-1 时期那份分解的差异：rename、读取、stat 三项高度一致（900–995 / 458 / 173–209 µs），说明主循环的骨架没变；此前的"其余 1,000 µs"实测可识别部分为 `type` 159 + 计划写入 88 + 非系统调用 278 ≈ 525 µs，剩余差额主要是两次运行之间 OS 侧的波动（本轮端到端 2,400 µs，当时 2,730 µs）。

#### 子项

下面的四项已全部实施，合计约 **380 µs/文件（改造前口径的 16%）**，都是局部改动，且都没有改变清理的持久化语义。回归测试集中在 `test/quarantine_clean_efficiency_test.dart`（10 个用例），另有既有 387 项测试全部通过。

**P0-5a 跳过全成功批次的全量复检（已实施，159 → 0 µs/文件）**

`_finalizeSession` 只有在"存在待恢复记录"时才需要 `_pendingEntries`：它决定会话是否保留、`pendingCount`/`pendingBytes` 写多少。当本轮 `failureCount == 0 && skippedCount == 0 && remainingCount == 0 && journal.rejected == 0` 时，pending 集合必然等于全部 item（减去已恢复的），可直接由计数推导，不必逐条探测。有失败、跳过、取消、续跑或存在无法解析的记录时维持原逻辑。

风险：低。短路与逐条探测在一种边缘情形下结论不同——若某个文件移动成功后立刻被外部删除，逐条探测会把它排除出 pending（并可能在 `remainingCount == 0` 时删掉整个会话），短路则仍把它算作待恢复记录，会话被保留、撤销时才报告缺失。短路方向更保守（不丢可恢复记录）。测试固定了两侧：全成功时不发起任何 `type` 探测且 `pendingCount` 正确；有失败时每个存活条目仍被探测一次。

**P0-5b 撤销日志的位置改为累计字节数（已实施，63 → 0.3 µs/文件）**

主循环每次迭代都 `await writer.position()`，只为在回滚时 `truncate(entryStart)`。日志是追加模式、本进程独占写入，因此写入起点可以由"打开时的位置 + 已写入字节数"算出：打开后取一次 `position()` 作为基线，之后累加 `utf8.encode(line).length`。回滚语义完全不变，正常路径零额外调用。

这里用一次 `utf8.encode` 换掉手写 UTF-8 长度计算：多花约 1.5 µs，但保证偏移量与 `dart:io` 实际写入的字节数严格一致，不需要重新推导代理对与替换字符的边界。

风险：低。`entries.jsonl` 在续跑时已有内容，因此基线位置必须真的取一次（每会话一次）。`_discardEntryWithoutStoredFile` 改为返回是否真的截断成功，调用方据此把偏移量回退到 `entryStart`，避免"截断失败但偏移量已回退"导致后续记录错位。测试覆盖三种情形：中文与 emoji 文件名下回滚后的日志仍逐行可解析、续跑时追加位置正确、截断后紧接的下一条记录完整。

**P0-5c 清理计划改为批量写入（已实施，86 → 约 1.5 µs/文件）**

`_writePlan` 对每个 item 单独 `writeString`，400 个文件就是 400 次写入（88 µs/次）。计划在清理开始前一次性写完、之后只被续跑逻辑读取，因此改为 64 行一批拼接后一次写入，写入次数从 N 降到 N/64。

风险：低。计划文件不参与"记录先于移动"的持久化承诺（那是 `entries.jsonl` 的职责），批量写不改变崩溃后的可恢复性。测试用 150 个条目跨过三个批次（64 + 64 + 22），断言行数、首行与末行内容与顺序不变。

**P0-5d 哈希读取改为按长度读取（已实施，约 81 µs/文件）**

`_tryHashFile` 原来用 `readBytes`（即 `File.readAsBytes`），而后者必须读到 EOF 才知道结束，会多付一次读取。新增 `BroomFileSystem.readBytesUpTo(path, limit)`：打开一次、按需读取、够数即停。`_tryHashFile` 用 `size + 1` 作为上限——返回长度小于上限就证明文件仍恰好结束于 `size`，正常路径只有一次读取；若返回长度大于 `size`（文件在 stat 之后变长），退回整文件读取，避免把摘要记成截断的前缀。撤销侧的 `_verifyStoredFile` 也改用它：那里上一步已经校验过长度等于 `size`。

风险：低。需要保证 `read` 短读时继续读到够数，否则大文件会算出错误摘要；`MemoryFileSystem` 与 `IoFileSystem` 都按"最多 limit 字节、短文件返回全文"实现。测试覆盖：摘要等于全文 SHA-256（含二进制内容）、文件变长时仍是全文摘要、超过 256 KiB 上限时不写摘要、两个后端的 `readBytesUpTo` 行为一致。

#### 实施后的 A/B：为什么用"每操作"而不是"两次端到端"

这台机器上端到端总时长在相邻两次运行之间会摆动 10% 以上（Defender 负载）：改造前后各跑一次的对比里，未改动的 rename 单项从 995 µs 涨到 1,280 µs、`stat` 从 209 涨到 287，而同期被删掉的调用确实消失了。两次整体运行的差值因此**不能作为证据**，只有两类数据可以：

1. **调用次数**（与负载无关，可复现）。同一基准（400 文件、3 轮）：

| 操作 | 改造前 | 改造后 |
| --- | ---: | ---: |
| 每文件 `type` 探测 | 1.01 | 0.01 |
| 每文件 `position()` | 1.00 | 0.00 |
| 每文件日志 + 计划写入 | 2.00 | 1.02 |
| 每文件哈希读取 | 1.00（`readBytes`） | 1.00（`readBytesUpTo`） |

2. **同一轮内的交错 A/B**（两个实现交替先后执行，机器漂移互相抵消）。哈希读取实测：

| 实现 | µs/次 |
| --- | ---: |
| `readAsBytes`（原） | 515.5 |
| `readBytesUpTo(size + 1)`（新） | 434.0 |
| 差值 | **−81.4（−16%）** |

按本轮实测单价折算，四项合计每文件省 **约 380 µs**（`type` ≈ 150、`position` ≈ 56、计划写入 ≈ 93、哈希读取 ≈ 81），相当于改造前 2,400–2,700 µs 口径下的 **14–16%**。绝对节省随文件数线性增长：10 万个文件的清理从约 240 s 降到约 202 s。

#### 决策点：小文件的完整性哈希是否保留（19.1%）

当前策略是"≤ 256 KiB 全量哈希，超过则只校验体积"。而清理对象以几 KiB 的缓存碎片为主，于是**被哈希的恰好是数量最多、单文件价值最低的那一批**，每文件付出 459 µs（占端到端 19%，P0-5d 之后约 380 µs）；真正的大文件反而不校验。

三个选项，按推荐顺序：

1. **保留哈希，只做 P0-5d**（已实施）。完整性是"可恢复清理"的核心承诺，459 µs 里已省下 81 µs 而无任何语义变化。
2. **改用体积 + 修改时间作为恢复校验**，仅在用户显式要求时哈希。可整块省掉约 15%，但撤销时的校验强度下降为"体积一致"，与当前文档承诺不符，需要同步修改用户可见文案。
3. **把哈希移到搬运之后**（读隔离区的副本，或在跨卷复制时复用已读缓冲区）。同卷 rename 不产生可用缓冲区，收益只体现在跨卷路径，不作为本轮范围。

不建议做：把哈希改成分段采样（与 `DuplicateFinder` 一致）。1 KiB 文件本身就小于采样窗口，"采样"等于全读，省不下 `open` 这个主要成本，只会降低校验强度。

#### 说明：rename 的 41.5% 不可压缩

同卷 rename 的 995 µs（本轮环境下 1,280 µs）是必要工作。作为对照，脱离清理流程的同步 `renameSync` 紧循环也要 756–1,040 µs/次，说明成本在 OS 侧（过滤驱动对每次重命名都要过一遍），Dart 侧的异步封装只额外增加约 240 µs 的事件循环往返。因此"减少 rename 次数"只能通过减少选中文件数实现，不属于引擎优化范围；扫描豁免属于用户级安全设置，程序不应自行修改（诊断结论保留，不做建议）。


### P0-2 NTFS 索引路径逐条串行 stat（待实施）

`lib/core/scan/junk_scanner.dart:286-310` 在 `await for (ntfsIndex.enumerate(...))` 中逐条 `await processCandidate()`，而 `processCandidate` 内部是 `await fileSystem.stat(path)`（`:300`）。USN 索引只给出名称与 FRN，体积和时间必须逐个 stat，于是索引省下的枚举时间又被串行 stat 还回去：10 万候选项 × 112 µs ≈ **11 s**。

同一文件的目录遍历路径已经把 stat 做成了 8 路流水线（`processFiles`，`:191`），索引路径没有复用。改法是让 `enumerate` 的产出累积成 512 条一批，走同一个 `processFiles`。

**注意**：目录枚举的并发实验显示 OS 侧会串行化，因此这里不要假设 8 路能拿到 8 倍；先用 `benchmark/scan_benchmark.dart` 验证再投入。保守预期是 2–4 倍。

### P0-3 UI 每帧重复做 O(N) 聚合（已实施）

**现象**：`CleanController` 的三个聚合 getter 每次 `build` 都会全量遍历：

| getter | 原实现 | 10 万条成本 |
| --- | --- | ---: |
| `selectedBytes` | `selectedItems` 先**分配全长列表**再 fold | 14.7 ms + 分配 |
| `selectedPossiblyLockedCount` | 双层循环 + `Set.contains` | 1.5 ms |
| `selectedBytesForRule` | 单规则全量 | 5.8 ms |

调用点都在 `build` 里：`lib/ui/home_page.dart:2592/2598`、`lib/ui/rule_detail_page.dart:178`。而扫描结束后锁探测以 250 ms 节奏 `_notify()`（`clean_controller.dart` 的 `_runLockProbe`），于是每次通知都重付一遍，合计约 **22 ms/次**（10 万条），用户感知即"结果出来了但界面发黏"。

**改法**：改为增量维护，新增 `_selectedBytes`、`_selectedBytesByRule`、`_selectedLockedCount`，getter 变成字段读取。

关键是**不要在多条写路径上各维护一份账本**。所有选择变更收敛到两个原语：

- `_selectPath(item)` / `_deselectPath(item)`：在同一个位置同时更新 `_selectedPaths`、`_selectedCountByRule`、字节总量、按规则字节、已选占用计数，并对"已选/未选"做幂等处理（返回 false 表示状态未改变）。
- `toggleItem`、`setRuleSelected`、`invertSelection`、`invertRuleSelection`、`clearRuleSelection`、`_selectAllItems`、`_selectDefaultItems`、`_resetSelection` 全部改为调用它们，原先各自 `_selectedPaths.add/remove` + 手动改计数的写法删除。
- `_startLockProbe` 在遍历条目重建 `_possiblyLockedCount` 时一并重算 `_selectedLockedCount`（覆盖"恢复上次扫描"时条目已带标记、且在此之前就被默认选中的情形）；`_markPossiblyLocked` 对已选条目加一。

收益：10 万条 **22.0 ms → 0.000 ms**（10 万次读取不足 1 µs，基准里显示为 0）。

**风险**：中低，实际比预期更低。原计划的"在每条写路径同步更新"最容易出的问题是漏更新，改成单一原语后这种可能被结构性消除——新增写路径如果绕过原语，`_selectedPaths` 本身也不会变，聚合值与选择状态会同时错，测试立刻能发现。回归用例用 `selectedItems`（由 `_results` 与 `_selectedPaths` 推导，与被优化的账本互相独立）作为 oracle，在"默认勾选 → 单项开关 → 规则勾选 → 规则反选 → 全局反选 → 清空 → 全选 → 规则取消"每一步后断言四个聚合值，并覆盖预先带占用标记的条目。

### P0-4 规则详情页每次重建都重新过滤+排序（已实施）

**现象**：`lib/ui/rule_detail_page.dart` 的 `build` 直接调用 `visibleResultItems(result.items, ...)`（现为 `_visibleFor` → `VisibleItemsCache.resolve`）：空过滤 + 默认排序 55.7 ms，用户切到"路径 A–Z"后 405.1 ms/次（同轮实测）。叠加 P0-3 的 250 ms 通知节奏，就是可见的卡顿。

**改法**：三件事，其中第 2 项与最初的设想不同。

1. **缓存可见列表**。新增 `VisibleItemsCache`，按 `(source, filter, sort, version)` 记忆化；`ResultItemFilter` 补齐值相等语义，页面每次重建新建的 filter 实例仍能命中。`CleanController` 新增 `itemsRevision`，在结果集替换（`_replaceResults`）与 `_markPossiblyLocked` 时递增。
2. **排序按"键是否已在条目上"分流**，而不是一律装饰-排序：
   - `sizeDesc` / `sizeAsc` / `modifiedDesc` / `modifiedAsc`：直接比较 `JunkItem` 字段。装饰版本实测反而更慢（见下），因为键本来就在条目上，装饰只是多分配 10 万个对象。仅当两个键相等时才派生小写路径，并按条目身份（`Map.identity`）缓存，因此"一串等体积碎片"也只派生一次。
   - `pathAsc` / `extensionAsc`：先为每条派生一次小写路径（扩展名序再派生扩展名），再按键排序。
3. 缓存命中时"过滤 + 排序"整体为 0。

**收益（同轮实测，10 万条，`dart run benchmark/ui_preview_benchmark.dart`，5 轮取中位数）**：

| 操作 | 改造前 | 改造后 |
| --- | ---: | ---: |
| 三个选择聚合 getter（P0-3） | 22.0 ms | 0.000 ms |
| `sortResultItems(sizeDesc)` | 55.7 ms | 39.9 ms |
| `sortResultItems(pathAsc)` | 405.1 ms | 166.7 ms |
| `sortResultItems(extensionAsc)` | 2,443.6 ms | 273.8 ms |
| `sortResultItems(sizeDesc)`，全部同体积 | 452.3 ms | 369.6 ms |
| `filter + sort` 默认视图，每次重建 | 50.4 ms | 0.000 ms（缓存命中） |
| `filter + sort`，换成关键词 filter（未命中） | — | 28.8 ms |

最后一行用的是"无匹配关键词"的 filter，28.8 ms 里几乎全是关键词逐条匹配的成本，不是排序——即未命中时也只付一次必要的过滤，排序对象已经为空。

即每次重建从约 72 ms（三个 getter + 过滤排序）降到 0；`pathAsc` 每次切换的代价从 405 ms 降到 167 ms，`extensionAsc` 从 2.4 s 降到 274 ms。后者的 8.9 倍来自"扩展名 + 小写路径"原本在每次比较里各算一遍。

**一处判断修正**：第一版把六种排序全部改成"装饰-排序"，基准显示 `sizeDesc` 反而从 46.4 ms 涨到 63.5 ms，而 `pathAsc` 只从 190 ms 降到 166 ms——装饰的成本是 O(N) 次对象分配，收益是省掉 O(N log N) 次派生，只有当派生比分配贵得多时才划算。改成按排序分流后才得到上表。

**风险**：中低。

- 缓存键含 `source` 的对象身份，页面被换上新结果集时不会显示旧数据；`_markPossiblyLocked` 递增版本号，锁标记能实时反映到已缓存的行。这一条是必需的：锁探测**替换**的是条目对象，若缓存只在输入变化时失效，行内"可能被占用"图标会停在旧值。
- 缓存不参与 `olderThan` 的时间基准：页面停留期间"30 天前修改"的边界不会随真实时间推移而重算。改动前后都只在重建时判断，差异在秒级以内。
- 回归用例：`test/result_filters_test.dart` 用改造前的比较器实现作 oracle，对 300 条含大量并列键的数据逐种排序断言顺序不变；缓存命中/失效计数逐次断言。`test/rule_detail_page_test.dart` 新增"锁探测在页面已打开后标记条目，行内锁图标随之出现且顺序不变"——把版本号写死为 0 时该用例失败，已确认。

### P1-5 分析工具没有复用扫描引擎的枚举能力（已实施）

**现象**：`lib/core/analysis/file_tree_walker.dart` 原来用 `Directory.list` + 逐条 `await entity.stat()`，每文件一次 112 µs。`%TEMP%` 的 14,440 个文件仅 stat 就是 ~1.6 s；20 万文件的目录约 22 s。

**改法**：walker 改为依赖 `BroomFileSystem`（默认 `IoFileSystem`），在后端实现 `DetailedDirectoryListing` 时优先 `listDetailed`，把名称、大小、修改时间与类型从同一次 `FindFirstFileW` 枚举里取回；`list + stat` 回退原样保留。访问者签名由 `(File, FileStat)` 改为 `(String, FsStat)`，两个使用方（`LargeFileScanner` / `DuplicateFinder`）只改取路径的方式。

分析工具运行在独立 isolate，平台通道需要根 isolate 的 messenger，因此还有一层协调：`AnalysisService` 在根 isolate 调用 `probeDetailedListingFromRoot()`（与扫描器共用同一探测），成功后把 `RootIsolateToken` 发进分析 isolate 并 `BackgroundIsolateBinaryMessenger.ensureInitialized`；token 缺失或初始化失败时把 `useDetailedListing` 降为 false，walker 走 `list + stat`。这样"后台 isolate 直接发平台消息会 abort"的风险在分析侧也被结构性规避。

**收益**：详细枚举路径下，N 个文件的逐文件 `stat` 从 N 次降到 0，只剩每个目录一次枚举。按本文 112 µs/次的口径，14,440 个文件省约 1.6 s，20 万文件省约 22 s，且同时作用于重复文件与大文件两个工具。`test/file_tree_walker_test.dart` 用 `MemoryFileSystem` 的操作钩子固定了调用次数：详细路径为 2 次 `listDetailed` + 0 次 `stat`（3 个文件），回退路径为 2 次 `list` + 3 次 `stat`。

局限：`flutter test` 没有原生 runner，通道探测必然失败，因此这项收益没有做安装包内的端到端 A/B；上面的节省是按已有单价与调用次数推算的量级，判断方式与 P0-5 的"调用次数可复现、端到端受 Defender 支配"一致。

**风险**：低。

- 枚举返回的 size / modified 与 `stat` 同源（`WIN32_FIND_DATAW`），大文件阈值继续按 `FsStat.size` 过滤。`test/large_file_scanner_test.dart` 新增用例断言枚举出的 500 B / 50 B 文件在 100 B 阈值下的结果，并断言全程没有 `stat`。
- 链接、排除目录、截断、取消与根目录缺失的语义不变；显式 `useDetailedListing: false` 的回退路径仍逐文件 `stat` 并把失败计入 `errorCount`。
- 一处报告口径变化：当后端是 `IoFileSystem` 且原生通道不可用时，其内部回退会跳过 stat 失败的子项（与扫描器一致），这些失败不再计入 walker 的 `errorCount`。该路径只出现在无原生通道的构建或测试环境；安装包内走原生枚举，不存在逐文件 stat。
- 回归：新增 `test/file_tree_walker_test.dart`（6 项）与 `test/large_file_scanner_test.dart` 的枚举尺寸用例；全量 410 项测试与 `flutter analyze --fatal-infos` 通过。

### P1-6 结果对象内存放大（已实施）

**现象**：1M 条结果常驻约 226–228 MiB（改造前形状的同轮基准）。每条 `JunkItem` 持有 `ruleId`、`rootPath` 两个字符串引用和一个 `DateTime` 对象：前两者在同一次扫描里完全重复，后者是每条的独立分配。

**改法**：

1. **压缩条目**：`JunkItem` 改为 `rootIndex`（int）、`path`、`size`、`modifiedMicros`（int 微秒）与 `possiblyLocked`。`modified` 变为按需构造的 getter。
2. **新增 `ScanRoots` 根表**：按 `jobs × roots` 展平生成 `(ruleId, rootPath)` 列表，`rootPath` 规范化一次，由扫描器、持久化、UI 与清理服务共享。扫描器带 `rootIndexBase` 写入条目；被跳过的根也占用下标，保证 worker 与协调者的展平顺序一致。
3. **删除 UI 侧反查表**：`clean_controller.dart` 的 `_itemsByPath` 与 `_itemLocations` 都不再需要。选择操作由 UI 直接传 `JunkItem`，规则归属用 `_scanRoots.at(item.rootIndex).ruleId`；锁探测结果从路径字符串改为全局条目下标，控制器按结果分组的前缀和定位条目并 `copyWith`。
4. **清理边界只传根表**：`QuarantineService.clean` / `SystemCacheCleaner.clean` 接收 `ScanRoots`，主循环按 `roots.at(item.rootIndex)` 取 `ruleId` / `rootPath` 做路径守卫、日志与计划；断点恢复从 `plan.jsonl` 重建同一张表。
5. **持久化格式不变**：`items.jsonl` 仍逐行写 `ruleId` / `rootPath`（由根表展开），加载时按出现顺序去重重建 `ScanRoots`，`schemaVersion` 无需升级，旧结果文件可继续读取。

**收益（`dart run benchmark/item_memory_benchmark.dart`，每个模式独立进程，1M 条、路径长约 75–80 字符，`ProcessInfo.currentRss` 前后差值，各跑 3 次）**：

| 形状 | RSS 增量 |
| --- | ---: |
| 改造前（`ruleId` + `rootPath` + `DateTime`） | 226 / 227 / 226 MiB |
| 改造后 `JunkItem` | 91 / 89 / 89 MiB |

即 1M 条节省约 135–138 MiB。显示修改时间时才构造 `DateTime`；列表排序与"早于 N 天"过滤直接比较整数微秒。

**风险**：中。`rootIndex` 只有配上同一份 `ScanRoots` 才有意义，因此所有跨层边界一起改：worker 偏移、持久化重建、UI 恢复顺序、清理计划恢复都要求下标与根表严格对齐。回归覆盖：

- `test/junk_scanner_test.dart` 新增多根规则用例，断言每条结果经 `roots.at(rootIndex)` 映射回自己的根；
- `test/scan_result_store_test.dart` 断言往返后根表与 `rootIndex` 不变；
- `test/clean_controller_test.dart` 覆盖多规则下标、恢复上次扫描（先重建根表再分组）与锁探测；
- 清理 / 系统缓存 / 隔离区相关测试全部改为显式传入根表，计划恢复用例额外写入了第二条根。

全量 413 项测试与 `flutter analyze --fatal-infos` 通过。

### P1-7 全局去重集合存整串路径（已实施）

**现象**：除 `ScanService._seenPaths` 外，`JunkScanner.seen` 在单次扫描期间也保留了一份小写路径集合；两处都是每条目一个字符串副本，1M 条约 80–95 MiB/处。

**改法**：新增 `pathFingerprint`（62 位 FNV-1a，按 UTF-16 code unit 两字节喂入），集合改为 `Set<int>`。掩码到 `0x3fffffffffff` 使值在 VM 上保持 Smi，避免堆上的大整数对象。`ScanService` 与 `JunkScanner` 两处去重同时换成指纹；跨 worker 的路径仍由协调者统一复核，语义不变。

**收益（同一基准，先预构建 1M 条路径再测集合增量，各 3 次）**：

| 集合 | RSS 增量 |
| --- | ---: |
| `Set<String>`（小写副本） | 94 / 95 / 80 MiB |
| `Set<int>`（指纹） | 19 / 28 / 31 MiB |

即单处节省约 60–75 MiB；扫描期间两处集合共存时，节省同步翻倍。

**风险**：低。指纹只用于"是否见过"的判断，碰撞会把两条不同路径中的一条当成重复而漏扫；62 位在 1M 量级的生日碰撞概率约 `1e-7`。`test/path_fingerprint_test.dart` 断言了稳定性、Smi 范围与 20 万条不同路径无碰撞。若未来单次扫描条数进入 10M 量级，应按 `n²/2^63` 重新评估。

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
2. **P0-5a–d**（已实施）：按"能整块删掉的调用"排序推进——`type` 复检、`position`、计划批写、哈希读取，四项合计约 380 µs/文件（14–16%）。互不冲突，各自带独立回归用例。
3. **P0-3 + P0-4**（已实施）：都是 UI 侧"重复计算"。P0-3 把每次重建的三个聚合从 22 ms 降到 0；P0-4 把每次重建的过滤+排序从 50 ms 降到 0（缓存命中），并把 `pathAsc` 从 405 ms 降到 167 ms。
4. **P1-5**（已实施）：walker 复用 `listDetailed`，逐文件 `stat` 归零；分析 isolate 通过根 isolate 探测 + token 接入原生枚举。
5. **P1-6 + P1-7**（已实施）：压缩条目形状并引入根表，两处去重集合改为指纹；1M 条结果常驻从约 227 MiB 降到约 89 MiB。
6. **P0-2 / P2-8 / P2-9 / P2-10**：需要基准验证或涉及原生侧，按实测收益排期。

## 变更记录

- **P0-1 已落地**：`FsStat` 增加 `accessed` / `changed`；`FileMetadataAccess.read` 改为接收调用方已有的 `FsStat` 且不再自行查询；清理主循环合并为单次 `stat()`。`flutter analyze --fatal-infos` 与全量 `flutter test`（386 项）通过。
- **P0-5 归因完成**：新增 `benchmark/clean_attribution_test.dart`，把 `clean()` 端到端 2,400 µs/文件拆到操作与阶段两级，余额归零。结论：rename 41.5% 不可压缩；`readBytes` 19.1% 中 30/31 花在 `open` 而不是 `sha256`；`position()` 确认是每文件一次独立系统调用（63 µs）；同时发现此前完全未计账的 `_pendingEntries` 全量 `type()` 复检（159 µs/文件）。
- **P0-5a–d 已落地**：短路全成功批次的条目复检、日志偏移改为累计字节数、清理计划 64 行批写、新增 `BroomFileSystem.readBytesUpTo` 供哈希与撤销校验使用。调用次数上 `type` 1.01→0.01、`position` 1.00→0.00、日志与计划写入 2.00→1.02；哈希读取交错 A/B 为 515.5→434.0 µs（−81.4）。回归测试 `test/quarantine_clean_efficiency_test.dart`（10 项），全量 397 项通过。
- **P0-3 已落地**：选择聚合改为增量维护。所有写路径收敛到 `_selectPath` / `_deselectPath` 两个原语（而不是在九条写路径上各改一遍），getter 由全量遍历变为字段读取；`_startLockProbe` 顺带重算已选占用计数。10 万条三个 getter 合计 22.0→0.000 ms。
- **P0-4 已落地**：新增 `VisibleItemsCache`（按 `source` 身份 + filter 值 + sort + `itemsRevision` 记忆化）、`CleanController.itemsRevision`、`ResultItemFilter` 值相等。排序按"键是否已在条目上"分流：数值键直接比较并在并列时惰性缓存小写路径，路径/扩展名键先派生一次再排序。默认视图每次重建 50.4→0 ms；`pathAsc` 405.1→166.7 ms，`extensionAsc` 2,443.6→273.8 ms。新增 `benchmark/ui_preview_benchmark.dart`，把旧实现作为参照副本保留在基准内以便复现同轮 A/B。
- **P1-5 已落地**：分析 walker 改用 `BroomFileSystem` 并优先 `DetailedDirectoryListing`，访问者签名改为 `(String, FsStat)`；`AnalysisService` 在根 isolate 探测原生枚举并通过 `RootIsolateToken` 在分析 isolate 初始化 messenger，失败时回退 `list + stat`。详细枚举路径下每文件 `stat` 从 1 次降为 0（3 个文件对应 2 次 `listDetailed` + 0 次 `stat`），回退路径保持 N 次 `stat` 与错误计数。新增 7 项回归用例，全量 410 项测试与 `flutter analyze --fatal-infos` 通过。
- **P1-6 + P1-7 已落地**：`JunkItem` 改为 `rootIndex` + `modifiedMicros`，新增 `ScanRoots` 根表并贯穿扫描（含 worker 的 `rootIndexBase`）、持久化、UI 与清理服务；删除 `_itemsByPath` / `_itemLocations`，锁探测改报全局条目下标；`items.jsonl` 格式与 `schemaVersion` 不变，加载时重建根表。去重集合改用 62 位 FNV-1a 指纹，同时覆盖 `ScanService._seenPaths` 与 `JunkScanner.seen`。1M 条基准：条目 226–228 → 89–91 MiB，单处去重集合 80–95 → 19–31 MiB。新增 `benchmark/item_memory_benchmark.dart`、`test/path_fingerprint_test.dart` 与多根扫描用例，全量 413 项测试与 `flutter analyze --fatal-infos` 通过。
- 记录一处方向性修正：装饰-排序并非对所有排序都更快。数值键本来就在条目上，装饰只是多出 O(N) 次分配，`sizeDesc` 实测因此从 46.4 涨到 63.5 ms。收益成立的区间是"派生键比分配贵得多"（`pathAsc`、`extensionAsc`）与"键大量并列"（惰性缓存生效）。全量 403 项测试与 `flutter analyze --fatal-infos` 通过。
- 评审过程中修正了一个判断：最初按单价推算认为"清理时间几乎全花在重复元数据查询上"，端到端 A/B 证明元数据只占约 12%，rename 与文件读取才是主体。文档中的收益数字以实测为准，未采用推算值。
- 另一处修正：P0-1 时的单步归因把约 1,000 µs 记为"其余未归因"，其中相当一部分并非散落在循环里，而是两项此前没被列入分解的操作——`finalize` 阶段的逐条 `type()` 与清理计划文件的逐条写入。这说明"按已知项求和再取差额"容易把整类操作漏在统计口径之外，凡涉及归因应以"每一次调用都有账"的方式重做。
- 方法上的修正：改造前后各跑一次端到端在这台机器上不可用（相邻运行之间未改动的 rename 单项波动可达 30%）。后续所有 A/B 都改为"调用次数 + 同轮交错计时"，端到端总时长只用于判断量级。
