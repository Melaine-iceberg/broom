import 'dart:convert';
import 'dart:io';

import 'package:broom/core/clean/quarantine_service.dart';
import 'package:crypto/crypto.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/safety/path_exclusions.dart';
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

  test('continues an interrupted cleanup from the persisted plan', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile('second.txt', 'bravo');
    final third = await createFile('third.txt', 'charlie');
    var cancel = false;

    final interrupted = await quarantine.clean(
      [await itemFor(first), await itemFor(second), await itemFor(third)],
      onProgress: (progress) {
        if (progress.moved >= 1) cancel = true;
      },
      isCancelled: () => cancel,
    );

    expect(interrupted.cancelled, isTrue);
    expect(interrupted.movedCount, 1);
    expect(interrupted.remainingCount, 2);
    expect(interrupted.sessionId, isNotNull);
    expect(await second.exists(), isTrue);
    expect(await third.exists(), isTrue);

    final interruptedSession = (await quarantine.listSessions()).single;
    expect(interruptedSession.status, QuarantineStatus.partial);
    expect(interruptedSession.resumable, isTrue);
    expect(interruptedSession.remainingCount, 2);
    expect(interruptedSession.pendingCount, 1);

    // A hard crash leaves the session in "cleaning"; listing must recover the
    // remaining count from the plan and entries instead of trusting metadata.
    final metaFile = File(
      p.windows.join(
        temp.path,
        'quarantine',
        interrupted.sessionId!,
        'session.json',
      ),
    );
    final crashedMeta =
        jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    crashedMeta['status'] = 'cleaning';
    crashedMeta.remove('remainingCount');
    await metaFile.writeAsString(jsonEncode(crashedMeta));

    final recovered = (await quarantine.listSessions()).single;
    expect(recovered.status, QuarantineStatus.partial);
    expect(recovered.resumable, isTrue);
    expect(recovered.remainingCount, 2);
    expect(recovered.pendingCount, 1);

    final resumed = await quarantine.resumeClean(interrupted.sessionId!);

    expect(resumed.cancelled, isFalse);
    expect(resumed.movedCount, 2);
    expect(resumed.failureCount, 0);
    expect(resumed.remainingCount, 0);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);
    expect(await third.exists(), isFalse);

    final readySession = (await quarantine.listSessions()).single;
    expect(readySession.status, QuarantineStatus.ready);
    expect(readySession.resumable, isFalse);
    expect(readySession.pendingCount, 3);
    expect(readySession.remainingCount, 0);
    expect(
      File(
        p.windows.join(
          temp.path,
          'quarantine',
          interrupted.sessionId!,
          'plan.jsonl',
        ),
      ).existsSync(),
      isFalse,
    );

    final undo = await quarantine.undo(interrupted.sessionId!);

    expect(undo.restoredCount, 3);
    expect(undo.sessionRemoved, isTrue);
    expect(await first.readAsString(), 'alpha');
    expect(await second.readAsString(), 'bravo');
    expect(await third.readAsString(), 'charlie');
    await expectLater(
      quarantine.resumeClean(interrupted.sessionId!),
      throwsStateError,
    );
  });

  test('keeps a resumable session when no file was moved', () async {
    final movable = await createFile('movable.txt', 'alpha');
    final missing = JunkItem(
      ruleId: 'test.rule',
      rootPath: source.path,
      path: p.windows.join(source.path, 'missing.txt'),
      size: 1,
      modified: DateTime(2026, 10, 18),
    );
    var cancel = false;

    final interrupted = await quarantine.clean(
      [missing, await itemFor(movable)],
      onProgress: (_) => cancel = true,
      isCancelled: () => cancel,
    );

    expect(interrupted.cancelled, isTrue);
    expect(interrupted.movedCount, 0);
    expect(interrupted.failureCount, 1);
    expect(interrupted.remainingCount, 1);
    expect(interrupted.sessionId, isNotNull);

    final session = (await quarantine.listSessions()).single;
    expect(session.status, QuarantineStatus.partial);
    expect(session.resumable, isTrue);
    expect(session.pendingCount, 0);
    expect(session.remainingCount, 1);

    final resumed = await quarantine.resumeClean(interrupted.sessionId!);

    expect(resumed.movedCount, 1);
    expect(resumed.failureCount, 1);
    expect(resumed.remainingCount, 0);
    expect(await movable.exists(), isFalse);
    expect(
      (await quarantine.listSessions()).single.status,
      QuarantineStatus.ready,
    );
  });

  test('records a SHA-256 digest for small quarantine entries', () async {
    final file = await createFile('hashed.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);

    final entriesFile = File(
      p.windows.join(
        temp.path,
        'quarantine',
        report.sessionId!,
        'entries.jsonl',
      ),
    );
    final entry = jsonDecode(
      (await entriesFile.readAsLines()).single,
    ) as Map<String, dynamic>;

    expect(entry['size'], 5);
    expect(entry['sha256'], sha256.convert(utf8.encode('alpha')).toString());
  });

  test('refuses to restore a quarantine file whose size changed', () async {
    final file = await createFile('tampered.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);

    final entry = (await quarantine.listEntries(report.sessionId!)).single;
    final stored = File(
      p.windows.join(
        temp.path,
        'quarantine',
        report.sessionId!,
        'files',
        entry.storedName,
      ),
    );
    await stored.writeAsString('x');

    final listed = (await quarantine.listEntries(report.sessionId!)).single;
    expect(listed.integrityFailure, isNotNull);
    expect(listed.restorable, isFalse);

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 0);
    expect(undo.failureCount, 1);
    expect(undo.integrityFailureCount, 1);
    expect(undo.sessionRemoved, isFalse);
    expect(await file.exists(), isFalse);
    expect(undo.failures.single.reason, contains('大小'));
  });

  test('detects same-size tampering with the stored hash', () async {
    final file = await createFile('tampered.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);

    final entry = (await quarantine.listEntries(report.sessionId!)).single;
    final stored = File(
      p.windows.join(
        temp.path,
        'quarantine',
        report.sessionId!,
        'files',
        entry.storedName,
      ),
    );
    await stored.writeAsString('bravo');

    final listed = (await quarantine.listEntries(report.sessionId!)).single;
    expect(listed.integrityFailure, isNull);

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 0);
    expect(undo.integrityFailureCount, 1);
    expect(undo.sessionRemoved, isFalse);
    expect(undo.failures.single.reason, contains('SHA-256'));
  });

  test('restores sessions whose entries predate integrity hashes', () async {
    final file = await createFile('legacy.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);

    final entriesFile = File(
      p.windows.join(
        temp.path,
        'quarantine',
        report.sessionId!,
        'entries.jsonl',
      ),
    );
    final entry = jsonDecode(
      (await entriesFile.readAsLines()).single,
    ) as Map<String, dynamic>;
    entry.remove('sha256');
    await entriesFile.writeAsString('${jsonEncode(entry)}\n');

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 1);
    expect(undo.integrityFailureCount, 0);
    expect(await file.readAsString(), 'alpha');
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

  test('keeps both copies with a unique restored name', () async {
    final file = await createFile('conflict.txt', 'alpha');
    final occupied = File(p.windows.join(source.path, 'conflict (已恢复).txt'));
    await occupied.writeAsString('occupied');
    final report = await quarantine.clean([await itemFor(file)]);
    await file.writeAsString('user-content');

    final undo = await quarantine.undo(
      report.sessionId!,
      conflictPolicy: UndoConflictPolicy.keepBoth,
    );

    expect(undo.restoredCount, 1);
    expect(undo.keptBothCount, 1);
    expect(undo.conflictCount, 0);
    expect(undo.failureCount, 0);
    expect(undo.sessionRemoved, isTrue);
    expect(await file.readAsString(), 'user-content');
    expect(await occupied.readAsString(), 'occupied');
    final restored = File(p.windows.join(source.path, 'conflict (已恢复 2).txt'));
    expect(await restored.readAsString(), 'alpha');
    expect(await quarantine.listSessions(), isEmpty);
  });

  test('overwrites the occupied target after backing it up', () async {
    final file = await createFile('conflict.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);
    await file.writeAsString('user-content');

    final undo = await quarantine.undo(
      report.sessionId!,
      conflictPolicy: UndoConflictPolicy.overwrite,
    );

    expect(undo.restoredCount, 1);
    expect(undo.overwrittenCount, 1);
    expect(undo.keptBothCount, 0);
    expect(undo.conflictCount, 0);
    expect(undo.failureCount, 0);
    expect(undo.sessionRemoved, isTrue);
    expect(await file.readAsString(), 'alpha');
    final leftovers = await source
        .list()
        .where((entity) => p.basename(entity.path).startsWith('.broom-backup-'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('refuses to overwrite a directory at the original path', () async {
    final file = await createFile('conflict.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);
    await Directory(file.path).create();

    final undo = await quarantine.undo(
      report.sessionId!,
      conflictPolicy: UndoConflictPolicy.overwrite,
    );

    expect(undo.restoredCount, 0);
    expect(undo.overwrittenCount, 0);
    expect(undo.failureCount, 1);
    expect(undo.failures.single.reason, contains('不是普通文件'));
    expect(undo.sessionRemoved, isFalse);
    expect(await Directory(file.path).exists(), isTrue);
    expect((await quarantine.listSessions()).single.pendingCount, 1);
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

  test('refuses to clean items inside excluded paths', () async {
    final excludedDir = Directory(p.windows.join(source.path, 'keep'));
    await excludedDir.create(recursive: true);
    final file = await createFile(p.join('keep', 'keep.txt'), 'keep-me');
    final service = QuarantineService(
      quarantineRoot: p.windows.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
      exclusions: PathExclusions([excludedDir.path]),
    );

    final report = await service.clean([await itemFor(file)]);

    expect(report.sessionId, isNull);
    expect(report.movedCount, 0);
    expect(report.failureCount, 1);
    expect(report.failures.single.reason, contains('排除'));
    expect(await file.readAsString(), 'keep-me');
    expect(await service.listSessions(), isEmpty);
  });

  test('refuses to restore into excluded paths', () async {
    final file = await createFile('keep.txt', 'alpha');
    final report = await quarantine.clean([await itemFor(file)]);

    final restricted = QuarantineService(
      quarantineRoot: p.windows.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
      exclusions: PathExclusions([source.path]),
    );
    final blocked = await restricted.undo(report.sessionId!);

    expect(blocked.restoredCount, 0);
    expect(blocked.failureCount, 1);
    expect(blocked.failures.single.reason, contains('排除'));
    expect(await file.exists(), isFalse);
    expect((await restricted.listSessions()).single.pendingCount, 1);

    final retry = await quarantine.undo(report.sessionId!);

    expect(retry.restoredCount, 1);
    expect(retry.sessionRemoved, isTrue);
    expect(await file.readAsString(), 'alpha');
  });
}
