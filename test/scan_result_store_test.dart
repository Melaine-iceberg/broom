import 'dart:io';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/scan/scan_result_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late ScanResultStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_scan_store_');
    store = ScanResultStore(rootDirectory: p.windows.join(temp.path, 'scans'));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  JunkItem item(String name, int size) => JunkItem(
    rootIndex: 0,
    path: p.windows.join(temp.path, 'cache', name),
    size: size,
    modifiedMicros: DateTime.utc(2026, 10, 18, 12).microsecondsSinceEpoch,
  );

  ScanRoots roots() => ScanRoots([
    ScanRoot(ruleId: 'test.rule', rootPath: p.windows.join(temp.path, 'cache')),
  ]);

  test('streams items and round-trips the latest result', () async {
    final writer = await store.begin(
      ruleIds: const ['test.rule'],
      rulesVersion: 'builtin',
      roots: roots(),
    );
    await writer.addItems([item('a.tmp', 10)]);
    await writer.addItems([item('b.tmp', 20)]);
    final summary = await writer.complete(
      scannedFiles: 8,
      foundFiles: 2,
      foundBytes: 30,
      issueCount: 1,
      errorCounts: const {ScanErrorKind.accessDenied: 1},
      truncated: false,
    );

    expect(summary.persistedItemCount, 2);
    expect(summary.foundBytes, 30);

    final latest = await store.loadLatest();
    expect(latest, isNotNull);
    expect(latest!.id, summary.id);
    expect(latest.rulesVersion, 'builtin');
    expect(latest.errorCounts[ScanErrorKind.accessDenied], 1);

    final data = await store.load(latest);
    expect(data, isNotNull);
    expect(data!.items, hasLength(2));
    expect(data.items.first.path, p.windows.join(temp.path, 'cache', 'a.tmp'));
    final root = data.roots.at(data.items.first.rootIndex);
    expect(root.ruleId, 'test.rule');
    expect(root.rootPath, p.windows.join(temp.path, 'cache'));
  });

  test('replaces the previous result and removes the old directory', () async {
    final first = await store.begin(
      ruleIds: const ['test.rule'],
      rulesVersion: 'builtin',
      roots: roots(),
    );
    await first.addItems([item('old.tmp', 1)]);
    final firstSummary = await first.complete(
      scannedFiles: 1,
      foundFiles: 1,
      foundBytes: 1,
      issueCount: 0,
      errorCounts: const {},
      truncated: false,
    );

    final second = await store.begin(
      ruleIds: const ['test.rule'],
      rulesVersion: 'builtin',
      roots: roots(),
    );
    await second.addItems([item('new.tmp', 2)]);
    final secondSummary = await second.complete(
      scannedFiles: 1,
      foundFiles: 1,
      foundBytes: 2,
      issueCount: 0,
      errorCounts: const {},
      truncated: false,
    );

    expect(secondSummary.id, isNot(firstSummary.id));
    final latest = await store.loadLatest();
    expect(latest!.id, secondSummary.id);
    expect(
      await Directory(p.windows.join(temp.path, 'scans', firstSummary.id))
          .exists(),
      isFalse,
    );
  });

  test('expired results are not offered for restore', () async {
    final writer = await store.begin(
      ruleIds: const ['test.rule'],
      rulesVersion: 'builtin',
      roots: roots(),
    );
    await writer.complete(
      scannedFiles: 0,
      foundFiles: 0,
      foundBytes: 0,
      issueCount: 0,
      errorCounts: const {},
      truncated: false,
    );

    final future = DateTime.now().add(const Duration(hours: 25));
    expect(await store.loadLatest(clock: () => future), isNull);
  });

  test('stops persisting when the disk protection limit is reached', () async {
    final limited = ScanResultStore(
      rootDirectory: p.windows.join(temp.path, 'limited'),
      maxItemsFileBytes: 120,
    );
    final writer = await limited.begin(
      ruleIds: const ['test.rule'],
      rulesVersion: 'builtin',
      roots: roots(),
    );
    await writer.addItems([
      for (var index = 0; index < 10; index++) item('file-$index.tmp', 1),
    ]);
    final summary = await writer.complete(
      scannedFiles: 10,
      foundFiles: 10,
      foundBytes: 10,
      issueCount: 0,
      errorCounts: const {},
      truncated: false,
    );

    expect(summary.persistenceLimited, isTrue);
    expect(summary.persistedItemCount, lessThan(10));
    final data = await limited.load(summary);
    expect(data!.items.length, summary.persistedItemCount);
  });

  test('rejects unsafe ids in latest.json', () async {
    final file = File(p.windows.join(store.rootDirectory, 'latest.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString('{"schemaVersion":1,"id":"../outside"}');

    expect(await store.loadLatest(), isNull);
  });

  test('aborted writes are not published', () async {
    final writer = await store.begin(
      ruleIds: const ['test.rule'],
      rulesVersion: 'builtin',
      roots: roots(),
    );
    await writer.addItems([item('partial.tmp', 1)]);
    await writer.abort();

    expect(await store.loadLatest(), isNull);
  });
}
