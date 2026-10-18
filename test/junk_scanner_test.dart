import 'dart:io';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeNtfsIndex implements NtfsIndex {
  _FakeNtfsIndex({this.paths = const [], this.error});

  final List<String> paths;
  final Object? error;
  int probes = 0;
  int enumerations = 0;

  @override
  Future<NtfsIndexAvailability> probe(String root) async {
    probes++;
    return const NtfsIndexAvailability.available();
  }

  @override
  Stream<NtfsIndexEntry> enumerate(
    String root, {
    Set<String>? extensions,
    int? maxItems,
    bool Function()? isCancelled,
  }) {
    enumerations++;
    if (error != null) return Stream<NtfsIndexEntry>.error(error!);
    return Stream<NtfsIndexEntry>.fromIterable(paths.map(NtfsIndexEntry.new));
  }
}

void main() {
  late Directory temp;
  late Directory root;
  late DateTime now;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_scanner_');
    root = Directory(p.windows.join(temp.path, 'root'));
    await root.create(recursive: true);
    now = DateTime.now();
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<File> createFile(
    Directory base,
    String relative,
    String content, {
    Duration age = Duration.zero,
  }) async {
    final file = File(p.windows.join(base.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    if (age > Duration.zero) {
      await file.setLastModified(now.subtract(age));
    }
    return file;
  }

  test(
    'finds old files, applies age, and skips excluded directories',
    () async {
      final oldFile = await createFile(
        root,
        'old.tmp',
        'old-file',
        age: const Duration(days: 2),
      );
      final nestedOld = await createFile(
        root,
        p.join('nested', 'old.log'),
        'old-log',
        age: const Duration(days: 3),
      );
      await createFile(root, 'fresh.tmp', 'fresh');
      final excluded = Directory(p.windows.join(root.path, 'excluded'));
      await createFile(
        excluded,
        'still-old.tmp',
        'excluded',
        age: const Duration(days: 5),
      );

      final scanner = JunkScanner(
        jobs: [
          ScanJob(
            ruleId: 'test.temp',
            roots: [root.path],
            minAge: const Duration(hours: 24),
          ),
        ],
        excludedPaths: [excluded.path],
        clock: () => now,
      );
      final progress = <ScanProgress>[];

      final result = await scanner.scan(onProgress: progress.add);

      expect(result.cancelled, isFalse);
      expect(result.truncated, isFalse);
      expect(
        result.items.map((item) => item.path),
        unorderedEquals([oldFile.path, nestedOld.path]),
      );
      expect(result.items.every((item) => item.rootPath == root.path), isTrue);
      expect(result.items.every((item) => item.ruleId == 'test.temp'), isTrue);
      expect(progress, isNotEmpty);
      expect(progress.last.foundFiles, 2);
    },
  );

  test('filters by extension', () async {
    await createFile(root, 'old.tmp', 'old-file', age: const Duration(days: 2));
    await createFile(
      root,
      p.join('nested', 'dump.dmp'),
      'old-dump',
      age: const Duration(days: 2),
    );

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.dumps', roots: [root.path], extensions: {'dmp'}),
      ],
      clock: () => now,
    );
    final result = await scanner.scan();

    expect(result.items, hasLength(1));
    expect(p.windows.basename(result.items.single.path), 'dump.dmp');
  });

  test('skips paths claimed by another job through excludedRoots', () async {
    final broad = await createFile(
      root,
      'broad.tmp',
      'broad',
      age: const Duration(days: 2),
    );
    final claimedRoot = Directory(p.windows.join(root.path, 'claimed'));
    final claimed = await createFile(
      claimedRoot,
      'old.tmp',
      'claimed',
      age: const Duration(days: 2),
    );

    final scanner = JunkScanner(
      jobs: [
        ScanJob(
          ruleId: 'test.broad',
          roots: [root.path],
          excludedRoots: [claimedRoot.path],
        ),
        ScanJob(ruleId: 'test.claimed', roots: [claimedRoot.path]),
      ],
      clock: () => now,
    );
    final result = await scanner.scan();

    expect(result.items, hasLength(2));
    final byPath = {for (final item in result.items) item.path: item.ruleId};
    expect(byPath[broad.path], 'test.broad');
    expect(byPath[claimed.path], 'test.claimed');
  });

  test('deduplicates files matched by overlapping jobs', () async {
    await createFile(root, 'a.tmp', 'a', age: const Duration(days: 2));
    await createFile(root, 'b.tmp', 'b', age: const Duration(days: 2));

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.one', roots: [root.path]),
        ScanJob(ruleId: 'test.two', roots: [root.path]),
      ],
      clock: () => now,
    );
    final result = await scanner.scan();

    expect(result.items, hasLength(2));
    expect(result.items.map((item) => item.path).toSet(), hasLength(2));
  });

  test('stops at the configured item limit', () async {
    await createFile(root, 'a.tmp', 'a', age: const Duration(days: 2));
    await createFile(root, 'b.tmp', 'b', age: const Duration(days: 2));

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.one', roots: [root.path]),
      ],
      maxItems: 1,
      clock: () => now,
    );
    final result = await scanner.scan();

    expect(result.truncated, isTrue);
    expect(result.items, hasLength(1));
  });

  test('reports cancellation without visiting files', () async {
    await createFile(root, 'a.tmp', 'a', age: const Duration(days: 2));

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.one', roots: [root.path]),
      ],
      clock: () => now,
    );
    final result = await scanner.scan(isCancelled: () => true);

    expect(result.cancelled, isTrue);
    expect(result.items, isEmpty);
  });

  test('has no fixed item cap unless the caller configures one', () async {
    for (var index = 0; index < 5; index++) {
      await createFile(
        root,
        'file-$index.tmp',
        'x',
        age: const Duration(days: 1),
      );
    }

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.one', roots: [root.path]),
      ],
      clock: () => now,
    );
    expect(scanner.maxItems, isNull);
    final result = await scanner.scan();
    expect(result.truncated, isFalse);
    expect(result.items, hasLength(5));
  });

  test('streams batches without retaining every item', () async {
    for (var index = 0; index < 5; index++) {
      await createFile(
        root,
        'stream-$index.tmp',
        'x',
        age: const Duration(days: 1),
      );
    }

    final batches = <List<JunkItem>>[];
    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.one', roots: [root.path]),
      ],
      batchSize: 2,
      clock: () => now,
    );
    final result = await scanner.scan(retainItems: false, onItems: batches.add);

    expect(result.items, isEmpty);
    expect(result.scannedFiles, 5);
    expect(result.directoryErrors, 0);
    expect(batches.expand((batch) => batch), hasLength(5));
    expect(batches.first, hasLength(2));
    expect(batches.last, hasLength(1));
  });

  test('uses the NTFS index stream instead of walking the directory', () async {
    final indexed = await createFile(
      root,
      'indexed.tmp',
      'x',
      age: const Duration(days: 1),
    );
    await createFile(root, 'walked.tmp', 'x', age: const Duration(days: 1));
    final index = _FakeNtfsIndex(paths: [indexed.path]);

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.index', roots: [root.path]),
      ],
      ntfsIndex: index,
      useNtfsIndex: true,
      clock: () => now,
    );
    final result = await scanner.scan();

    expect(index.probes, 1);
    expect(index.enumerations, 1);
    expect(result.items, hasLength(1));
    expect(result.items.single.path, indexed.path);
  });

  test('falls back to directory traversal when the index fails', () async {
    final first = await createFile(
      root,
      'first.tmp',
      'x',
      age: const Duration(days: 1),
    );
    final second = await createFile(
      root,
      'second.tmp',
      'x',
      age: const Duration(days: 1),
    );
    final index = _FakeNtfsIndex(error: StateError('usn failed'));

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.index', roots: [root.path]),
      ],
      ntfsIndex: index,
      useNtfsIndex: true,
      clock: () => now,
    );
    final result = await scanner.scan();

    expect(
      result.items.map((item) => item.path),
      unorderedEquals([first.path, second.path]),
    );
    expect(result.issues, isNotEmpty);
    expect(result.issues.first.message, contains('回退'));
  });

  test('skips index entries outside the job root', () async {
    final file = await createFile(
      root,
      'inside.tmp',
      'x',
      age: const Duration(days: 1),
    );
    final outside = File(p.windows.join(temp.path, 'outside.tmp'));
    await outside.writeAsString('x');
    final index = _FakeNtfsIndex(paths: [file.path, outside.path]);

    final scanner = JunkScanner(
      jobs: [
        ScanJob(ruleId: 'test.index', roots: [root.path]),
      ],
      ntfsIndex: index,
      useNtfsIndex: true,
      clock: () => now,
    );
    final result = await scanner.scan();

    expect(result.items, hasLength(1));
    expect(result.items.single.path, file.path);
  });
}
