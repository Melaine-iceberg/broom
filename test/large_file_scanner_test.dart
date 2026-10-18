import 'dart:io';

import 'package:broom/core/analysis/large_file_scanner.dart';
import 'package:broom/core/models/analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom-large-files-');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  File write(String relativePath, int bytes) {
    final file = File(p.normalize(p.join(temp.path, relativePath)));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
    return file;
  }

  test('filters by threshold and sorts matches by size', () async {
    final huge = write('media/huge.bin', 300);
    final medium = write('medium.bin', 150);
    write('small.bin', 20);

    final report = await LargeFileScanner(
      root: temp.path,
      minFileSize: 100,
    ).scan();

    expect(report.files.map((file) => file.path).toList(), [
      huge.path,
      medium.path,
    ]);
    expect(report.matchedCount, 2);
    expect(report.matchedBytes, 450);
    expect(report.scannedFiles, 3);
    expect(report.scannedBytes, 470);
    expect(report.cancelled, isFalse);
    expect(report.truncated, isFalse);
  });

  test('caps visible results while keeping totals', () async {
    write('a.bin', 100);
    write('b.bin', 200);
    write('c.bin', 300);

    final report = await LargeFileScanner(
      root: temp.path,
      minFileSize: 1,
      maxResults: 2,
    ).scan();

    expect(report.files, hasLength(2));
    expect(report.files.first.size, 300);
    expect(report.files.last.size, 200);
    expect(report.resultsCapped, isTrue);
    expect(report.matchedCount, 3);
    expect(report.matchedBytes, 600);
  });

  test('ignores excluded subtrees', () async {
    write('keep/huge.bin', 300);
    write('other/medium.bin', 200);
    final excluded = p.join(temp.path, 'keep');

    final report = await LargeFileScanner(
      root: temp.path,
      minFileSize: 1,
      excludedPaths: [excluded],
    ).scan();

    expect(report.files, hasLength(1));
    expect(report.files.single.path, contains('other'));
  });

  test('reports cancellation', () async {
    write('a.bin', 100);
    write('b.bin', 200);

    var checks = 0;
    final report = await LargeFileScanner(
      root: temp.path,
      minFileSize: 1,
    ).scan(isCancelled: () => ++checks > 2);

    expect(report.cancelled, isTrue);
  });

  test('throws a readable error when the root does not exist', () async {
    await expectLater(
      LargeFileScanner(
        root: p.join(temp.path, 'missing'),
        minFileSize: 1,
      ).scan(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('目录不存在'),
        ),
      ),
    );
  });

  test('reports progress with matched counts', () async {
    write('a.bin', 300);
    write('b.bin', 50);

    final progress = <LargeFileProgress>[];
    await LargeFileScanner(
      root: temp.path,
      minFileSize: 100,
    ).scan(onProgress: progress.add);

    expect(progress, isNotEmpty);
    final last = progress.last;
    expect(last.scannedFiles, 2);
    expect(last.scannedBytes, 350);
    expect(last.matchedFiles, 1);
  });
}
