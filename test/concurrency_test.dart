import 'dart:async';
import 'dart:convert';

import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/file_metadata_fakes.dart';

void main() {
  const quarantineRoot = r'C:\BroomConcurrency\quarantine';
  const sourceRoot = r'C:\BroomConcurrency\source';
  const sessionId = '20261019_130000_beef';

  late MemoryFileSystem fs;
  late QuarantineService service;

  setUp(() {
    fs = MemoryFileSystem();
    fs.seedDirectory(sourceRoot);
    fs.seedDirectory(p.windows.join(quarantineRoot, sessionId, 'files'));
    service = QuarantineService(
      quarantineRoot: quarantineRoot,
      guard: PathGuard(protectedRoots: const []),
      metadataAccess: FakeFileMetadataAccess(),
      fileSystem: fs,
      clock: () => DateTime.utc(2026, 10, 19, 13),
    );
  });

  JunkItem item(String path, {int size = 4}) => JunkItem(
    ruleId: 'test.rule',
    rootPath: sourceRoot,
    path: path,
    size: size,
    modified: DateTime.utc(2026, 10, 19),
  );

  void seedSession() {
    fs.seedFile(
      p.windows.join(quarantineRoot, sessionId, 'session.json'),
      contents: jsonEncode({
        'schemaVersion': 2,
        'id': sessionId,
        'createdAt': '2026-10-19T13:00:00.000Z',
        'status': 'ready',
        'entryCount': 1,
        'totalBytes': 5,
        'pendingCount': 1,
        'pendingBytes': 5,
        'failureCount': 0,
        'skippedCount': 0,
        'plannedCount': 1,
        'remainingCount': 0,
        'updatedAt': '2026-10-19T13:00:00.000Z',
      }),
    );
    fs.seedFile(
      p.windows.join(quarantineRoot, sessionId, 'entries.jsonl'),
      contents:
          '${jsonEncode({'originalPath': '$sourceRoot\\notes.txt', 'rootPath': sourceRoot, 'storedName': '000001_notes.txt', 'size': 5})}\n',
    );
    fs.seedFile(
      p.windows.join(quarantineRoot, sessionId, 'files', '000001_notes.txt'),
      contents: 'hello',
    );
  }

  test(
    'serializes clean and purge without interleaving filesystem work',
    () async {
      final renameStarted = Completer<void>();
      final releaseRename = Completer<void>();
      var blockNextRename = true;
      fs.onOperation = (operation, path) async {
        if (operation == 'rename' &&
            path.endsWith(r'\move.txt') &&
            blockNextRename) {
          blockNextRename = false;
          renameStarted.complete();
          await releaseRename.future;
        }
      };
      fs.seedFile('$sourceRoot\\move.txt', contents: 'data');

      final cleanFuture = service.clean([item('$sourceRoot\\move.txt')]);
      await renameStarted.future;
      expect(service.operationInProgress, isTrue);

      var purgeFinished = false;
      final purgeFuture = service.purgeAllSessions().then((value) {
        purgeFinished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        purgeFinished,
        isFalse,
        reason: 'purge must wait for the active clean operation',
      );
      expect(service.operationInProgress, isTrue);

      releaseRename.complete();
      final cleanReport = await cleanFuture;
      expect(cleanReport.movedCount, 1);
      expect(cleanReport.sessionId, isNotNull);

      final purgeReport = await purgeFuture;
      expect(purgeReport.removedCount, 1);
      expect(purgeReport.sessionRemoved, isTrue);
      expect(
        await service.listSessions(),
        isEmpty,
        reason: 'the clean session was purged after the move completed',
      );
    },
  );

  test('allows reads while undo holds the mutation lock', () async {
    seedSession();
    final restoreStarted = Completer<void>();
    final releaseRestore = Completer<void>();
    fs.onOperation = (operation, path) async {
      if (operation == 'rename' && path.endsWith('000001_notes.txt')) {
        if (!restoreStarted.isCompleted) {
          restoreStarted.complete();
          await releaseRestore.future;
        }
      }
    };

    final undoFuture = service.undo(sessionId);
    await restoreStarted.future;
    expect(service.operationInProgress, isTrue);

    // Read-only queries are not blocked by the mutation lock and see the
    // session before the move completes.
    final sessions = await service.listSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single.id, sessionId);

    final queuedPurge = expectLater(
      service.purgeSession(sessionId),
      throwsA(isA<StateError>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.operationInProgress, isTrue);

    releaseRestore.complete();
    final report = await undoFuture;
    expect(report.restoredCount, 1);
    expect(report.sessionRemoved, isTrue);
    expect(await fs.readString('$sourceRoot\\notes.txt'), 'hello');

    await queuedPurge;
    expect(service.operationInProgress, isFalse);
  });

  test(
    'queues a second clean instead of corrupting the first session',
    () async {
      fs.seedFile('$sourceRoot\\first.txt', contents: 'one');
      fs.seedFile('$sourceRoot\\second.txt', contents: 'two');

      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      fs.onOperation = (operation, path) async {
        if (operation == 'rename' &&
            path.endsWith(r'\first.txt') &&
            !firstStarted.isCompleted) {
          firstStarted.complete();
          await releaseFirst.future;
        }
      };

      final first = service.clean([item('$sourceRoot\\first.txt', size: 3)]);
      await firstStarted.future;
      final second = service.clean([item('$sourceRoot\\second.txt', size: 3)]);
      await Future<void>.delayed(Duration.zero);
      expect(await fs.type('$sourceRoot\\second.txt'), FsEntityType.file);

      releaseFirst.complete();
      final firstReport = await first;
      final secondReport = await second;

      expect(firstReport.movedCount, 1);
      expect(secondReport.movedCount, 1);
      expect(firstReport.sessionId, isNot(secondReport.sessionId));
      expect(await service.listSessions(), hasLength(2));
      expect(await fs.type('$sourceRoot\\first.txt'), FsEntityType.notFound);
      expect(await fs.type('$sourceRoot\\second.txt'), FsEntityType.notFound);
    },
  );
}
