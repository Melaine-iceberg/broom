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
