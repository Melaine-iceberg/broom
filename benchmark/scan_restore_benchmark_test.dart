// Restore benchmark for P2-8 (docs/perf-review.md).
//
// `ScanResultStore.load` now parses, filters, groups and sorts `items.jsonl`
// inside a worker isolate. This benchmark measures that load and the real
// `CleanController.restoreLastScan()` that follows it, so the remaining
// main-isolate work (default selection, summary folds, lock-probe path table)
// stays visible.
//
// The pre-change main-isolate vs worker A/B numbers are recorded in
// docs/perf-review.md; this file is the post-change regression baseline.
//
// Run manually; `flutter test` only scans `test/`, so this never runs in CI:
//
//   flutter test benchmark/scan_restore_benchmark_test.dart
//
// Result files are created under the system temporary directory and removed
// afterwards.

import 'dart:async';
import 'dart:io';

import 'package:broom/core/clean/file_metadata.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/file_lock_probe.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/scan_result_store.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _sizes = [100000, 1000000];
const _rounds = 3;
const _writeBatchSize = 2048;
const _ruleIds = [
  'browser.chrome',
  'browser.edge',
  'dev.dart',
  'app.temp',
  'system.cache',
  'logs.app',
  'thumbnails.cache',
  'gpu.shader',
];

void main() {
  test('restore parse + group benchmark', () async {
    final base = await Directory.systemTemp.createTemp('broom_restore_bench_');
    try {
      for (final count in _sizes) {
        final store = ScanResultStore(
          rootDirectory: p.join(base.path, 's$count'),
          semantics: const WindowsPathSemantics(),
        );
        final setup = Stopwatch()..start();
        final summary = await _writeResult(store, count);
        setup.stop();
        final file = File(
          p.join(store.rootDirectory, summary.id, 'items.jsonl'),
        );
        final mib = file.lengthSync() / (1024 * 1024);
        // Measure parsing, not first-touch disk reads.
        await file.openRead().drain<void>();

        final rules = [
          for (var index = 0; index < _ruleIds.length; index++)
            CleanerRule(
              id: _ruleIds[index],
              title: _ruleIds[index],
              category: 'bench',
              description: 'bench',
              pathPatterns: const [],
              risk: index.isEven ? CleanRisk.safe : CleanRisk.review,
            ),
        ];
        final controller = await _createController(
          store: store,
          rules: rules,
          basePath: p.join(base.path, 'c$count'),
        );
        final loads = <Duration>[];
        final restores = <Duration>[];
        final residuals = <Duration>[];
        try {
          for (var round = 0; round < _rounds; round++) {
            if (round.isEven) {
              final load = await _measuredLoad(store, summary, count);
              final restore = await _measuredRestore(controller, count);
              loads.add(load);
              restores.add(restore);
              residuals.add(restore - load);
            } else {
              final restore = await _measuredRestore(controller, count);
              final load = await _measuredLoad(store, summary, count);
              loads.add(load);
              restores.add(restore);
              residuals.add(restore - load);
            }
          }
        } finally {
          controller.dispose();
        }

        final loadMedian = _median(loads);
        final restoreMedian = _median(restores);
        final residualMedian = _median(residuals);
        stdout.writeln('');
        stdout.writeln(
          'RESTORE+GROUP [$count items, ${mib.toStringAsFixed(1)} MiB, '
          'setup ${setup.elapsedMilliseconds} ms]',
        );
        stdout.writeln('  load (isolate parse+group) : ${_ms(loadMedian)}');
        stdout.writeln('  full restore              : ${_ms(restoreMedian)}');
        stdout.writeln(
          '    selection + folds       : '
          '${residualMedian.isNegative ? 'within noise' : _ms(residualMedian)} '
          '(paired: full restore - load)',
        );
      }
    } finally {
      try {
        await base.delete(recursive: true);
      } on FileSystemException {
        // Leaving a temp directory behind is harmless.
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}

Future<Duration> _measuredLoad(
  ScanResultStore store,
  StoredScanSummary summary,
  int expected,
) async {
  final stopwatch = Stopwatch()..start();
  final data = await store.load(summary);
  stopwatch.stop();
  _expectCount(
    data?.groups.values.fold<int>(0, (total, group) => total + group.length),
    expected,
    'load',
  );
  for (final group in data!.groups.values) {
    for (var index = 1; index < group.length; index++) {
      if (group[index - 1].size < group[index].size) {
        throw StateError('group is not sorted by size');
      }
    }
  }
  return stopwatch.elapsed;
}

Future<Duration> _measuredRestore(
  CleanController controller,
  int expected,
) async {
  final stopwatch = Stopwatch()..start();
  await controller.restoreLastScan();
  stopwatch.stop();
  _expectCount(
    controller.results.fold<int>(
      0,
      (total, result) => total + result.items.length,
    ),
    expected,
    'restore',
  );
  return stopwatch.elapsed;
}

Future<StoredScanSummary> _writeResult(ScanResultStore store, int count) async {
  final roots = ScanRoots([
    for (final ruleId in _ruleIds)
      ScanRoot(
        ruleId: ruleId,
        rootPath: p.join(
          r'C:\Users\Bench\AppData\Local\Temp\cache',
          ruleId.replaceAll('.', '_'),
        ),
      ),
  ]);
  final writer = await store.begin(
    ruleIds: _ruleIds,
    rulesVersion: 'bench',
    roots: roots,
  );
  final baseTime = DateTime.utc(2026, 10, 1);
  var foundBytes = 0;
  final batch = <JunkItem>[];
  for (var index = 0; index < count; index++) {
    final rootIndex = index % roots.length;
    final root = roots.at(rootIndex);
    final size = (index * 7919) % 1048576 + 128;
    foundBytes += size;
    batch.add(
      JunkItem(
        rootIndex: rootIndex,
        path: p.join(
          root.rootPath,
          'd${(index ~/ 4096) % 64}',
          'file${index.toString().padLeft(10, '0')}.tmp',
        ),
        size: size,
        modifiedMicros: baseTime
            .add(Duration(seconds: index % 86400))
            .microsecondsSinceEpoch,
      ),
    );
    if (batch.length < _writeBatchSize) continue;
    await writer.addItems(batch);
    batch.clear();
  }
  if (batch.isNotEmpty) await writer.addItems(batch);
  return writer.complete(
    scannedFiles: count * 2,
    foundFiles: count,
    foundBytes: foundBytes,
    issueCount: 0,
    errorCounts: const {},
    truncated: false,
  );
}

Future<CleanController> _createController({
  required ScanResultStore store,
  required List<CleanerRule> rules,
  required String basePath,
}) async {
  final guard = PathGuard(protectedRoots: const []);
  final controller = CleanController(
    platform: _BenchPlatform(rules),
    guard: guard,
    quarantine: QuarantineService(
      quarantineRoot: p.join(basePath, 'quarantine'),
      guard: guard,
      metadataAccess: const LocalFileMetadataAccess(),
    ),
    exclusions: ExclusionStore(
      filePath: p.join(basePath, 'exclusions.json'),
    ),
    scanServiceFactory: ScanService.new,
    // Keeps the asynchronous probe from competing with the next measured
    // restore; building the path list is still part of restoreLastScan.
    lockProbe: const _HangingLockProbe(),
    scanResultStore: store,
  );
  await controller.initialize();
  return controller;
}

class _BenchPlatform implements CleanerPlatform {
  _BenchPlatform(this.rules);

  @override
  final List<CleanerRule> rules;

  @override
  String get displayName => 'bench';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  PathSemantics get pathSemantics => PathSemanticsFactory.forCurrentPlatform();

  @override
  List<String> get protectedRoots => const [];

  @override
  String? get quarantineRoot => null;

  @override
  String get rulesVersion => 'bench';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

class _HangingLockProbe implements FileLockProbe {
  const _HangingLockProbe();

  @override
  Future<List<bool>> probePossiblyLocked(List<String> paths) =>
      Completer<List<bool>>().future;
}

void _expectCount(int? actual, int expected, String label) {
  if (actual != expected) {
    throw StateError('$label parsed=$actual expected=$expected');
  }
}

Duration _median(List<Duration> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return Duration(
    microseconds:
        (sorted[middle - 1].inMicroseconds + sorted[middle].inMicroseconds) ~/
        2,
  );
}

String _ms(Duration value) => '${value.inMilliseconds} ms';
