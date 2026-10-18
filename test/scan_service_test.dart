import 'dart:io';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_scan_service_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('round-trips models and progress through the scan isolate', () async {
    final directory = Directory(p.windows.join(temp.path, 'cache'));
    await directory.create(recursive: true);
    final file = File(p.windows.join(directory.path, 'old.tmp'));
    await file.writeAsString('old-content');
    await file.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );

    final service = ScanService();
    addTearDown(service.dispose);
    final progress = <ScanProgress>[];

    final result = await service
        .scan(
          jobs: [
            ScanJob(
              ruleId: 'test.rule',
              roots: [directory.path],
              minAge: const Duration(hours: 1),
            ),
          ],
          excludedPaths: const [],
          onProgress: progress.add,
        )
        .timeout(const Duration(seconds: 20));

    expect(result.cancelled, isFalse);
    expect(result.items, hasLength(1));
    expect(result.items.single.path, file.path);
    expect(result.items.single.size, file.lengthSync());
    expect(result.items.single.ruleId, 'test.rule');
    expect(progress, isNotEmpty);
    expect(progress.last.jobCount, 1);
    expect(progress.last.foundFiles, 1);
  });
}
