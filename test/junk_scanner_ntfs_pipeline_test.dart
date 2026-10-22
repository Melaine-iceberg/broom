import 'dart:async';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:flutter_test/flutter_test.dart';

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

class _DelayedStatFileSystem extends MemoryFileSystem {
  _DelayedStatFileSystem({this.delay = Duration.zero});

  final Duration delay;
  final List<String> statPaths = [];
  int completed = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<FsStat> stat(String path) async {
    statPaths.add(path);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(delay);
      final stat = await super.stat(path);
      completed++;
      return stat;
    } finally {
      inFlight--;
    }
  }
}

void main() {
  const root = r'C:\Cache';
  final clock = DateTime(2026, 10, 19);

  JunkScanner scannerFor({
    required _DelayedStatFileSystem fs,
    required List<String> paths,
    Set<String>? extensions,
    int? maxItems,
    Duration minAge = Duration.zero,
  }) {
    return JunkScanner(
      jobs: [
        ScanJob(
          ruleId: 'index',
          roots: const [root],
          extensions: extensions,
          minAge: minAge,
        ),
      ],
      ntfsIndex: _StaticNtfsIndex(paths),
      useNtfsIndex: true,
      fileSystem: fs,
      semantics: const WindowsPathSemantics(),
      maxItems: maxItems,
      clock: () => clock,
    );
  }

  test('indexed entries stat through the concurrent pipeline', () async {
    final fs = _DelayedStatFileSystem(delay: const Duration(milliseconds: 2));
    final paths = <String>[];
    for (var index = 0; index < 64; index++) {
      paths.add(
        fs.seedFile(
          'C:\\Cache\\file$index.tmp',
          size: index + 1,
          modified: DateTime(2026, 1, 1),
        ),
      );
    }

    final result = await scannerFor(fs: fs, paths: paths).scan();

    expect(result.items, hasLength(64));
    expect(result.scannedFiles, 64);
    expect(fs.statPaths, hasLength(64));
    expect(fs.maxInFlight, greaterThan(1));
    expect(fs.maxInFlight, lessThanOrEqualTo(defaultStatConcurrency));
  });

  test('filters indexed entries before issuing stat', () async {
    final fs = _DelayedStatFileSystem();
    final kept = fs.seedFile(
      'C:\\Cache\\keep.tmp',
      size: 10,
      modified: DateTime(2026, 1, 1),
    );
    final wrongExtension = fs.seedFile(
      'C:\\Cache\\skip.log',
      size: 20,
      modified: DateTime(2026, 1, 1),
    );
    final outsideRoot = fs.seedFile(
      'C:\\Other\\skip.tmp',
      size: 30,
      modified: DateTime(2026, 1, 1),
    );

    final result = await scannerFor(
      fs: fs,
      paths: [kept, wrongExtension, outsideRoot],
      extensions: const {'tmp'},
    ).scan();

    expect(result.items.single.path, kept);
    expect(result.items.single.size, 10);
    expect(result.scannedFiles, 1);
    expect(fs.statPaths, [kept]);
  });

  test('indexed scan keeps the age filter and item cap', () async {
    final fs = _DelayedStatFileSystem();
    final paths = <String>[];
    for (var index = 0; index < 8; index++) {
      paths.add(
        fs.seedFile(
          'C:\\Cache\\old$index.tmp',
          size: 10,
          modified: DateTime(2026, 1, 1),
        ),
      );
    }
    paths.add(
      fs.seedFile(
        'C:\\Cache\\fresh.tmp',
        size: 10,
        modified: DateTime(2026, 10, 19),
      ),
    );

    final aged = await scannerFor(
      fs: fs,
      paths: paths,
      minAge: const Duration(hours: 24),
    ).scan();
    expect(aged.items, hasLength(8));

    final capped = await scannerFor(
      fs: fs,
      paths: paths,
      minAge: const Duration(hours: 24),
      maxItems: 3,
    ).scan();
    expect(capped.truncated, isTrue);
    expect(capped.items, hasLength(3));
  });

  test('reports indexed entries that disappear before stat', () async {
    final fs = _DelayedStatFileSystem();
    final kept = fs.seedFile(
      'C:\\Cache\\kept.tmp',
      size: 10,
      modified: DateTime(2026, 1, 1),
    );
    const vanished = r'C:\Cache\vanished.tmp';

    final result = await scannerFor(fs: fs, paths: [kept, vanished]).scan();

    expect(result.items.single.path, kept);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.path, vanished);
  });

  test('stops stat-ing the remaining batch after cancellation', () async {
    final fs = _DelayedStatFileSystem(delay: const Duration(milliseconds: 1));
    final paths = <String>[];
    for (var index = 0; index < 64; index++) {
      paths.add(
        fs.seedFile(
          'C:\\Cache\\file$index.tmp',
          size: 10,
          modified: DateTime(2026, 1, 1),
        ),
      );
    }

    final scanner = JunkScanner(
      jobs: const [
        ScanJob(ruleId: 'index', roots: [root], extensions: {'tmp'}),
      ],
      ntfsIndex: _StaticNtfsIndex(paths),
      useNtfsIndex: true,
      fileSystem: fs,
      semantics: const WindowsPathSemantics(),
      clock: () => clock,
    );
    final result = await scanner.scan(
      isCancelled: () => fs.completed >= defaultStatConcurrency,
    );

    expect(result.cancelled, isTrue);
    expect(result.items, isNotEmpty);
    expect(result.items.length, lessThan(paths.length));
    expect(fs.completed, lessThan(paths.length));
  });
}
