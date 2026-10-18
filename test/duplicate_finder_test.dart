import 'dart:io';

import 'package:broom/core/analysis/duplicate_finder.dart';
import 'package:broom/core/models/analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom-duplicates-');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  File write(String relativePath, String content) {
    final file = File(p.normalize(p.join(temp.path, relativePath)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  test(
    'groups byte-identical files and skips same-size different content',
    () async {
      final first = write('a.txt', 'duplicate-content');
      final second = write('nested/b.txt', 'duplicate-content');
      write('c.txt', 'different-content');
      write('tiny.txt', 'dup');
      write('empty.txt', '');

      final report = await DuplicateFinder(
        root: temp.path,
        minFileSize: 4,
        partialChunkSize: 8,
      ).scan();

      expect(report.cancelled, isFalse);
      expect(report.truncated, isFalse);
      expect(report.groups, hasLength(1));
      expect(report.groupCount, 1);
      expect(report.redundantFileCount, 1);
      expect(report.duplicateFileCount, 2);
      expect(report.reclaimableBytes, 'duplicate-content'.length);
      expect(report.groups.single.files.map((file) => file.path).toSet(), {
        first.path,
        second.path,
      });
      expect(report.groups.single.size, 'duplicate-content'.length);
      expect(report.scannedFiles, 5);
    },
  );

  test('honors the minimum file size threshold', () async {
    write('a.txt', 'same');
    write('b.txt', 'same');

    final report = await DuplicateFinder(
      root: temp.path,
      minFileSize: 10,
      partialChunkSize: 4,
    ).scan();

    expect(report.groups, isEmpty);
    expect(report.scannedFiles, 2);
  });

  test('ignores excluded subtrees', () async {
    write('keep/a.txt', 'excluded-content');
    write('keep/b.txt', 'excluded-content');
    write('other/c.txt', 'different-content');
    final excluded = p.join(temp.path, 'keep');

    final report = await DuplicateFinder(
      root: temp.path,
      minFileSize: 1,
      partialChunkSize: 8,
      excludedPaths: [excluded],
    ).scan();

    expect(report.groups, isEmpty);
    expect(report.scannedFiles, 1);
  });

  test('reports cancellation without returning partial groups', () async {
    write('a.txt', 'duplicate-content');
    write('b.txt', 'duplicate-content');

    var checks = 0;
    final report = await DuplicateFinder(
      root: temp.path,
      minFileSize: 1,
      partialChunkSize: 8,
    ).scan(isCancelled: () => ++checks > 2);

    expect(report.cancelled, isTrue);
    expect(report.groups, isEmpty);
  });

  test('throws a readable error when the root does not exist', () async {
    final missing = p.join(temp.path, 'does-not-exist');

    await expectLater(
      DuplicateFinder(root: missing, minFileSize: 1).scan(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('目录不存在'),
        ),
      ),
    );
  });

  test('reports scanning and comparing progress', () async {
    write('a.txt', 'duplicate-content');
    write('b.txt', 'duplicate-content');

    final progress = <DuplicateProgress>[];
    await DuplicateFinder(
      root: temp.path,
      minFileSize: 1,
      partialChunkSize: 8,
    ).scan(onProgress: progress.add);

    expect(
      progress.any((event) => event.phase == AnalysisPhase.scanning),
      isTrue,
    );
    expect(
      progress.any((event) => event.phase == AnalysisPhase.comparing),
      isTrue,
    );
    final comparing = progress.last;
    expect(comparing.processedFiles, comparing.totalFiles);
    expect(comparing.fraction, 1);
  });
}
