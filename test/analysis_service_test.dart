import 'dart:io';

import 'package:broom/core/analysis/analysis_service.dart';
import 'package:broom/core/models/analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom-analysis-service-');
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

  test('runs duplicate detection in an isolate', () async {
    final first = write('a.txt', 'identical-content');
    final second = write('nested/b.txt', 'identical-content');

    final service = AnalysisService();
    addTearDown(service.dispose);

    final progress = <DuplicateProgress>[];
    final report = await service.findDuplicates(
      root: temp.path,
      minFileSize: 1,
      excludedPaths: const [],
      onProgress: progress.add,
    );

    expect(service.isRunning, isFalse);
    expect(report.groups, hasLength(1));
    expect(report.groups.single.files.map((file) => file.path).toSet(), {
      first.path,
      second.path,
    });
    expect(progress, isNotEmpty);
  });

  test('runs large-file analysis in an isolate', () async {
    final big = write('big.bin', 'x' * 400);
    write('small.bin', 'x' * 10);

    final service = AnalysisService();
    addTearDown(service.dispose);

    final report = await service.findLargeFiles(
      root: temp.path,
      minFileSize: 100,
      maxResults: 10,
      excludedPaths: const [],
    );

    expect(report.files, hasLength(1));
    expect(report.files.single.path, big.path);
    expect(report.matchedBytes, 400);
  });

  test('propagates analysis errors with a readable message', () async {
    final service = AnalysisService();
    addTearDown(service.dispose);

    await expectLater(
      service.findLargeFiles(
        root: p.join(temp.path, 'missing'),
        minFileSize: 1,
        maxResults: 10,
        excludedPaths: const [],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('目录不存在'),
        ),
      ),
    );
  });
}
