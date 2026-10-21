// UI preview aggregation, sorting and extension benchmark (P0-3, P0-4 and
// P2-11 in docs/perf-review.md).
//
// Measures the costs the preview page used to pay on every rebuild:
//
//   1. the O(N) selection aggregates (`selectedBytes`,
//      `selectedPossiblyLockedCount`, `selectedBytesForRule`),
//   2. filtering + sorting one rule's items for display, and
//   3. scanning every item for the extension filter menu on page open.
//
// The "legacy" rows are verbatim copies of the pre-optimisation code, kept
// here as a reference so the comparison stays reproducible after the
// production code moved on. Run manually; `flutter test` only scans `test/`,
// so this never runs in CI:
//
//   dart run benchmark/ui_preview_benchmark.dart
//   dart run benchmark/ui_preview_benchmark.dart --items=1000000
//
// Everything is synthetic: no disk access, no real user data.

import 'dart:io';
import 'dart:math';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/ui/result_filters.dart';
import 'package:path/path.dart' as p;

const _defaultItemCount = 100000;
const _rounds = 5;

void main(List<String> args) {
  final itemCount = _intArg(args, '--items') ?? _defaultItemCount;
  final items = _buildItems(itemCount);
  stdout.writeln('Broom UI preview benchmark');
  stdout.writeln(
    'Dart ${Platform.version.split(' ').first}, '
    '${Platform.numberOfProcessors} logical processors, '
    '$itemCount items',
  );
  stdout.writeln('');

  _benchmarkAggregates(items);
  stdout.writeln('');
  _benchmarkVisibleList(items);
  stdout.writeln('');
  _benchmarkExtensions(items);
  stdout.writeln('');
  stdout.writeln(
    '以上是 $itemCount 条目的纯 CPU 成本，不含 Flutter 布局与绘制。'
    '（校验和 $_sink，仅用于阻止循环体被消除。）',
  );
}

void _benchmarkAggregates(List<JunkItem> items) {
  final selectedPaths = <String>{for (final item in items) item.path};

  int legacySelectedBytes() => _legacySelectedItems(
    items,
    selectedPaths,
  ).fold(0, (total, item) => total + item.size);
  int legacySelectedLocked() {
    var count = 0;
    for (final item in items) {
      if (item.possiblyLocked && selectedPaths.contains(item.path)) count++;
    }
    return count;
  }

  int legacyBytesForRule() {
    var total = 0;
    for (final item in items) {
      if (selectedPaths.contains(item.path)) total += item.size;
    }
    return total;
  }

  stdout.writeln('选择聚合（每次 build，全部条目被选中）');
  _row('selectedBytes（旧：先分配全长列表再 fold）', _time(legacySelectedBytes));
  _row('selectedPossiblyLockedCount（旧：双层循环）', _time(legacySelectedLocked));
  _row('selectedBytesForRule（旧：单规则全量）', _time(legacyBytesForRule));
  // The new implementation reads fields maintained by the write paths, so the
  // row measures the getters themselves rather than a recomputation.
  final aggregates = _IncrementalAggregates(
    selectedBytes: legacySelectedBytes(),
    selectedLocked: legacySelectedLocked(),
    selectedBytesForRule: legacyBytesForRule(),
  );
  _row(
    '三个 getter（新：O(1) 字段读取）',
    _time(() {
      _sink =
          aggregates.selectedBytes +
          aggregates.selectedLocked +
          aggregates.selectedBytesForRule;
    }),
  );
}

void _benchmarkVisibleList(List<JunkItem> items) {
  const empty = ResultItemFilter();
  stdout.writeln('可见列表（单条规则，十万级）');
  stdout.writeln(
    '  （体积/时间序直接比较条目字段，仅在键相等时缓存小写路径；'
    '路径/扩展名序先为每条派生一次键。）',
  );

  _row(
    'filterResultItems（旧：空过滤，仍全量复制）',
    _time(() => _sink = _legacyFilter(items, empty).length),
  );
  for (final sort in [
    ResultItemSort.sizeDesc,
    ResultItemSort.pathAsc,
    ResultItemSort.extensionAsc,
  ]) {
    _row(
      'sortResultItems/$sort（旧）',
      _time(() => _sink = _legacySort(items, sort).length),
    );
    _row(
      'sortResultItems/$sort（新）',
      _time(() => _sink = sortResultItems(items, sort).length),
    );
  }

  _row(
    'filter + sort（旧：每次重建都重算）',
    _time(
      () => _sink = _legacySort(
        _legacyFilter(items, empty),
        ResultItemSort.sizeDesc,
      ).length,
    ),
  );

  final cache = VisibleItemsCache();
  // Warm the cache with the arguments the page passes on every rebuild.
  cache.resolve(items, empty, ResultItemSort.sizeDesc, version: 1);
  final warmCount = cache.recomputeCount;
  _row(
    'filter + sort（新：缓存命中）',
    _time(
      () => _sink = cache
          .resolve(items, empty, ResultItemSort.sizeDesc, version: 1)
          .length,
    ),
  );
  stdout.writeln('  └ 缓存重算次数：预热 $warmCount → 命中阶段 ${cache.recomputeCount}');

  final misses = VisibleItemsCache();
  _row(
    'filter + sort（新：每次换 filter，未命中）',
    _time(
      () => _sink = misses
          .resolve(
            items,
            ResultItemFilter(query: _nextQuery()),
            ResultItemSort.sizeDesc,
            version: 1,
          )
          .length,
    ),
  );

  // Cache garbage is dominated by equal-sized fragments, so the tie-breaker
  // decides the whole order there. That is the case the lazy lowercase cache
  // in _sortByOrdinal exists for.
  final ties = [
    for (final item in items)
      JunkItem(
        rootIndex: item.rootIndex,
        path: item.path,
        size: 4096,
        modifiedMicros: item.modifiedMicros,
      ),
  ];
  _row(
    'sortResultItems/sizeDesc 全同体积（旧）',
    _time(() => _sink = _legacySort(ties, ResultItemSort.sizeDesc).length),
  );
  _row(
    'sortResultItems/sizeDesc 全同体积（新）',
    _time(() => _sink = sortResultItems(ties, ResultItemSort.sizeDesc).length),
  );
}

void _benchmarkExtensions(List<JunkItem> items) {
  stdout.writeln('扩展名集合（规则详情页打开筛选对话框）');

  _row(
    'availableExtensions（旧：打开页面时全量扫描）',
    _time(() => _sink = _legacyAvailableExtensions(items).length),
  );

  final extensions = <String>{};
  _row(
    '增量维护（新：扫描/恢复时每条一次 Set.add）',
    _time(() {
      extensions.clear();
      for (final item in items) {
        final extension = extensionOfPath(item.path);
        if (extension.isNotEmpty) extensions.add(extension);
      }
      _sink = extensions.length;
    }),
  );

  final sorted = List<String>.unmodifiable(extensions.toList()..sort());
  _row('打开页面（新：读取 RuleResult.extensions）', _time(() => _sink = sorted.length));
}

class _IncrementalAggregates {
  const _IncrementalAggregates({
    required this.selectedBytes,
    required this.selectedLocked,
    required this.selectedBytesForRule,
  });

  final int selectedBytes;
  final int selectedLocked;
  final int selectedBytesForRule;
}

int _sink = 0;

int _queryCounter = 0;
String _nextQuery() => 'nomatch${_queryCounter++}';

/// Milliseconds per call, median of [_rounds].
double _time(void Function() body) {
  final samples = <double>[];
  for (var round = 0; round < _rounds; round++) {
    final watch = Stopwatch()..start();
    body();
    watch.stop();
    samples.add(watch.elapsedMicroseconds / 1000);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

void _row(String label, double milliseconds) {
  stdout.writeln(
    '  ${label.padRight(52)}${milliseconds.toStringAsFixed(3).padLeft(9)} ms',
  );
}

List<JunkItem> _buildItems(int count) {
  final random = Random(17);
  const extensions = ['tmp', 'log', 'bin', 'dat', 'cache'];
  const folders = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
  return [
    for (var index = 0; index < count; index++)
      JunkItem(
        rootIndex: 0,
        path:
            'C:\\Users\\Bench\\AppData\\Local\\Temp\\'
            '${folders[index % folders.length]}\\sub${index % 97}\\'
            'file-$index.${extensions[index % extensions.length]}',
        size: random.nextInt(8 * 1024 * 1024),
        modifiedMicros: DateTime(
          2026,
          1,
          1,
        ).add(Duration(hours: random.nextInt(8000))).microsecondsSinceEpoch,
        possiblyLocked: index % 20 == 0,
      ),
  ];
}

// ---------------------------------------------------------------------------
// Reference copies of the pre-optimisation implementations.

List<String> _legacyAvailableExtensions(List<JunkItem> items) {
  final extensions = <String>{};
  for (final item in items) {
    final name = p.windows.basename(item.path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) continue;
    extensions.add(name.substring(dot + 1).toLowerCase());
  }
  return extensions.toList()..sort();
}

List<JunkItem> _legacySelectedItems(
  List<JunkItem> items,
  Set<String> selectedPaths,
) {
  return [
    for (final item in items)
      if (selectedPaths.contains(item.path)) item,
  ];
}

List<JunkItem> _legacyFilter(List<JunkItem> items, ResultItemFilter filter) {
  final query = filter.query.trim().toLowerCase();
  final wantedExtension = filter.extension?.toLowerCase();
  final clock = DateTime.now().microsecondsSinceEpoch;
  return [
    for (final item in items)
      if ((query.isEmpty || item.path.toLowerCase().contains(query)) &&
          (wantedExtension == null ||
              extensionOfPath(item.path) == wantedExtension) &&
          item.size >= filter.minimumSize &&
          (filter.olderThan == null ||
              clock - item.modifiedMicros >=
                  filter.olderThan!.inMicroseconds) &&
          (!filter.lockedOnly || item.possiblyLocked))
        item,
  ];
}

List<JunkItem> _legacySort(List<JunkItem> items, ResultItemSort sort) {
  final copy = List<JunkItem>.of(items);
  int comparison(JunkItem a, JunkItem b) {
    switch (sort) {
      case ResultItemSort.sizeDesc:
        return b.size.compareTo(a.size);
      case ResultItemSort.sizeAsc:
        return a.size.compareTo(b.size);
      case ResultItemSort.modifiedDesc:
        return b.modifiedMicros.compareTo(a.modifiedMicros);
      case ResultItemSort.modifiedAsc:
        return a.modifiedMicros.compareTo(b.modifiedMicros);
      case ResultItemSort.pathAsc:
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      case ResultItemSort.extensionAsc:
        final byExtension = extensionOfPath(a.path)
            .compareTo(extensionOfPath(b.path));
        if (byExtension != 0) return byExtension;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    }
  }

  copy.sort((a, b) {
    final result = comparison(a, b);
    if (result != 0) return result;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  return copy;
}

int? _intArg(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) {
      return int.tryParse(arg.substring(name.length + 1));
    }
  }
  return null;
}
