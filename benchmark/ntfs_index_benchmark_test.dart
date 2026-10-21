// A/B benchmark for the NTFS-index scan path (P0-2 in docs/perf-review.md).
//
// The USN index itself is faked: the native enumeration is not what this
// measures. Every indexed path points at a real file, so each candidate pays a
// real `FileStat.stat`. The same scanner runs with different
// `statConcurrency` values; 1 reproduces the pre-P0-2 serial loop, 8 is the
// directory walk's pipeline width.
//
// Run manually; `flutter test` only scans `test/`, so this never runs in CI:
//
//   flutter test benchmark/ntfs_index_benchmark_test.dart
//
// Files are created under the system temporary directory and removed
// afterwards.

import 'dart:io';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _fileCount = 20000;
const _rounds = 3;
const _widths = [1, 2, 4, 8];

void main() {
  test('NTFS index stat pipeline A/B', () async {
    final root = await Directory.systemTemp.createTemp('broom_ntfs_bench_');
    try {
      final setup = Stopwatch()..start();
      final paths = await _seedFiles(root.path, _fileCount);
      setup.stop();
      stdout.writeln(
        'seeded ${paths.length} files in ${setup.elapsedMilliseconds} ms',
      );

      final index = _StaticNtfsIndex(paths);
      for (final width in _widths) {
        await _scan(index: index, root: root.path, concurrency: width);
      }

      final samples = {for (final width in _widths) width: <Duration>[]};
      for (var round = 0; round < _rounds; round++) {
        final order = round.isEven ? _widths : _widths.reversed.toList();
        for (final width in order) {
          samples[width]!.add(
            await _scan(index: index, root: root.path, concurrency: width),
          );
        }
      }

      _report(samples, paths.length);
    } finally {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // Leaving a temp directory behind is harmless.
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<Duration> _scan({
  required NtfsIndex index,
  required String root,
  required int concurrency,
}) async {
  final scanner = JunkScanner(
    jobs: [
      ScanJob(ruleId: 'bench.ntfs', roots: [root], extensions: const {'tmp'}),
    ],
    ntfsIndex: index,
    useNtfsIndex: true,
    statConcurrency: concurrency,
  );
  final stopwatch = Stopwatch()..start();
  final result = await scanner.scan(retainItems: false);
  stopwatch.stop();
  if (result.scannedFiles != _fileCount || result.issues.isNotEmpty) {
    throw StateError(
      'scan scanned=${result.scannedFiles} issues=${result.issues.length}',
    );
  }
  return stopwatch.elapsed;
}

Future<List<String>> _seedFiles(String root, int count) async {
  const directoryCount = 40;
  final perDirectory = (count / directoryCount).ceil();
  final paths = <String>[];
  for (var directory = 0; directory < directoryCount; directory++) {
    if (paths.length >= count) break;
    final target = Directory(p.join(root, 'd$directory'));
    await target.create();
    for (var file = 0; file < perDirectory; file++) {
      if (paths.length >= count) break;
      final path = p.join(target.path, 'f$file.tmp');
      // Non-empty so the size is real rather than a filesystem special case.
      await File(path).writeAsBytes(const [0, 1, 2, 3], flush: false);
      paths.add(path);
    }
  }
  return paths;
}

void _report(Map<int, List<Duration>> samples, int fileCount) {
  final reference = _median(samples[_widths.first]!);
  stdout.writeln('SCAN [ntfs index, $fileCount real files, $_rounds rounds]');
  stdout.writeln('  concurrency  median       µs/file  files/s  vs serial');
  for (final entry in samples.entries) {
    final median = _median(entry.value);
    final microsPerFile = median.inMicroseconds / fileCount;
    final filesPerSecond = (fileCount * 1000000 / median.inMicroseconds)
        .round();
    final speedup = reference.inMicroseconds / median.inMicroseconds;
    stdout.writeln(
      '  ${entry.key.toString().padLeft(11)}  '
      '${median.inMilliseconds.toString().padLeft(7)} ms  '
      '${microsPerFile.toStringAsFixed(1).padLeft(8)}  '
      '${filesPerSecond.toString().padLeft(7)}  '
      '${speedup.toStringAsFixed(2)}x',
    );
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

class _StaticNtfsIndex implements NtfsIndex {
  _StaticNtfsIndex(this.paths);

  final List<String> paths;

  @override
  Future<NtfsIndexAvailability> probe(String root) async =>
      const NtfsIndexAvailability.available();

  @override
  Stream<NtfsIndexEntry> enumerate(
    String root, {
    Set<String>? extensions,
    int? maxItems,
    bool Function()? isCancelled,
  }) {
    return Stream<NtfsIndexEntry>.fromIterable(paths.map(NtfsIndexEntry.new));
  }
}
