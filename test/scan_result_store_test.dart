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
    store = ScanResultStore(rootDirectory: p.join(temp.path, 'scans'));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  JunkItem item(String name, int size) => JunkItem(
    rootIndex: 0,
    path: p.join(temp.path, 'cache', name),
    size: size,
    modifiedMicros: DateTime.utc(2026, 10, 18, 12).microsecondsSinceEpoch,
  );

  ScanRoots roots() => ScanRoots([
    ScanRoot(ruleId: 'test.rule', rootPath: p.join(temp.path, 'cache')),
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
    final items = data!.groups['test.rule']!;
    expect(items, hasLength(2));
    // Groups are sorted by size descending inside the worker.
    expect(items.first.path, p.join(temp.path, 'cache', 'b.tmp'));
    expect(items.last.path, p.join(temp.path, 'cache', 'a.tmp'));
    expect(data.totalItems, 2);
    final root = data.roots.at(items.first.rootIndex);
    expect(root.ruleId, 'test.rule');
    expect(root.rootPath, p.join(temp.path, 'cache'));
  });

  test('loads grouped, sorted and filtered rule groups', () async {
    final multiRoots = ScanRoots([
      ScanRoot(ruleId: 'rule.a', rootPath: p.join(temp.path, 'a')),
      ScanRoot(ruleId: 'rule.b', rootPath: p.join(temp.path, 'b')),
    ]);
    JunkItem groupedItem(String name, int size, int rootIndex) => JunkItem(
      rootIndex: rootIndex,
      path: p.join(temp.path, 'cache', name),
      size: size,
      modifiedMicros: DateTime.utc(2026, 10, 18, 12).microsecondsSinceEpoch,
    );
    final writer = await store.begin(
      ruleIds: const ['rule.a', 'rule.b'],
      rulesVersion: 'builtin',
      roots: multiRoots,
    );
    await writer.addItems([
      groupedItem('a-small.tmp', 1, 0),
      groupedItem('a-big.tmp', 30, 0),
      groupedItem('b-mid.tmp', 20, 1),
    ]);
    final summary = await writer.complete(
      scannedFiles: 3,
      foundFiles: 3,
      foundBytes: 51,
      issueCount: 0,
      errorCounts: const {},
      truncated: false,
    );

    final all = await store.load(summary);
    expect(all!.totalItems, 3);
    expect(all.groups.keys, unorderedEquals(['rule.a', 'rule.b']));
    expect(
      all.groups['rule.a']!.map((item) => item.size),
      orderedEquals([30, 1]),
    );
    expect(
      all.roots.at(all.groups['rule.a']!.first.rootIndex).ruleId,
      'rule.a',
    );

    final filtered = await store.load(summary, allowedRuleIds: {'rule.b'});
    expect(filtered!.totalItems, 3);
    expect(filtered.groups.keys, ['rule.b']);
    expect(filtered.extensionsByRule.keys, ['rule.b']);
    expect(
      filtered.groups['rule.b']!.single.path,
      p.join(temp.path, 'cache', 'b-mid.tmp'),
    );
  });

  test('collects distinct extensions per rule while grouping', () async {
    final writer = await store.begin(
      ruleIds: const ['test.rule'],
      rulesVersion: 'builtin',
      roots: roots(),
    );
    await writer.addItems([
      item('a.TMP', 1),
      item('b.log', 2),
      item('c.tmp', 3),
      item('no-extension', 4),
      item('d.Tmp.', 5),
    ]);
    final summary = await writer.complete(
      scannedFiles: 5,
      foundFiles: 5,
      foundBytes: 15,
      issueCount: 0,
      errorCounts: const {},
      truncated: false,
    );

    final data = await store.load(summary);

    expect(data!.extensionsByRule['test.rule'], {'log', 'tmp'});
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
      await Directory(p.join(temp.path, 'scans', firstSummary.id)).exists(),
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
      rootDirectory: p.join(temp.path, 'limited'),
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
    final items = data!.groups.values.expand((group) => group);
    expect(items.length, summary.persistedItemCount);
  });

  test(
    'drains buffered writes across batches before hitting the limit',
    () async {
      final longName = 'x' * 4096;
      final limited = ScanResultStore(
        rootDirectory: p.join(temp.path, 'limited_batches'),
        maxItemsFileBytes: 6 * 1024 * 1024,
      );
      final writer = await limited.begin(
        ruleIds: const ['test.rule'],
        rulesVersion: 'builtin',
        roots: roots(),
      );
      const total = 2000;
      for (var start = 0; start < total; start += 10) {
        await writer.addItems([
          for (var index = start; index < start + 10; index++)
            JunkItem(
              rootIndex: 0,
              path: p.join(temp.path, 'cache', 'd$index', '$longName.tmp'),
              size: 1,
              modifiedMicros: DateTime.utc(
                2026,
                10,
                18,
                12,
              ).microsecondsSinceEpoch,
            ),
        ]);
      }
      final summary = await writer.complete(
        scannedFiles: total,
        foundFiles: total,
        foundBytes: total,
        issueCount: 0,
        errorCounts: const {},
        truncated: false,
      );

      expect(summary.persistenceLimited, isTrue);
      expect(summary.persistedItemCount, lessThan(total));
      final data = await limited.load(summary);
      final items = data!.groups.values.expand((group) => group);
      expect(items.length, summary.persistedItemCount);
      expect(data.totalItems, summary.persistedItemCount);
    },
  );

  test('rejects unsafe ids in latest.json', () async {
    final file = File(p.join(store.rootDirectory, 'latest.json'));
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
