// Guards the four per-file costs removed in the P0-5 follow-up (see
// docs/perf-review.md): the finalize-time existence probe, the per-file journal
// `position()`, the per-line plan write and the integrity-hash read.

import 'dart:convert';
import 'dart:io';

import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/file_metadata_fakes.dart';

void main() {
  const quarantineRoot = r'C:\BroomTest\quarantine';
  const sourceRoot = r'C:\BroomTest\source';

  late MemoryFileSystem fs;
  late QuarantineService service;

  setUp(() {
    fs = MemoryFileSystem();
    fs.seedDirectory(sourceRoot);
    service = QuarantineService(
      quarantineRoot: quarantineRoot,
      guard: PathGuard(
        protectedRoots: const [],
        semantics: const WindowsPathSemantics(),
      ),
      metadataAccess: FakeFileMetadataAccess(),
      fileSystem: fs,
      clock: () => DateTime.utc(2026, 10, 20, 12),
    );
  });

  JunkItem item(String name, {int size = 5}) => JunkItem(
    rootIndex: 0,
    path: p.join(sourceRoot, name),
    size: size,
    modifiedMicros: DateTime.utc(2026, 10, 20).microsecondsSinceEpoch,
  );

  const testRoots = ScanRoots([
    ScanRoot(ruleId: 'test.rule', rootPath: sourceRoot),
  ]);

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

  String sessionFile(String sessionId, String child) =>
      p.join(quarantineRoot, sessionId, child);

  Future<List<Map<String, Object?>>> readJournal(String sessionId) async {
    final contents = utf8.decode(
      await fs.readBytes(sessionFile(sessionId, 'entries.jsonl')),
    );
    return [
      for (final line in const LineSplitter().convert(contents))
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];
  }

  group('finalize existence probe', () {
    test('a fully successful clean does not re-probe stored files', () async {
      for (var index = 0; index < 5; index++) {
        fs.seedFile(p.join(sourceRoot, 'cache_$index.tmp'), contents: 'hello');
      }
      final items = [
        for (var index = 0; index < 5; index++) item('cache_$index.tmp'),
      ];
      final probes = <String>[];
      fs.onOperation = (operation, path) async {
        if (operation == 'type' && path.contains(r'\files\')) {
          probes.add(path);
        }
      };

      final report = await clean(items);

      expect(report.movedCount, 5);
      expect(report.failureCount, 0);
      expect(probes, isEmpty);
      final session = (await service.listSessions()).single;
      expect(session.pendingCount, 5);
      expect(session.pendingBytes, 25);
    });

    test('a failed move still probes every entry', () async {
      for (var index = 0; index < 3; index++) {
        fs.seedFile(p.join(sourceRoot, 'cache_$index.tmp'), contents: 'hello');
      }
      final items = [
        for (var index = 0; index < 3; index++) item('cache_$index.tmp'),
      ];
      final probes = <String>[];
      fs.onOperation = (operation, path) async {
        if (operation == 'type' && path.contains(r'\files\')) {
          probes.add(path);
        }
        if ((operation == 'rename' || operation == 'copy') &&
            path.endsWith('cache_1.tmp')) {
          throw const FileSystemException('没有访问权限', '', OSError('文件系统操作失败', 5));
        }
      };

      final report = await clean(items);

      expect(report.movedCount, 2);
      expect(report.failureCount, 1);
      // The surviving entries are probed once each by `_pendingEntries`; the
      // failed one is probed once by the rollback, which is what makes the
      // short circuit unsafe here.
      for (final name in ['cache_0', 'cache_2']) {
        expect(probes.where((path) => path.contains(name)), hasLength(1));
      }
      final session = (await service.listSessions()).single;
      expect(session.pendingCount, 2);
    });
  });

  group('journal offsets', () {
    test('a rolled back record leaves the journal byte exact', () async {
      const names = ['缓存 文件.tmp', '📦.tmp', 'plain.tmp'];
      for (final name in names) {
        fs.seedFile(p.join(sourceRoot, name), contents: 'hello');
      }
      fs.onOperation = (operation, path) async {
        if ((operation == 'rename' || operation == 'copy') &&
            path.endsWith('📦.tmp')) {
          throw const FileSystemException('没有访问权限', '', OSError('文件系统操作失败', 5));
        }
      };

      final report = await clean([for (final name in names) item(name)]);

      expect(report.movedCount, 2);
      expect(report.failureCount, 1);
      // A wrong offset would truncate mid-line and leave either a broken record
      // or a fragment of the failed entry behind.
      final journal = await readJournal(report.sessionId!);
      expect(journal, hasLength(2));
      expect(journal.map((entry) => entry['originalPath']), [
        p.join(sourceRoot, names[0]),
        p.join(sourceRoot, names[2]),
      ]);
    });

    test('resumed runs keep appending at the right offset', () async {
      for (var index = 0; index < 4; index++) {
        fs.seedFile(p.join(sourceRoot, 'cache_$index.tmp'), contents: 'hello');
      }
      var renames = 0;
      fs.onOperation = (operation, path) async {
        if (operation == 'rename' && path.startsWith(sourceRoot)) renames++;
      };

      final first = await clean([
        for (var index = 0; index < 4; index++) item('cache_$index.tmp'),
      ], isCancelled: () => renames >= 2);
      expect(first.cancelled, isTrue);
      expect(first.movedCount, 2);

      final resumed = await service.resumeClean(first.sessionId!);
      expect(resumed.movedCount, 2);
      final journal = await readJournal(first.sessionId!);
      expect(journal, hasLength(4));
      expect(journal.map((entry) => entry['originalPath']).toSet(), {
        for (var index = 0; index < 4; index++)
          p.join(sourceRoot, 'cache_$index.tmp'),
      });
    });
  });

  group('plan batching', () {
    test('writes every item exactly once across batch boundaries', () async {
      const count = 150;
      for (var index = 0; index < count; index++) {
        fs.seedFile(p.join(sourceRoot, 'cache_$index.tmp'), contents: 'hello');
      }
      var renames = 0;
      fs.onOperation = (operation, path) async {
        if (operation == 'rename' && path.startsWith(sourceRoot)) renames++;
      };

      final report = await clean([
        for (var index = 0; index < count; index++) item('cache_$index.tmp'),
      ], isCancelled: () => renames >= 10);
      expect(report.cancelled, isTrue);

      // A cancelled run keeps the plan so cleanup can resume from it.
      final contents = utf8.decode(
        await fs.readBytes(sessionFile(report.sessionId!, 'plan.jsonl')),
      );
      final plan = const LineSplitter()
          .convert(contents)
          .where((line) => line.trim().isNotEmpty)
          .toList();
      expect(plan, hasLength(count));
      expect(
        jsonDecode(plan.first)['originalPath'],
        p.join(sourceRoot, 'cache_0.tmp'),
      );
      expect(
        jsonDecode(plan.last)['originalPath'],
        p.join(sourceRoot, 'cache_${count - 1}.tmp'),
      );
    });
  });

  group('integrity hash read', () {
    test('hashes the whole file, not just the requested prefix', () async {
      final bytes = [for (var index = 0; index < 32; index++) index * 7 % 256];
      final path = p.join(sourceRoot, 'blob.bin');
      fs.seedFile(path, bytes: bytes);

      final report = await clean([item('blob.bin', size: bytes.length)]);

      final journal = await readJournal(report.sessionId!);
      expect(journal.single['sha256'], sha256.convert(bytes).toString());
      expect(journal.single['size'], bytes.length);
    });

    test(
      'falls back to a full read when the file grew after the stat',
      () async {
        final bytes = [for (var index = 0; index < 64; index++) 255 - index];
        final path = p.join(sourceRoot, 'grew.bin');
        // Reports five bytes while holding 64: the same shape a file that grew
        // between the stat and the hash has.
        fs.seedFile(path, bytes: bytes, size: 5);

        final report = await clean([item('grew.bin', size: 5)]);

        final journal = await readJournal(report.sessionId!);
        expect(journal.single['sha256'], sha256.convert(bytes).toString());
      },
    );

    test('skips the hash above the size limit', () async {
      final path = p.join(sourceRoot, 'big.bin');
      fs.seedFile(path, size: 300 * 1024);

      final report = await clean([item('big.bin', size: 300 * 1024)]);

      final journal = await readJournal(report.sessionId!);
      expect(journal.single.containsKey('sha256'), isFalse);
    });
  });

  group('readBytesUpTo', () {
    test('returns the requested prefix from the in-memory backend', () async {
      final path = fs.seedFile(
        p.join(sourceRoot, 'prefix.bin'),
        contents: 'abcdef',
      );

      expect(await fs.readBytesUpTo(path, 3), [97, 98, 99]);
      expect(await fs.readBytesUpTo(path, 6), [97, 98, 99, 100, 101, 102]);
      expect(await fs.readBytesUpTo(path, 99), hasLength(6));
      expect(await fs.readBytesUpTo(path, 0), isEmpty);
    });

    test('matches readBytes on the real filesystem', () async {
      final directory = await Directory.systemTemp.createTemp('broom_prefix');
      addTearDown(() => directory.delete(recursive: true));
      final file = File(p.join(directory.path, 'prefix.bin'));
      await file.writeAsBytes([0, 1, 2, 3, 250, 255]);

      const files = IoFileSystem();
      expect(await files.readBytesUpTo(file.path, 3), [0, 1, 2]);
      expect(await files.readBytesUpTo(file.path, 99), [0, 1, 2, 3, 250, 255]);
      expect(await files.readBytesUpTo(file.path, 0), isEmpty);
    });
  });
}
