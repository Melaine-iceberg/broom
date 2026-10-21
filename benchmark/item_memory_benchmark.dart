import 'dart:io';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/path_fingerprint.dart';

/// Measures the per-item and dedupe-set savings from the P1-6 / P1-7 work.
///
/// Run one mode per process so RSS reflects only that allocation:
///   dart run benchmark/item_memory_benchmark.dart legacy --count=1000000
///   dart run benchmark/item_memory_benchmark.dart compact --count=1000000
///   dart run benchmark/item_memory_benchmark.dart seen-strings --count=1000000
///   dart run benchmark/item_memory_benchmark.dart seen-fingerprints --count=1000000
Future<void> main(List<String> args) async {
  final mode = args.firstWhere(
    (arg) => !arg.startsWith('--'),
    orElse: () => 'compact',
  );
  final count = int.parse(
    args
        .firstWhere(
          (arg) => arg.startsWith('--count='),
          orElse: () => '--count=1000000',
        )
        .substring('--count='.length),
  );

  final paths = mode.startsWith('seen-')
      ? [for (var index = 0; index < count; index++) _path(index)]
      : const <String>[];
  final before = ProcessInfo.currentRss;
  final Object result = switch (mode) {
    'legacy' => _buildLegacy(count),
    'compact' => _buildCompact(count),
    'seen-strings' => _buildSeenStrings(paths),
    'seen-fingerprints' => _buildSeenFingerprints(paths),
    _ => throw ArgumentError.value(mode, 'mode'),
  };
  final after = ProcessInfo.currentRss;
  stdout.writeln(
    '$mode count=$count '
    'delta=${(after - before) ~/ (1024 * 1024)}MiB '
    'size=${result is Set ? result.length : (result as List).length}',
  );
}

/// Pre-P1-6 shape, kept only so the benchmark can measure the comparison.
class _LegacyItem {
  _LegacyItem({
    required this.ruleId,
    required this.rootPath,
    required this.path,
    required this.size,
    required this.modified,
    required this.possiblyLocked,
  });

  final String ruleId;
  final String rootPath;
  final String path;
  final int size;
  final DateTime modified;
  final bool possiblyLocked;
}

String _path(int index) =>
    'C:\\Users\\Bench\\AppData\\Local\\Temp\\f${index % 8}\\'
    'sub${index % 97}\\file-$index.tmp';

List<Object> _buildLegacy(int count) {
  const ruleId = 'bench.rule';
  const rootPath = r'C:\Users\Bench\AppData\Local\Temp';
  final base = DateTime(2026, 1, 1);
  return [
    for (var index = 0; index < count; index++)
      _LegacyItem(
        ruleId: ruleId,
        rootPath: rootPath,
        path: _path(index),
        size: index * 37,
        modified: base.add(Duration(seconds: index)),
        possiblyLocked: index % 20 == 0,
      ),
  ];
}

List<Object> _buildCompact(int count) {
  final base = DateTime(2026, 1, 1).microsecondsSinceEpoch;
  return [
    for (var index = 0; index < count; index++)
      JunkItem(
        rootIndex: 0,
        path: _path(index),
        size: index * 37,
        modifiedMicros: base + index * 1000000,
        possiblyLocked: index % 20 == 0,
      ),
  ];
}

Set<String> _buildSeenStrings(List<String> paths) => {
  for (final path in paths) path.toLowerCase(),
};

Set<int> _buildSeenFingerprints(List<String> paths) => {
  for (final path in paths) pathFingerprint(path.toLowerCase()),
};
