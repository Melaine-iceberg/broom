import 'dart:io';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
}
