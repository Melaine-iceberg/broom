import 'dart:convert';

import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/file_metadata_fakes.dart';

void main() {
  const sessionId = '20261019_120000_abcd';
  const quarantineRoot = r'C:\BroomTest\quarantine';
  const sourceRoot = r'C:\BroomTest\source';
  const storedPath = '$quarantineRoot\\$sessionId\\files\\000001_notes.txt';
  const testRoots = ScanRoots([
    ScanRoot(ruleId: 'test.rule', rootPath: sourceRoot),
  ]);

  late MemoryFileSystem fs;
  late QuarantineService service;

  Future<CleanReport> clean(
    List<JunkItem> items, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) => service.clean(
    items,
    roots: testRoots,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  String sessionPath([String child = '']) => child.isEmpty
      ? p.join(quarantineRoot, sessionId)
      : p.join(quarantineRoot, sessionId, child);

  Map<String, Object?> validEntry({
    String originalPath = '$sourceRoot\\notes.txt',
    String rootPath = sourceRoot,
    String storedName = '000001_notes.txt',
    int size = 5,
  }) => {
    'originalPath': originalPath,
    'rootPath': rootPath,
    'storedName': storedName,
    'size': size,
  };

  void writeSession([Map<String, Object?> overrides = const {}]) {
    final meta = <String, Object?>{
      'schemaVersion': 2,
      'id': sessionId,
      'createdAt': '2026-10-19T12:00:00.000Z',
      'status': 'ready',
      'entryCount': 1,
      'totalBytes': 5,
      'pendingCount': 1,
      'pendingBytes': 5,
      'failureCount': 0,
      'skippedCount': 0,
      'plannedCount': 1,
      'remainingCount': 0,
      'updatedAt': '2026-10-19T12:00:00.000Z',
      ...overrides,
    };
    fs.seedFile(sessionPath('session.json'), contents: jsonEncode(meta));
  }

  void writeEntries(List<String> lines) {
    fs.seedFile(sessionPath('entries.jsonl'), contents: lines.join('\n'));
  }

  void seedJournal(List<Object?> entries) {
    writeEntries([
      for (final entry in entries) entry is String ? entry : jsonEncode(entry),
    ]);
  }

  void seedStoredFile([String contents = 'hello']) {
    fs.seedFile(storedPath, contents: contents);
  }

  setUp(() {
    fs = MemoryFileSystem();
    fs.seedDirectory(sourceRoot);
    fs.seedDirectory(p.join(quarantineRoot, sessionId, 'files'));
    service = QuarantineService(
      quarantineRoot: quarantineRoot,
      guard: PathGuard(
        protectedRoots: const [],
        semantics: const WindowsPathSemantics(),
      ),
      metadataAccess: FakeFileMetadataAccess(),
      fileSystem: fs,
      clock: () => DateTime.utc(2026, 10, 19, 12),
    );
  });

  test('rejects unsafe, reserved and overlong session ids', () async {
    const ids = [
      '',
      '.',
      '..',
      '../escape',
      r'..\escape',
      'a/b',
      r'a\b',
      'a:b',
      '.hidden',
      'CON',
      'aux',
    ];
    for (final id in ids) {
      await expectLater(service.listEntries(id), throwsArgumentError);
      await expectLater(service.getSession(id), throwsArgumentError);
      await expectLater(service.undo(id), throwsArgumentError);
      await expectLater(service.resumeClean(id), throwsArgumentError);
      await expectLater(service.purgeSession(id), throwsArgumentError);
    }
    await expectLater(service.getSession('a' * 65), throwsArgumentError);
  });

  test('ignores traversal, reserved and overlong stored names', () async {
    writeSession({'entryCount': 1, 'pendingCount': 1});
    seedStoredFile();
    final overlong = '000009_${'a' * 220}.tmp';
    seedJournal([
      validEntry(),
      validEntry(storedName: r'..\..\escape.txt'),
      validEntry(storedName: '../../escape.txt'),
      validEntry(storedName: 'nested/evil.txt'),
      validEntry(storedName: 'CON'),
      validEntry(storedName: 'aux.txt'),
      validEntry(storedName: 'notes.txt.'),
      validEntry(storedName: 'notes.txt '),
      validEntry(storedName: 'notes:stream.txt'),
      validEntry(storedName: overlong),
    ]);

    final entries = await service.listEntries(sessionId);
    expect(entries, hasLength(1));
    expect(entries.single.storedName, '000001_notes.txt');

    final report = await service.undo(sessionId);
    expect(report.restoredCount, 1);
    expect(report.failureCount, 1);
    expect(report.sessionRemoved, isFalse);
    expect(report.failures.single.reason, contains('无法解析'));
    expect(await fs.readString('$sourceRoot\\notes.txt'), 'hello');
    expect(await fs.type(r'C:\BroomTest\escape.txt'), FsEntityType.notFound);
    expect(await fs.type(r'C:\escape.txt'), FsEntityType.notFound);
    expect(await fs.type(r'C:\nested\evil.txt'), FsEntityType.notFound);
  });

  test('refuses to resume when the journal has invalid records', () async {
    writeSession({
      'status': 'partial',
      'entryCount': 1,
      'pendingCount': 0,
      'pendingBytes': 0,
      'plannedCount': 1,
      'remainingCount': 1,
    });
    fs.seedFile(
      sessionPath('plan.jsonl'),
      contents: jsonEncode({
        ...validEntry(),
        'ruleId': 'test.rule',
        'modified': '2026-10-19T12:00:00.000Z',
      }),
    );
    fs.seedFile('$sourceRoot\\notes.txt', contents: 'hello');
    seedJournal([validEntry(storedName: r'..\escape.txt')]);
    fs.seedFile(p.join(sessionPath(), 'escape.txt'), contents: 'left-behind');

    await expectLater(
      service.resumeClean(sessionId),
      throwsA(isA<StateError>()),
    );
    expect(await fs.readString('$sourceRoot\\notes.txt'), 'hello');
    expect(await fs.type(r'C:\escape.txt'), FsEntityType.notFound);

    final purge = await service.purgeSession(sessionId);
    expect(purge.sessionRemoved, isTrue);
    expect(await fs.type(sessionPath()), FsEntityType.notFound);
  });

  test('ignores records outside their declared root and bad sizes', () async {
    writeSession();
    seedStoredFile();
    seedJournal([
      validEntry(),
      validEntry(originalPath: r'C:\Windows\System32\drivers\evil.sys'),
      validEntry(originalPath: r'C:\BroomTest\source\..\other\evil.txt'),
      validEntry(originalPath: 'relative\\file.txt'),
      validEntry(rootPath: 'relative-root'),
      validEntry(size: -1),
      validEntry(size: 999999999999999999),
      '{"originalPath":"C:\\BroomTest\\source\\truncated.txt","rootPath"',
      'not-json',
      '[]',
    ]);

    final entries = await service.listEntries(sessionId);
    expect(entries.single.storedName, '000001_notes.txt');

    final report = await service.undo(sessionId);
    expect(report.restoredCount, 1);
    expect(report.integrityFailureCount, 0);
    expect(report.failureCount, greaterThan(0));
    expect(report.sessionRemoved, isFalse);
    expect(
      await fs.type(r'C:\Windows\System32\drivers\evil.sys'),
      FsEntityType.notFound,
    );
  });

  test('stops at a truncated JSONL line but keeps earlier entries', () async {
    writeSession();
    seedStoredFile();
    final valid = jsonEncode(validEntry());
    writeEntries([valid, '{"originalPath":"$sourceRoot\\\\half-written.txt"']);

    final entries = await service.listEntries(sessionId);
    expect(entries, hasLength(1));

    final report = await service.undo(sessionId);
    expect(report.restoredCount, 1);
    expect(report.failureCount, 1);
    expect(report.sessionRemoved, isFalse);
    expect(await fs.readString('$sourceRoot\\notes.txt'), 'hello');
  });

  test('does not list sessions with unknown status or corrupt json', () async {
    writeSession({'status': 'quantum'});
    expect(await service.listSessions(), isEmpty);
    await expectLater(
      service.getSession(sessionId),
      throwsA(isA<StateError>()),
    );
    await expectLater(service.undo(sessionId), throwsA(isA<StateError>()));

    fs.seedFile(sessionPath('session.json'), contents: '{"schemaVersion":2,');
    expect(await service.listSessions(), isEmpty);
    await expectLater(
      service.resumeClean(sessionId),
      throwsA(isA<StateError>()),
    );
  });

  test('clamps negative and malformed counters instead of crashing', () async {
    writeSession({
      'entryCount': -5,
      'totalBytes': -100,
      'pendingCount': 1,
      'pendingBytes': 'not-a-number',
      'plannedCount': -1,
      'remainingCount': -2,
    });
    seedStoredFile();
    seedJournal([validEntry()]);

    final sessions = await service.listSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single.entryCount, 0);
    expect(sessions.single.totalBytes, 0);
    expect(sessions.single.pendingCount, 1);
    expect(sessions.single.pendingBytes, 0);
  });

  test('refuses a resume plan that escapes its root', () async {
    writeSession({
      'status': 'partial',
      'entryCount': 0,
      'pendingCount': 0,
      'pendingBytes': 0,
      'plannedCount': 1,
      'remainingCount': 1,
    });
    fs.seedFile(
      sessionPath('plan.jsonl'),
      contents: jsonEncode({
        'originalPath': r'C:\Windows\System32\drivers\evil.sys',
        'rootPath': sourceRoot,
        'ruleId': 'test.rule',
        'size': 1,
        'modified': '2026-10-19T12:00:00.000Z',
      }),
    );
    fs.seedFile(sessionPath('entries.jsonl'), contents: '');

    await expectLater(
      service.resumeClean(sessionId),
      throwsA(isA<StateError>()),
    );
    expect(
      await fs.type(r'C:\Windows\System32\drivers\evil.sys'),
      FsEntityType.notFound,
    );
  });

  test('preserves a session when only invalid entries remain', () async {
    writeSession({
      'status': 'partial',
      'entryCount': 3,
      'pendingCount': 3,
      'pendingBytes': 15,
      'plannedCount': 3,
      'remainingCount': 3,
    });
    seedStoredFile();
    seedJournal([
      validEntry(storedName: r'..\escape.txt'),
      validEntry(originalPath: 'relative'),
      '{"broken"',
    ]);
    fs.seedFile(sessionPath('plan.jsonl'), contents: '');

    final sessions = await service.listSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single.pendingCount, 3);

    final report = await service.undo(sessionId);
    expect(report.restoredCount, 0);
    expect(report.failureCount, 1);
    expect(report.sessionRemoved, isFalse);
    expect(await fs.type(sessionPath()), FsEntityType.directory);
  });

  test('keeps the quarantine service usable after refused metadata', () async {
    writeSession({'status': 'quantum'});
    final item = JunkItem(
      rootIndex: 0,
      path: '$sourceRoot\\fresh.txt',
      size: 5,
      modifiedMicros: DateTime.utc(2026, 10, 19).microsecondsSinceEpoch,
    );
    fs.seedFile('$sourceRoot\\fresh.txt', contents: 'fresh');

    final report = await clean([item]);
    expect(report.sessionId, isNotNull);
    expect(report.movedCount, 1);
    expect(report.failureCount, 0);

    final sessions = await service.listSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single.id, report.sessionId);
    expect(sessions.any((session) => session.id == sessionId), isFalse);
  });

  test('reads each cleaned file once', () async {
    final path = '$sourceRoot\\cache.bin';
    fs.seedFile(path, contents: 'hello');
    final probes = <String>[];
    fs.onOperation = (operation, target) async {
      if (target.toLowerCase() != path.toLowerCase()) return;
      probes.add(operation);
    };

    final report = await clean([
      JunkItem(
        rootIndex: 0,
        path: path,
        size: 5,
        modifiedMicros: DateTime.utc(2026, 10, 19).microsecondsSinceEpoch,
      ),
    ]);

    expect(report.movedCount, 1);
    // Type, size and timestamps come from a single query. A separate `type`
    // probe, or a stat inside the metadata layer, would show up here.
    expect(probes.where((operation) => operation == 'stat'), hasLength(1));
    expect(probes, isNot(contains('type')));
  });
}
