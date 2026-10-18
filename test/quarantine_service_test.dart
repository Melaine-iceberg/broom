import 'dart:io';

import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory source;
  late QuarantineService quarantine;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_quarantine_');
    source = Directory(p.windows.join(temp.path, 'source'));
    await source.create(recursive: true);
    quarantine = QuarantineService(
      quarantineRoot: p.windows.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<File> createFile(String relative, String content) async {
    final file = File(p.windows.join(source.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  Future<JunkItem> itemFor(File file) async {
    final stat = await file.stat();
    return JunkItem(
      ruleId: 'test.rule',
      rootPath: source.path,
      path: file.path,
      size: stat.size,
      modified: stat.modified,
    );
  }

  test('cleans into quarantine and fully restores the session', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile(p.join('nested', 'second.txt'), 'bravo!');
    final items = [await itemFor(first), await itemFor(second)];

    final report = await quarantine.clean(items);

    expect(report.sessionId, isNotNull);
    expect(report.movedCount, 2);
    expect(report.failureCount, 0);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);

    final sessions = await quarantine.listSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single.status.name, 'ready');
    expect(sessions.single.pendingCount, 2);

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 2);
    expect(undo.conflictCount, 0);
    expect(undo.sessionRemoved, isTrue);
    expect(await first.readAsString(), 'alpha');
    expect(await second.readAsString(), 'bravo!');
    expect(await quarantine.listSessions(), isEmpty);
    expect(
      await Directory(p.windows.join(temp.path, 'quarantine')).exists(),
      isTrue,
    );
  });

  test('skips existing targets and can retry the remaining entry', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile('second.txt', 'bravo');
    final report = await quarantine.clean([
      await itemFor(first),
      await itemFor(second),
    ]);

    await first.writeAsString('user-content');
    final firstUndo = await quarantine.undo(report.sessionId!);

    expect(firstUndo.restoredCount, 1);
    expect(firstUndo.conflictCount, 1);
    expect(firstUndo.sessionRemoved, isFalse);
    expect(await first.readAsString(), 'user-content');
    expect(await second.readAsString(), 'bravo');
    final sessions = await quarantine.listSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single.pendingCount, 1);

    await first.delete();
    final secondUndo = await quarantine.undo(report.sessionId!);

    expect(secondUndo.restoredCount, 1);
    expect(secondUndo.sessionRemoved, isTrue);
    expect(await first.readAsString(), 'alpha');
    expect(await quarantine.listSessions(), isEmpty);
  });

  test('lists entries and restores only selected files', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile('second.txt', 'bravo');
    final report = await quarantine.clean([
      await itemFor(first),
      await itemFor(second),
    ]);

    final entries = await quarantine.listEntries(report.sessionId!);
    expect(entries, hasLength(2));
    expect(entries.every((entry) => entry.present), isTrue);
    expect(entries.every((entry) => !entry.restored), isTrue);
    expect(entries.every((entry) => !entry.originalExists), isTrue);

    final selected = entries.firstWhere(
      (entry) => entry.originalPath == first.path,
    );
    final partial = await quarantine.undo(
      report.sessionId!,
      storedNames: {selected.storedName},
    );

    expect(partial.restoredCount, 1);
    expect(partial.sessionRemoved, isFalse);
    expect(await first.readAsString(), 'alpha');
    expect(await second.exists(), isFalse);
    expect((await quarantine.listSessions()).single.pendingCount, 1);

    final remaining = await quarantine.listEntries(report.sessionId!);
    final restored = remaining.firstWhere(
      (entry) => entry.originalPath == first.path,
    );
    expect(restored.restored, isTrue);
    expect(restored.present, isFalse);
    expect(
      remaining
          .firstWhere((entry) => entry.originalPath == second.path)
          .restorable,
      isTrue,
    );

    final complete = await quarantine.undo(report.sessionId!);
    expect(complete.restoredCount, 1);
    expect(complete.sessionRemoved, isTrue);
    expect(await second.readAsString(), 'bravo');
  });

  test('reports existing original paths before restoring', () async {
    final file = await createFile('conflict.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);
    await file.writeAsString('user-content');

    final entries = await quarantine.listEntries(report.sessionId!);
    expect(entries.single.originalExists, isTrue);
    expect(entries.single.restorable, isTrue);

    final undo = await quarantine.undo(report.sessionId!);
    expect(undo.conflictCount, 1);
    expect(undo.sessionRemoved, isFalse);
    expect(await file.readAsString(), 'user-content');

    final after = await quarantine.listEntries(report.sessionId!);
    expect(after.single.restored, isFalse);
    expect(after.single.originalExists, isTrue);
  });

  test('permanently purges a quarantine session', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile('second.txt', 'bravo');
    final report = await quarantine.clean([
      await itemFor(first),
      await itemFor(second),
    ]);
    final entries = await quarantine.listEntries(report.sessionId!);
    final totalBytes = entries.fold<int>(
      0,
      (total, entry) => total + entry.size,
    );

    final purge = await quarantine.purgeSession(report.sessionId!);

    expect(purge.removedCount, 2);
    expect(purge.removedBytes, totalBytes);
    expect(purge.failureCount, 0);
    expect(purge.sessionRemoved, isTrue);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);
    expect(await quarantine.listSessions(), isEmpty);
    expect(
      await Directory(
        p.windows.join(temp.path, 'quarantine', report.sessionId!),
      ).exists(),
      isFalse,
    );
  });

  test('permanently purges every pending session', () async {
    final first = await createFile('first.txt', 'alpha');
    await quarantine.clean([await itemFor(first)]);
    final second = await createFile('second.txt', 'bravo');
    await quarantine.clean([await itemFor(second)]);

    expect(await quarantine.listSessions(), hasLength(2));

    final purge = await quarantine.purgeAllSessions();

    expect(purge.removedCount, 2);
    expect(purge.failureCount, 0);
    expect(purge.sessionRemoved, isTrue);
    expect(await quarantine.listSessions(), isEmpty);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);
  });

  test('rejects unsafe session ids', () async {
    for (final id in ['../escape', r'..\escape', 'a/b', '']) {
      await expectLater(quarantine.listEntries(id), throwsArgumentError);
      await expectLater(quarantine.purgeSession(id), throwsArgumentError);
    }
  });

  test('refuses items outside their declared root', () async {
    final outside = File(p.windows.join(temp.path, 'outside.txt'));
    await outside.writeAsString('keep-me');
    final stat = await outside.stat();

    final report = await quarantine.clean([
      JunkItem(
        ruleId: 'test.rule',
        rootPath: source.path,
        path: outside.path,
        size: stat.size,
        modified: stat.modified,
      ),
    ]);

    expect(report.sessionId, isNull);
    expect(report.movedCount, 0);
    expect(report.failureCount, 1);
    expect(await outside.exists(), isTrue);
    expect(await quarantine.listSessions(), isEmpty);
  });

  test('requires an absolute quarantine path', () {
    expect(
      () => QuarantineService(
        quarantineRoot: 'relative/quarantine',
        guard: PathGuard(protectedRoots: const []),
      ),
      throwsArgumentError,
    );
  });
}
