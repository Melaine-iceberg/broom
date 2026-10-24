import 'dart:io';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/scan_priority.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakePriorityController implements ScanPriorityController {
  int begins = 0;
  int ends = 0;

  @override
  Future<String?> beginLowPriority() async {
    begins++;
    return 'below_normal';
  }

  @override
  Future<void> endLowPriority() async {
    ends++;
  }
}

class _FakeNtfsIndex implements NtfsIndex {
  _FakeNtfsIndex({this.available = true, this.paths = const []});

  final bool available;
  final List<String> paths;
  int probes = 0;

  @override
  Future<NtfsIndexAvailability> probe(String root) async {
    probes++;
    return available
        ? const NtfsIndexAvailability.available()
        : const NtfsIndexAvailability(NtfsIndexStatus.unprivileged);
  }

  @override
  Stream<NtfsIndexEntry> enumerate(
    String root, {
    Set<String>? extensions,
    int? maxItems,
    bool Function()? isCancelled,
  }) => Stream<NtfsIndexEntry>.fromIterable(paths.map(NtfsIndexEntry.new));
}

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
    final directory = Directory(p.join(temp.path, 'cache'));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, 'old.tmp'));
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
    expect(result.roots.at(result.items.single.rootIndex).ruleId, 'test.rule');
    expect(progress, isNotEmpty);
    expect(progress.last.jobCount, 1);
    expect(progress.last.foundFiles, 1);
  });

  test('streams batches while scanning', () async {
    final directory = Directory(p.join(temp.path, 'stream'));
    await directory.create(recursive: true);
    for (var index = 0; index < 5; index++) {
      await File(p.join(directory.path, 'file-$index.tmp')).writeAsString('x');
    }

    final service = ScanService();
    addTearDown(service.dispose);
    final batches = <List<JunkItem>>[];

    final result = await service
        .scan(
          jobs: [
            ScanJob(ruleId: 'test.rule', roots: [directory.path]),
          ],
          excludedPaths: const [],
          options: const ScanOptions(batchSize: 2),
          retainItems: false,
          onItems: batches.add,
        )
        .timeout(const Duration(seconds: 20));

    expect(result.items, isEmpty);
    expect(result.scannedFiles, 5);
    expect(batches.expand((batch) => batch), hasLength(5));
    expect(batches, isNotEmpty);
  });

  test('scans disjoint jobs with parallel workers', () async {
    final first = Directory(p.join(temp.path, 'first'));
    final second = Directory(p.join(temp.path, 'second'));
    await first.create(recursive: true);
    await second.create(recursive: true);
    await File(p.join(first.path, 'a.tmp')).writeAsString('a');
    await File(p.join(second.path, 'b.tmp')).writeAsString('b');

    final service = ScanService();
    addTearDown(service.dispose);
    final result = await service
        .scan(
          jobs: [
            ScanJob(ruleId: 'test.first', roots: [first.path]),
            ScanJob(ruleId: 'test.second', roots: [second.path]),
          ],
          excludedPaths: const [],
          options: const ScanOptions(parallelism: 2),
        )
        .timeout(const Duration(seconds: 20));

    expect(result.items, hasLength(2));
    expect(
      result.items
          .map((item) => result.roots.at(item.rootIndex).ruleId)
          .toSet(),
      {'test.first', 'test.second'},
    );
  });

  test('deduplicates overlapping jobs across parallel workers', () async {
    final directory = Directory(p.join(temp.path, 'overlap'));
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'a.tmp')).writeAsString('a');
    await File(p.join(directory.path, 'b.tmp')).writeAsString('b');

    final service = ScanService();
    addTearDown(service.dispose);
    final result = await service
        .scan(
          jobs: [
            ScanJob(ruleId: 'test.one', roots: [directory.path]),
            ScanJob(ruleId: 'test.two', roots: [directory.path]),
          ],
          excludedPaths: const [],
          options: const ScanOptions(parallelism: 2),
        )
        .timeout(const Duration(seconds: 20));

    expect(result.items, hasLength(2));
    expect(result.items.map((item) => item.path).toSet(), hasLength(2));
  });

  test('applies a user-configured result limit globally', () async {
    final directory = Directory(p.join(temp.path, 'limited'));
    await directory.create(recursive: true);
    for (var index = 0; index < 8; index++) {
      await File(p.join(directory.path, 'file-$index.tmp')).writeAsString('x');
    }

    final service = ScanService();
    addTearDown(service.dispose);
    final result = await service
        .scan(
          jobs: [
            ScanJob(ruleId: 'test.rule', roots: [directory.path]),
          ],
          excludedPaths: const [],
          options: const ScanOptions(maxItems: 3, parallelism: 2),
        )
        .timeout(const Duration(seconds: 20));

    expect(result.truncated, isTrue);
    expect(result.items, hasLength(3));
    expect(result.cancelled, isFalse);
  });

  test('lowers and restores priority around a scan', () async {
    final directory = Directory(p.join(temp.path, 'priority'));
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'a.tmp')).writeAsString('a');

    final priority = _FakePriorityController();
    final service = ScanService(priorityController: priority);
    addTearDown(service.dispose);

    await service
        .scan(
          jobs: [
            ScanJob(ruleId: 'test.rule', roots: [directory.path]),
          ],
          excludedPaths: const [],
          options: const ScanOptions(lowPriority: true),
        )
        .timeout(const Duration(seconds: 20));
    await Future<void>.delayed(Duration.zero);

    expect(priority.begins, 1);
    expect(priority.ends, 1);
  });

  test('uses the indexed path when every root is available', () async {
    final directory = Directory(p.join(temp.path, 'indexed'));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, 'a.tmp'));
    await file.writeAsString('a');
    final index = _FakeNtfsIndex(paths: [file.path]);

    final service = ScanService();
    addTearDown(service.dispose);
    final result = await service
        .scan(
          jobs: [
            ScanJob(ruleId: 'test.index', roots: [directory.path]),
          ],
          excludedPaths: const [],
          options: const ScanOptions(useNtfsIndex: true),
          ntfsIndex: index,
        )
        .timeout(const Duration(seconds: 20));

    expect(index.probes, greaterThanOrEqualTo(1));
    expect(result.items, hasLength(1));
    expect(result.items.single.path, file.path);
  });

  test('falls back to workers when the NTFS index is unavailable', () async {
    final directory = Directory(p.join(temp.path, 'fallback'));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, 'a.tmp'));
    await file.writeAsString('a');
    final index = _FakeNtfsIndex(available: false);

    final service = ScanService();
    addTearDown(service.dispose);
    final result = await service
        .scan(
          jobs: [
            ScanJob(ruleId: 'test.index', roots: [directory.path]),
          ],
          excludedPaths: const [],
          options: const ScanOptions(useNtfsIndex: true),
          ntfsIndex: index,
        )
        .timeout(const Duration(seconds: 20));

    expect(result.items, hasLength(1));
    expect(result.items.single.path, file.path);
  });
}
