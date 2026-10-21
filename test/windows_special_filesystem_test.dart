import 'dart:convert';
import 'dart:io';

import 'package:broom/core/analysis/file_tree_walker.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/windows_path.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/file_metadata_fakes.dart';

final _windowsOnly = Platform.isWindows ? false : 'Windows only';

String? _environmentPath(String key) {
  final value = Platform.environment[key]?.trim();
  if (value == null || value.isEmpty) return null;
  return WindowsPath.canonical(value);
}

void _requireAbsolutePath(String path, String variable) {
  final isDrive = RegExp(r'^[A-Za-z]:\\').hasMatch(path);
  final isUnc = path.startsWith(r'\\');
  if (!isDrive && !isUnc) {
    fail('$variable 必须是盘符或 UNC 绝对路径，当前值：$path');
  }
}

String _uniqueName(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _deepRoot(String base, int levels) {
  var path = base;
  for (var index = 0; index < levels; index++) {
    path = p.windows.join(path, 'd' * 120);
  }
  return path;
}

Future<void> _deleteTreeQuietly(String path) async {
  try {
    await Directory(WindowsPath.forIo(path)).delete(recursive: true);
  } on FileSystemException {
    // Best-effort cleanup of a test directory.
  }
}

Future<void> _assertReadOnly(String root) async {
  final probe = p.windows.join(
    root,
    '.broom_write_probe_${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await File(WindowsPath.forIo(probe)).writeAsString('probe');
  } on FileSystemException {
    return;
  }
  await File(WindowsPath.forIo(probe)).delete();
  fail('BROOM_TEST_READONLY_FILE 所在目录可写，拒绝在可写介质上执行只读验证');
}

/// Scans [testRoot], cleans the nested file into quarantine, restores it and
/// verifies the bytes. [depth] levels of 120-character components push the
/// nested file beyond MAX_PATH when depth >= 3.
Future<({String filePath, List<int> content})> _roundTrip({
  required Directory temp,
  required String testRoot,
  required int depth,
  required String label,
}) async {
  final deepRoot = _deepRoot(testRoot, depth);
  final filePath = p.windows.join(deepRoot, 'sample.bin');
  final content = List<int>.generate(4096, (index) => (index * 31) % 256);
  await Directory(WindowsPath.forIo(deepRoot)).create(recursive: true);
  await File(WindowsPath.forIo(filePath)).writeAsBytes(content);

  final scan = await JunkScanner(
    jobs: [
      ScanJob(ruleId: 'fs.$label', roots: [testRoot]),
    ],
  ).scan();
  expect(scan.directoryErrors, 0);
  final item = scan.items.singleWhere(
    (candidate) => candidate.path.toLowerCase() == filePath.toLowerCase(),
  );
  expect(item.path, isNot(startsWith(r'\\?\')), reason: '记录必须使用规范路径');
  expect(item.path.toLowerCase(), startsWith(testRoot.toLowerCase()));

  final walked = <String>[];
  final walk = await FileTreeWalker(root: testRoot)
      .walk(onFile: (path, stat) => walked.add(path));
  expect(walk.rootMissing, isFalse);
  expect(
    walked.map((path) => path.toLowerCase()),
    contains(filePath.toLowerCase()),
  );

  final quarantine = QuarantineService(
    quarantineRoot: p.windows.join(temp.path, 'quarantine_$label'),
    guard: PathGuard(protectedRoots: const []),
    metadataAccess: FakeFileMetadataAccess(),
  );
  final report = await quarantine.clean([item]);
  expect(report.movedCount, 1, reason: '${report.failures}');
  expect(report.failureCount, 0, reason: '${report.failures}');
  expect(await File(WindowsPath.forIo(filePath)).exists(), isFalse);

  final undo = await quarantine.undo(report.sessionId!);
  expect(undo.restoredCount, 1, reason: '${undo.failures}');
  expect(undo.failureCount, 0, reason: '${undo.failures}');
  expect(await File(WindowsPath.forIo(filePath)).readAsBytes(), content);
  expect(await quarantine.listSessions(), isEmpty);
  return (filePath: filePath, content: content);
}

void main() {
  group('long paths', () {
    test('scans, cleans and restores a file beyond MAX_PATH', () async {
      final temp = await Directory.systemTemp.createTemp('broom_long_path_');
      try {
        final testRoot = p.windows.join(temp.path, 'cache');
        await Directory(WindowsPath.forIo(testRoot)).create(recursive: true);
        final result = await _roundTrip(
          temp: temp,
          testRoot: testRoot,
          depth: 3,
          label: 'long',
        );
        expect(result.filePath.length, greaterThan(260));
      } finally {
        await _deleteTreeQuietly(temp.path);
      }
    }, skip: _windowsOnly);

    test('restores a long path after cleanup removed its folders', () async {
      final temp = await Directory.systemTemp.createTemp('broom_long_undo_');
      try {
        final testRoot = p.windows.join(temp.path, 'cache');
        await Directory(WindowsPath.forIo(testRoot)).create(recursive: true);
        final deepRoot = _deepRoot(testRoot, 3);
        final filePath = p.windows.join(deepRoot, 'removed.bin');
        await Directory(WindowsPath.forIo(deepRoot)).create(recursive: true);
        await File(WindowsPath.forIo(filePath)).writeAsString('long');

        final quarantine = QuarantineService(
          quarantineRoot: p.windows.join(temp.path, 'quarantine'),
          guard: PathGuard(protectedRoots: const []),
          metadataAccess: FakeFileMetadataAccess(),
        );
        final stat = await File(WindowsPath.forIo(filePath)).stat();
        final report = await quarantine.clean([
          JunkItem(
            ruleId: 'test.long',
            rootPath: testRoot,
            path: filePath,
            size: stat.size,
            modified: stat.modified,
          ),
        ]);
        expect(report.movedCount, 1);
        expect(report.removedDirectoryCount, 3);
        expect(await Directory(WindowsPath.forIo(deepRoot)).exists(), isFalse);

        final undo = await quarantine.undo(report.sessionId!);
        expect(undo.restoredCount, 1, reason: '${undo.failures}');
        expect(await File(WindowsPath.forIo(filePath)).readAsString(), 'long');
      } finally {
        await _deleteTreeQuietly(temp.path);
      }
    }, skip: _windowsOnly);
  });

  group('UNC', () {
    final uncRoot = _environmentPath('BROOM_TEST_UNC_ROOT');
    final skip = !Platform.isWindows
        ? 'Windows only'
        : uncRoot == null
        ? 'Set BROOM_TEST_UNC_ROOT to run UNC validation'
        : false;

    test('scans, cleans and restores over a UNC share', () async {
      _requireAbsolutePath(uncRoot!, 'BROOM_TEST_UNC_ROOT');
      final temp = await Directory.systemTemp.createTemp('broom_unc_');
      final testRoot = p.windows.join(uncRoot, _uniqueName('broom_unc'));
      try {
        await Directory(WindowsPath.forIo(testRoot)).create(recursive: true);
        final result = await _roundTrip(
          temp: temp,
          testRoot: testRoot,
          depth: 3,
          label: 'unc',
        );
        expect(result.filePath.length, greaterThan(260));
      } finally {
        await _deleteTreeQuietly(testRoot);
        await _deleteTreeQuietly(temp.path);
      }
    }, skip: skip);
  });

  group('FAT / exFAT', () {
    final fatRoot = _environmentPath('BROOM_TEST_FAT_ROOT');
    final skip = !Platform.isWindows
        ? 'Windows only'
        : fatRoot == null
        ? 'Set BROOM_TEST_FAT_ROOT to run FAT/exFAT validation'
        : false;

    test('scans, cleans and restores on a FAT/exFAT volume', () async {
      _requireAbsolutePath(fatRoot!, 'BROOM_TEST_FAT_ROOT');
      final temp = await Directory.systemTemp.createTemp('broom_fat_');
      final testRoot = p.windows.join(fatRoot, _uniqueName('broom_fat'));
      try {
        await Directory(WindowsPath.forIo(testRoot)).create(recursive: true);
        await _roundTrip(
          temp: temp,
          testRoot: testRoot,
          depth: 2,
          label: 'fat',
        );
      } finally {
        await _deleteTreeQuietly(testRoot);
        await _deleteTreeQuietly(temp.path);
      }
    }, skip: skip);
  });

  group('network drive', () {
    final networkRoot = _environmentPath('BROOM_TEST_NETWORK_ROOT');
    final skip = !Platform.isWindows
        ? 'Windows only'
        : networkRoot == null
        ? 'Set BROOM_TEST_NETWORK_ROOT to run network drive validation'
        : false;

    test('scans, cleans and restores on a mapped network drive', () async {
      _requireAbsolutePath(networkRoot!, 'BROOM_TEST_NETWORK_ROOT');
      final temp = await Directory.systemTemp.createTemp('broom_network_');
      final testRoot = p.windows.join(networkRoot, _uniqueName('broom_net'));
      try {
        await Directory(WindowsPath.forIo(testRoot)).create(recursive: true);
        final result = await _roundTrip(
          temp: temp,
          testRoot: testRoot,
          depth: 3,
          label: 'network',
        );
        expect(result.filePath.length, greaterThan(260));
      } finally {
        await _deleteTreeQuietly(testRoot);
        await _deleteTreeQuietly(temp.path);
      }
    }, skip: skip);
  });

  group('read-only media', () {
    final readOnlyFile = _environmentPath('BROOM_TEST_READONLY_FILE');
    final skip = !Platform.isWindows
        ? 'Windows only'
        : readOnlyFile == null
        ? 'Set BROOM_TEST_READONLY_FILE to run read-only media validation'
        : false;

    test('reports a failed clean and leaves the source intact', () async {
      _requireAbsolutePath(readOnlyFile!, 'BROOM_TEST_READONLY_FILE');
      final filePath = readOnlyFile;
      final root = p.windows.dirname(filePath);
      await _assertReadOnly(root);

      final stat = await File(WindowsPath.forIo(filePath)).stat();
      final scan = await JunkScanner(
        jobs: [
          ScanJob(ruleId: 'fs.readonly', roots: [root]),
        ],
        maxItems: 50000,
      ).scan();
      expect(scan.directoryErrors, 0);
      expect(
        scan.items.map((item) => item.path.toLowerCase()),
        contains(filePath.toLowerCase()),
      );

      final temp = await Directory.systemTemp.createTemp('broom_readonly_');
      try {
        final quarantine = QuarantineService(
          quarantineRoot: p.windows.join(temp.path, 'quarantine'),
          guard: PathGuard(protectedRoots: const []),
          metadataAccess: FakeFileMetadataAccess(),
        );
        final report = await quarantine.clean([
          JunkItem(
            ruleId: 'fs.readonly',
            rootPath: root,
            path: filePath,
            size: stat.size,
            modified: stat.modified,
          ),
        ]);

        expect(report.movedCount, 0);
        expect(report.failureCount, 1);
        expect(
          report.failures.single.reason,
          anyOf(contains('只读'), contains('没有访问权限')),
        );
        expect(await File(WindowsPath.forIo(filePath)).exists(), isTrue);
        expect(await quarantine.listSessions(), isEmpty);
      } finally {
        await _deleteTreeQuietly(temp.path);
      }
    }, skip: skip);

    test('keeps the quarantined file when restore cannot be written', () async {
      _requireAbsolutePath(readOnlyFile!, 'BROOM_TEST_READONLY_FILE');
      final filePath = readOnlyFile;
      final root = p.windows.dirname(filePath);
      await _assertReadOnly(root);

      final temp = await Directory.systemTemp.createTemp(
        'broom_readonly_undo_',
      );
      try {
        final sourceDir = Directory(p.windows.join(temp.path, 'source'));
        await sourceDir.create(recursive: true);
        final sourceFile = File(p.windows.join(sourceDir.path, 'recover.txt'));
        await sourceFile.writeAsString('recoverable');

        final quarantine = QuarantineService(
          quarantineRoot: p.windows.join(temp.path, 'quarantine'),
          guard: PathGuard(protectedRoots: const []),
          metadataAccess: FakeFileMetadataAccess(),
        );
        final stat = await sourceFile.stat();
        final report = await quarantine.clean([
          JunkItem(
            ruleId: 'fs.readonly',
            rootPath: sourceDir.path,
            path: sourceFile.path,
            size: stat.size,
            modified: stat.modified,
          ),
        ]);
        expect(report.movedCount, 1);
        final sessionId = report.sessionId!;

        // Point the recorded entry at a missing file on the read-only medium.
        // The stored bytes stay valid, so undo must attempt the write and fail
        // without discarding the quarantine copy.
        final sessionDir = Directory(
          p.windows.join(temp.path, 'quarantine', sessionId),
        );
        final entriesFile = File(
          p.windows.join(sessionDir.path, 'entries.jsonl'),
        );
        final entry = jsonDecode(
          (await entriesFile.readAsLines()).single,
        ) as Map<String, dynamic>;
        final missingPath = p.windows.join(
          root,
          '.broom_missing_restore_${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        entry['originalPath'] = missingPath;
        entry['rootPath'] = root;
        await entriesFile.writeAsString('${jsonEncode(entry)}\n');

        final undo = await quarantine.undo(sessionId);

        expect(undo.restoredCount, 0);
        expect(undo.failureCount, 1);
        expect(
          undo.failures.single.reason,
          anyOf(contains('只读'), contains('没有访问权限')),
        );
        expect(await quarantine.listSessions(), hasLength(1));
        final stored = File(
          p.windows.join(
            sessionDir.path,
            'files',
            entry['storedName'] as String,
          ),
        );
        expect(await stored.exists(), isTrue);
        await quarantine.purgeSession(sessionId);
      } finally {
        await _deleteTreeQuietly(temp.path);
      }
    }, skip: skip);
  });
}
