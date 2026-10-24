import 'dart:convert';
import 'dart:io';

import 'package:broom/core/clean/clean_history_store.dart';
import 'package:broom/core/clean/file_metadata.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/clean/quarantine_session_schema.dart';
import 'package:broom/core/models/clean_history_models.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/safety/path_exclusions.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/file_metadata_fakes.dart';

final _windowsOnly = !Platform.isWindows;

void main() {
  late Directory temp;
  late Directory source;
  late FakeFileMetadataAccess metadata;
  late QuarantineService quarantine;
  late ScanRoots testRoots;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_quarantine_');
    source = Directory(p.join(temp.path, 'source'));
    await source.create(recursive: true);
    testRoots = ScanRoots([
      ScanRoot(ruleId: 'test.rule', rootPath: source.path),
    ]);
    metadata = FakeFileMetadataAccess();
    quarantine = QuarantineService(
      quarantineRoot: p.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
      metadataAccess: metadata,
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<File> createFile(String relative, String content) async {
    final file = File(p.join(source.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  Future<JunkItem> itemFor(File file) async {
    final stat = await file.stat();
    return JunkItem(
      rootIndex: 0,
      path: file.path,
      size: stat.size,
      modifiedMicros: stat.modified.microsecondsSinceEpoch,
    );
  }

  Future<CleanReport> clean(
    List<JunkItem> items, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) => quarantine.clean(
    items,
    roots: testRoots,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  test('cleans into quarantine and fully restores the session', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile(p.join('nested', 'second.txt'), 'bravo!');
    final items = [await itemFor(first), await itemFor(second)];

    final report = await clean(items);

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
    expect(await Directory(p.join(temp.path, 'quarantine')).exists(), isTrue);
  });

  test('removes empty cache directories and recreates them on undo', () async {
    final file = await createFile(
      p.join('cache', 'nested', 'file.tmp'),
      'alpha',
    );
    final report = await clean([await itemFor(file)]);

    expect(report.removedDirectoryCount, 2);
    expect(await file.exists(), isFalse);
    expect(
      await Directory(p.join(source.path, 'cache', 'nested')).exists(),
      isFalse,
    );
    expect(await Directory(p.join(source.path, 'cache')).exists(), isFalse);
    expect(await source.exists(), isTrue);

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 1);
    expect(undo.recreatedDirectoryCount, 2);
    expect(undo.directoryFailureCount, 0);
    expect(
      await Directory(p.join(source.path, 'cache', 'nested')).exists(),
      isTrue,
    );
    expect(await file.readAsString(), 'alpha');
  });

  test('leaves pre-existing empty directories and directories with remaining files', () async {
    final selected = await createFile(p.join('cache', 'selected.tmp'), 'alpha');
    final kept = await createFile(p.join('cache', 'kept.tmp'), 'bravo');
    final existingEmpty = Directory(p.join(source.path, 'already_empty'));
    await existingEmpty.create();

    final report = await clean([await itemFor(selected)]);

    expect(report.removedDirectoryCount, 0);
    expect(await Directory(p.join(source.path, 'cache')).exists(), isTrue);
    expect(await existingEmpty.exists(), isTrue);
    expect(await kept.readAsString(), 'bravo');
  });

  test(
    'removes directories from earlier interrupted moves after resume',
    () async {
      final first = await createFile(p.join('a', 'first.tmp'), 'alpha');
      final second = await createFile(p.join('b', 'second.tmp'), 'bravo');
      var cancel = false;

      final interrupted = await clean(
        [await itemFor(first), await itemFor(second)],
        onProgress: (progress) {
          if (progress.moved >= 1) cancel = true;
        },
        isCancelled: () => cancel,
      );

      expect(interrupted.cancelled, isTrue);
      expect(interrupted.removedDirectoryCount, 0);
      expect(await Directory(p.join(source.path, 'a')).exists(), isTrue);
      expect(await second.exists(), isTrue);

      final resumed = await quarantine.resumeClean(interrupted.sessionId!);

      expect(resumed.movedCount, 1);
      expect(resumed.removedDirectoryCount, 2);
      expect(await Directory(p.join(source.path, 'a')).exists(), isFalse);
      expect(await Directory(p.join(source.path, 'b')).exists(), isFalse);

      final undo = await quarantine.undo(interrupted.sessionId!);

      expect(undo.restoredCount, 2);
      expect(undo.recreatedDirectoryCount, 2);
      expect(await Directory(p.join(source.path, 'a')).exists(), isTrue);
      expect(await Directory(p.join(source.path, 'b')).exists(), isTrue);
    },
  );

  test('recreates removed directories when no file can be restored', () async {
    final file = await createFile(
      p.join('cache', 'nested', 'lost.tmp'),
      'alpha',
    );
    final report = await clean([await itemFor(file)]);
    final entry = (await quarantine.listEntries(report.sessionId!)).single;
    await File(
      p.join(
        temp.path,
        'quarantine',
        report.sessionId!,
        'files',
        entry.storedName,
      ),
    ).delete();

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 0);
    expect(undo.missingCount, 1);
    expect(undo.recreatedDirectoryCount, 2);
    expect(
      await Directory(p.join(source.path, 'cache', 'nested')).exists(),
      isTrue,
    );
    expect(undo.sessionRemoved, isTrue);
  });

  test('ignores tampered removed directory records', () async {
    final file = await createFile(
      p.join('cache', 'nested', 'file.tmp'),
      'alpha',
    );
    final report = await clean([await itemFor(file)]);
    final recordsFile = File(
      p.join(temp.path, 'quarantine', report.sessionId!, 'removed_dirs.jsonl'),
    );
    final outside = Directory(p.join(temp.path, 'outside'));
    final unrelated = Directory(p.join(source.path, 'unrelated'));
    final existing = await recordsFile.readAsString();
    await recordsFile.writeAsString(
      '$existing'
      '${jsonEncode({'path': outside.path, 'rootPath': source.path})}\n'
      '${jsonEncode({'path': unrelated.path, 'rootPath': source.path})}\n',
      flush: true,
    );

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 1);
    expect(await outside.exists(), isFalse);
    expect(await unrelated.exists(), isFalse);
    expect(undo.recreatedDirectoryCount, 2);
  });

  test('continues an interrupted cleanup from the persisted plan', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile('second.txt', 'bravo');
    final third = await createFile('third.txt', 'charlie');
    var cancel = false;

    final interrupted = await clean(
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
      p.join(temp.path, 'quarantine', interrupted.sessionId!, 'session.json'),
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
        p.join(temp.path, 'quarantine', interrupted.sessionId!, 'plan.jsonl'),
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
      rootIndex: 0,
      path: p.join(source.path, 'missing.txt'),
      size: 1,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    var cancel = false;

    final interrupted = await clean(
      [missing, await itemFor(movable)],
      onProgress: (_) => cancel = true,
      isCancelled: () => cancel,
    );

    expect(interrupted.cancelled, isTrue);
    expect(interrupted.movedCount, 0);
    expect(interrupted.skippedCount, 1);
    expect(interrupted.skips.single.reason, contains('不存在'));
    expect(interrupted.failureCount, 0);
    expect(interrupted.remainingCount, 1);
    expect(interrupted.sessionId, isNotNull);

    final session = (await quarantine.listSessions()).single;
    expect(session.status, QuarantineStatus.partial);
    expect(session.resumable, isTrue);
    expect(session.pendingCount, 0);
    expect(session.remainingCount, 1);

    final resumed = await quarantine.resumeClean(interrupted.sessionId!);

    expect(resumed.movedCount, 1);
    expect(resumed.skippedCount, 1);
    expect(resumed.failureCount, 0);
    expect(resumed.remainingCount, 0);
    expect(await movable.exists(), isFalse);
    expect(
      (await quarantine.listSessions()).single.status,
      QuarantineStatus.ready,
    );
  });

  test(
    'captures and restores timestamps, read-only and ACL metadata',
    () async {
      final file = await createFile('meta.txt', 'alpha');
      final created = DateTime.utc(2020, 1, 2, 3, 4, 5);
      final modified = DateTime.utc(2021, 2, 3, 4, 5, 6);
      final accessed = DateTime.utc(2022, 3, 4, 5, 6, 7);
      const acl = 'D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;FA;;;S-1-5-21-1)';
      metadata.metadata = FileMetadata(
        created: created,
        modified: modified,
        accessed: accessed,
        readOnly: true,
        acl: acl,
      );

      final report = await clean([await itemFor(file)]);
      final entriesFile = File(
        p.join(temp.path, 'quarantine', report.sessionId!, 'entries.jsonl'),
      );
      final entry = jsonDecode(
        (await entriesFile.readAsLines()).single,
      ) as Map<String, dynamic>;

      expect(entry['created'], created.toIso8601String());
      expect(entry['modified'], modified.toIso8601String());
      expect(entry['accessed'], accessed.toIso8601String());
      expect(entry['readOnly'], isTrue);
      expect(entry['acl'], acl);
      expect(metadata.reads.single.captureAcl, isFalse);

      final undo = await quarantine.undo(report.sessionId!);

      expect(undo.restoredCount, 1);
      expect(undo.metadataFailureCount, 0);
      expect(undo.sessionRemoved, isTrue);
      final applied = metadata.applies.single;
      expect(applied.path, file.path);
      expect(applied.metadata.created, created);
      expect(applied.metadata.modified, modified);
      expect(applied.metadata.accessed, accessed);
      expect(applied.metadata.readOnly, isTrue);
      expect(applied.metadata.acl, acl);
      expect(await file.readAsString(), 'alpha');
    },
    skip: _windowsOnly,
  );

  test(
    'persists and restores POSIX ownership and extended attributes',
    () async {
      final file = await createFile('posix-meta.txt', 'alpha');
      final modified = DateTime.utc(2021, 2, 3, 4, 5, 6);
      const xattrs = {'user.test': 'AQID', 'security.selinux': 'bGFiZWw='};
      metadata.metadata = FileMetadata(
        modified: modified,
        mode: 0x1A4,
        uid: 1000,
        gid: 1001,
        xattrs: xattrs,
      );

      final report = await clean([await itemFor(file)]);
      final entriesFile = File(
        p.join(temp.path, 'quarantine', report.sessionId!, 'entries.jsonl'),
      );
      final entry = jsonDecode(
        (await entriesFile.readAsLines()).single,
      ) as Map<String, dynamic>;

      expect(entry['uid'], 1000);
      expect(entry['gid'], 1001);
      expect(entry['xattrs'], xattrs);

      final undo = await quarantine.undo(report.sessionId!);

      expect(undo.restoredCount, 1);
      expect(undo.metadataFailureCount, 0);
      final applied = metadata.applies.single.metadata;
      expect(applied.uid, 1000);
      expect(applied.gid, 1001);
      expect(applied.xattrs, xattrs);
    },
  );

  test('warns when POSIX extended metadata could not be captured', () async {
    final file = await createFile('posix-meta.txt', 'alpha');
    metadata.metadata = FileMetadata(
      modified: DateTime.utc(2021, 1, 1),
      extendedUnavailable: true,
    );

    final report = await clean([await itemFor(file)]);
    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.metadataFailureCount, 1);
    expect(undo.metadataWarnings.single.reason, contains('扩展属性'));
  });

  test('derives undo metadata from the supplied stat', () async {
    final file = await createFile('derived.txt', 'alpha');
    final stat = await const IoFileSystem().stat(file.path);

    final captured = await const MethodChannelFileMetadataAccess().read(
      file.path,
      stat: stat,
      captureAcl: false,
    );

    // The metadata layer must not query the file again: every restorable value
    // comes from the stat the clean loop already performed.
    expect(captured, isNotNull);
    expect(captured!.created, stat.changed);
    expect(captured.modified, stat.modified);
    expect(captured.accessed, stat.accessed);
    expect(captured.readOnly, isFalse);
    expect(captured.acl, isNull);
    expect(captured.aclUnavailable, isFalse);
  });

  test('reports metadata failures without failing the restore', () async {
    final file = await createFile('meta.txt', 'alpha');
    metadata.metadata = FileMetadata(
      modified: DateTime.utc(2021, 1, 1),
      readOnly: false,
    );
    final report = await clean([await itemFor(file)]);
    metadata.applyError = const FileMetadataException('无法设置 ACL');

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 1);
    expect(undo.failureCount, 0);
    expect(undo.metadataFailureCount, 1);
    expect(undo.metadataWarnings.single.reason, contains('ACL'));
    expect(undo.sessionRemoved, isTrue);
    expect(await file.readAsString(), 'alpha');
  });

  test('warns when ACL capture was unavailable', () async {
    final file = await createFile('meta.txt', 'alpha');
    metadata.metadata = FileMetadata(
      modified: DateTime.utc(2021, 1, 1),
      aclUnavailable: true,
    );
    final report = await clean([await itemFor(file)]);

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.metadataFailureCount, 1);
    expect(undo.metadataWarnings.single.reason, contains('ACL'));
    expect(undo.sessionRemoved, isTrue);
  });

  test('falls back to scan metadata when reading metadata fails', () async {
    final file = await createFile('meta.txt', 'alpha');
    final item = await itemFor(file);
    metadata.readError = const FileMetadataException('元数据不可用');

    final report = await clean([item]);

    expect(report.movedCount, 1);
    expect(report.failureCount, 0);

    final undo = await quarantine.undo(report.sessionId!);

    expect(undo.restoredCount, 1);
    expect(undo.metadataFailureCount, 0);
    expect(
      metadata.applies.single.metadata.modified!.isAtSameMomentAs(
        item.modified,
      ),
      isTrue,
    );
  });

  test('captures ACLs only for cross-volume moves', () {
    expect(
      shouldCaptureAcl(r'C:\cache\a.txt', r'C:\Users\Alice\Broom\quarantine'),
      isFalse,
    );
    expect(
      shouldCaptureAcl(r'D:\cache\a.txt', r'C:\Users\Alice\Broom\quarantine'),
      isTrue,
    );
    expect(
      shouldCaptureAcl(
        r'\\server\share\a.txt',
        r'C:\Users\Alice\Broom\quarantine',
      ),
      isTrue,
    );
  });

  test('records a SHA-256 digest for small quarantine entries', () async {
    final file = await createFile('hashed.txt', 'alpha');
    final report = await clean([await itemFor(file)]);

    final entriesFile = File(
      p.join(temp.path, 'quarantine', report.sessionId!, 'entries.jsonl'),
    );
    final entry = jsonDecode(
      (await entriesFile.readAsLines()).single,
    ) as Map<String, dynamic>;

    expect(entry['size'], 5);
    expect(entry['sha256'], sha256.convert(utf8.encode('alpha')).toString());
  });

  test('refuses to restore a quarantine file whose size changed', () async {
    final file = await createFile('tampered.txt', 'alpha');
    final report = await clean([await itemFor(file)]);

    final entry = (await quarantine.listEntries(report.sessionId!)).single;
    final stored = File(
      p.join(
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
    final report = await clean([await itemFor(file)]);

    final entry = (await quarantine.listEntries(report.sessionId!)).single;
    final stored = File(
      p.join(
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
    final report = await clean([await itemFor(file)]);

    final entriesFile = File(
      p.join(temp.path, 'quarantine', report.sessionId!, 'entries.jsonl'),
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
    final report = await clean([await itemFor(first), await itemFor(second)]);

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
    final report = await clean([await itemFor(first), await itemFor(second)]);

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
    final report = await clean([await itemFor(file)]);
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
    final occupied = File(p.join(source.path, 'conflict (已恢复).txt'));
    await occupied.writeAsString('occupied');
    final report = await clean([await itemFor(file)]);
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
    final restored = File(p.join(source.path, 'conflict (已恢复 2).txt'));
    expect(await restored.readAsString(), 'alpha');
    expect(await quarantine.listSessions(), isEmpty);
  });

  test('overwrites the occupied target after backing it up', () async {
    final file = await createFile('conflict.txt', 'alpha');
    final report = await clean([await itemFor(file)]);
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
    final report = await clean([await itemFor(file)]);
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
    final report = await clean([await itemFor(first), await itemFor(second)]);
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
      await Directory(p.join(temp.path, 'quarantine', report.sessionId!))
          .exists(),
      isFalse,
    );
  });

  test('permanently purges every pending session', () async {
    final first = await createFile('first.txt', 'alpha');
    await clean([await itemFor(first)]);
    final second = await createFile('second.txt', 'bravo');
    await clean([await itemFor(second)]);

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
    final outside = File(p.join(temp.path, 'outside.txt'));
    await outside.writeAsString('keep-me');
    final stat = await outside.stat();

    final report = await clean([
      JunkItem(
        rootIndex: 0,
        path: outside.path,
        size: stat.size,
        modifiedMicros: stat.modified.microsecondsSinceEpoch,
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
        metadataAccess: FakeFileMetadataAccess(),
      ),
      throwsArgumentError,
    );
  });

  test('refuses to clean items inside excluded paths', () async {
    final excludedDir = Directory(p.join(source.path, 'keep'));
    await excludedDir.create(recursive: true);
    final file = await createFile(p.join('keep', 'keep.txt'), 'keep-me');
    final service = QuarantineService(
      quarantineRoot: p.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
      metadataAccess: FakeFileMetadataAccess(),
      exclusions: PathExclusions([excludedDir.path]),
    );

    final report = await service.clean([await itemFor(file)], roots: testRoots);

    expect(report.sessionId, isNull);
    expect(report.movedCount, 0);
    expect(report.skippedCount, 1);
    expect(report.skips.single.reason, contains('排除'));
    expect(report.failureCount, 0);
    expect(await file.readAsString(), 'keep-me');
    expect(await service.listSessions(), isEmpty);
  });

  test('refuses to restore into excluded paths', () async {
    final file = await createFile('keep.txt', 'alpha');
    final report = await clean([await itemFor(file)]);

    final restricted = QuarantineService(
      quarantineRoot: p.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
      metadataAccess: FakeFileMetadataAccess(),
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

  test('classifies a file held by another process as skipped', () async {
    final file = await createFile('locked.txt', 'locked-content');
    final script = File(p.join(temp.path, 'hold_lock.ps1'));
    final ready = File(p.join(temp.path, 'lock.ready'));
    const scriptText = r'''
$ErrorActionPreference = 'Stop'
$target = $args[0]
$ready = $args[1]
$stream = [System.IO.File]::Open($target, 'Open', 'Read', 'None')
try {
  Set-Content -LiteralPath $ready -Value 'ready' -NoNewline
  Start-Sleep -Seconds 60
} finally {
  $stream.Close()
}
''';
    await script.writeAsString(scriptText);
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      file.path,
      ready.path,
    ]);

    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await ready.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('文件锁辅助进程未能在超时前启动');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final report = await clean([await itemFor(file)]);

      expect(report.movedCount, 0);
      expect(report.skippedCount, 1);
      expect(report.skips.single.reason, contains('占用'));
      expect(report.failureCount, 0);
      expect(
        await FileSystemEntity.type(file.path, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(await quarantine.listSessions(), isEmpty);
    } finally {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
    }
    expect(await file.readAsString(), 'locked-content');
  }, skip: Platform.isWindows ? false : 'Windows only');

  test(
    'assesses cross-volume space and aborts before creating a session',
    () async {
      final item = JunkItem(
        rootIndex: 0,
        path: r'D:\cache\large.bin',
        size: 10 * 1024 * 1024,
        modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
      );
      final probed = <String>[];
      final service = QuarantineService(
        quarantineRoot: p.join(temp.path, 'quarantine'),
        guard: PathGuard(protectedRoots: const []),
        metadataAccess: metadata,
        freeSpaceProbe: (path) async {
          probed.add(path);
          return 5 * 1024 * 1024;
        },
      );

      await expectLater(
        service.clean([item], roots: testRoots),
        throwsA(
          isA<QuarantineSpaceException>()
              .having(
                (error) => error.assessment.requiredBytes,
                'requiredBytes',
                item.size,
              )
              .having(
                (error) => error.assessment.freeBytes,
                'freeBytes',
                5 * 1024 * 1024,
              ),
        ),
      );
      expect(probed, [p.windows.rootPrefix(p.join(temp.path, 'quarantine'))]);
      expect(await service.listSessions(), isEmpty);
      expect(
        await Directory(p.join(temp.path, 'quarantine')).exists(),
        isFalse,
      );
    },
  );

  test(
    'skips the preflight for same-volume moves',
    skip: _windowsOnly,
    () async {
      final file = await createFile('same-volume.tmp', 'alpha');
      final item = await itemFor(file);
      var probeCalls = 0;
      final service = QuarantineService(
        quarantineRoot: p.join(temp.path, 'quarantine'),
        guard: PathGuard(protectedRoots: const []),
        metadataAccess: metadata,
        freeSpaceProbe: (_) async {
          probeCalls++;
          return 0;
        },
      );

      final assessment = await service.assessSpace([item]);
      expect(assessment.requiredBytes, 0);
      expect(assessment.crossVolumeCount, 0);
      expect(assessment.sufficient, isTrue);

      final report = await service.clean([item], roots: testRoots);
      expect(probeCalls, 0);
      expect(report.movedCount, 1);
      expect(report.sessionId, isNotNull);
    },
  );

  test(
    'refuses to resume when the remaining plan needs unavailable space',
    skip: _windowsOnly,
    () async {
      final first = await createFile('first.txt', 'alpha');
      final second = await createFile('second.txt', 'bravo');
      var cancel = false;
      final interrupted = await clean(
        [await itemFor(first), await itemFor(second)],
        onProgress: (progress) {
          if (progress.moved >= 1) cancel = true;
        },
        isCancelled: () => cancel,
      );
      final sessionId = interrupted.sessionId!;
      expect(interrupted.cancelled, isTrue);

      final sessionDir = Directory(p.join(temp.path, 'quarantine', sessionId));
      final planFile = File(p.join(sessionDir.path, 'plan.jsonl'));
      final existingPlan = await planFile.readAsString();
      final extra = JunkItem(
        rootIndex: 0,
        path: r'D:\cache\extra.bin',
        size: 4096,
        modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
      );
      await planFile.writeAsString(
        '$existingPlan'
        '${jsonEncode({'originalPath': extra.path, 'rootPath': r'D:\cache', 'ruleId': 'test.rule', 'size': extra.size, 'modified': extra.modified.toUtc().toIso8601String()})}\n',
      );
      final metaFile = File(p.join(sessionDir.path, 'session.json'));
      final meta =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      meta['plannedCount'] = 3;
      meta['remainingCount'] = 2;
      await metaFile.writeAsString(jsonEncode(meta));

      final limited = QuarantineService(
        quarantineRoot: p.join(temp.path, 'quarantine'),
        guard: PathGuard(protectedRoots: const []),
        metadataAccess: metadata,
        freeSpaceProbe: (_) async => 0,
      );

      await expectLater(
        limited.resumeClean(sessionId),
        throwsA(isA<QuarantineSpaceException>()),
      );
      expect(await second.exists(), isTrue);
      expect(await planFile.exists(), isTrue);
      final session = (await limited.listSessions()).single;
      expect(session.status, QuarantineStatus.partial);
      expect(session.remainingCount, 2);
      expect(session.pendingCount, 1);
    },
  );

  test(
    'migrates legacy sessions and refuses unknown schema versions',
    () async {
      final first = await createFile('first.txt', 'alpha');
      final second = await createFile('second.txt', 'bravo');
      final report = await clean([await itemFor(first), await itemFor(second)]);
      final metaFile = File(
        p.join(temp.path, 'quarantine', report.sessionId!, 'session.json'),
      );
      final v1 =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      v1['schemaVersion'] = 1;
      v1.remove('skippedCount');
      v1.remove('updatedAt');
      await metaFile.writeAsString(jsonEncode(v1));

      final sessions = await quarantine.listSessions();
      expect(sessions.single.id, report.sessionId);
      expect(sessions.single.status, QuarantineStatus.ready);

      final entries = await quarantine.listEntries(report.sessionId!);
      final partial = await quarantine.undo(
        report.sessionId!,
        storedNames: {entries.first.storedName},
      );
      expect(partial.restoredCount, 1);

      final rewritten =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      expect(rewritten['schemaVersion'], currentQuarantineSessionSchemaVersion);
      expect(rewritten['skippedCount'], 0);
      expect(rewritten['updatedAt'], isA<String>());

      rewritten.remove('schemaVersion');
      await metaFile.writeAsString(jsonEncode(rewritten));
      expect(await quarantine.listSessions(), hasLength(1));

      rewritten['schemaVersion'] = 99;
      await metaFile.writeAsString(jsonEncode(rewritten));
      expect(await quarantine.listSessions(), isEmpty);
      await expectLater(
        quarantine.listEntries(report.sessionId!),
        throwsA(isA<QuarantineSessionFormatException>()),
      );
      await expectLater(
        quarantine.undo(report.sessionId!),
        throwsA(isA<QuarantineSessionFormatException>()),
      );
      await expectLater(
        quarantine.purgeSession(report.sessionId!),
        throwsA(isA<QuarantineSessionFormatException>()),
      );
    },
  );

  test('applies a conflict policy per entry', () async {
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile('second.txt', 'bravo');
    final third = await createFile('third.txt', 'charlie');
    final report = await clean([
      await itemFor(first),
      await itemFor(second),
      await itemFor(third),
    ]);
    await first.writeAsString('user-first');
    await second.writeAsString('user-second');
    await third.writeAsString('user-third');

    final entries = await quarantine.listEntries(report.sessionId!);
    final byPath = {
      for (final entry in entries) entry.originalPath: entry.storedName,
    };
    final undo = await quarantine.undo(
      report.sessionId!,
      conflictPolicies: {
        byPath[first.path]!: UndoConflictPolicy.keepBoth,
        byPath[second.path]!: UndoConflictPolicy.overwrite,
        byPath[third.path]!: UndoConflictPolicy.skip,
      },
    );

    expect(undo.restoredCount, 2);
    expect(undo.keptBothCount, 1);
    expect(undo.overwrittenCount, 1);
    expect(undo.conflictCount, 1);
    expect(undo.conflicts, hasLength(3));
    expect(
      undo.conflicts
          .firstWhere((conflict) => conflict.originalPath == first.path)
          .applied,
      isTrue,
    );
    expect(
      undo.conflicts
          .firstWhere((conflict) => conflict.originalPath == second.path)
          .applied,
      isTrue,
    );
    expect(
      undo.conflicts
          .firstWhere((conflict) => conflict.originalPath == third.path)
          .applied,
      isFalse,
    );
    expect(await first.readAsString(), 'user-first');
    expect(await second.readAsString(), 'bravo');
    expect(await third.readAsString(), 'user-third');
    final keptBoth = File(p.join(source.path, 'first (已恢复).txt'));
    expect(await keptBoth.readAsString(), 'alpha');
    expect(undo.sessionRemoved, isFalse);
    expect((await quarantine.listSessions()).single.pendingCount, 1);
  });

  test(
    'records cleaning history independently of the session lifecycle',
    () async {
      final history = CleanHistoryStore(
        filePath: p.join(temp.path, 'clean_history.json'),
      );
      final service = QuarantineService(
        quarantineRoot: p.join(temp.path, 'quarantine'),
        guard: PathGuard(protectedRoots: const []),
        metadataAccess: metadata,
        historyStore: history,
      );
      final file = await createFile('history.tmp', 'alpha');

      final report = await service.clean([
        await itemFor(file),
      ], roots: testRoots);

      var records = await history.load();
      expect(records, hasLength(1));
      expect(records.single.sessionId, report.sessionId);
      expect(records.single.outcome, CleanHistoryOutcome.completed);
      expect(records.single.plannedCount, 1);
      expect(records.single.movedCount, 1);
      expect(records.single.movedBytes, report.movedBytes);
      expect(records.single.rules.single.ruleId, 'test.rule');

      await service.purgeSession(report.sessionId!);

      records = await history.load();
      expect(records, hasLength(1));
      expect(records.single.sessionId, report.sessionId);
    },
  );

  test('updates one history record when a cleanup is resumed', () async {
    final history = CleanHistoryStore(
      filePath: p.join(temp.path, 'clean_history.json'),
    );
    final service = QuarantineService(
      quarantineRoot: p.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
      metadataAccess: metadata,
      historyStore: history,
    );
    final first = await createFile('first.txt', 'alpha');
    final second = await createFile('second.txt', 'bravo');
    var cancel = false;

    final interrupted = await service.clean(
      [await itemFor(first), await itemFor(second)],
      roots: testRoots,
      onProgress: (progress) {
        if (progress.moved >= 1) cancel = true;
      },
      isCancelled: () => cancel,
    );

    var records = await history.load();
    expect(records, hasLength(1));
    expect(records.single.outcome, CleanHistoryOutcome.cancelled);
    expect(records.single.movedCount, 1);
    expect(records.single.remainingCount, 1);

    await service.resumeClean(interrupted.sessionId!);

    records = await history.load();
    expect(records, hasLength(1));
    expect(records.single.sessionId, interrupted.sessionId);
    expect(records.single.outcome, CleanHistoryOutcome.completed);
    expect(records.single.movedCount, 2);
    expect(records.single.plannedCount, 2);
    expect(records.single.remainingCount, 0);
  });

  test('a broken history store never fails a cleanup', () async {
    final service = QuarantineService(
      quarantineRoot: p.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const []),
      metadataAccess: metadata,
      // The path is a directory, so every history write must fail.
      historyStore: CleanHistoryStore(filePath: temp.path),
    );
    final file = await createFile('history.tmp', 'alpha');

    final report = await service.clean([await itemFor(file)], roots: testRoots);

    expect(report.movedCount, 1);
    expect(report.failureCount, 0);
    expect(report.sessionId, isNotNull);
  });
}
