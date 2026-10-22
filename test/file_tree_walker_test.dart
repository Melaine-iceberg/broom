import 'dart:io';

import 'package:broom/core/analysis/file_tree_walker.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = r'C:\analysis\root';

  MemoryFileSystem seeded() {
    final fs = MemoryFileSystem();
    fs.seedDirectory(root);
    fs.seedFile(
      r'C:\analysis\root\a.bin',
      size: 300,
      modified: DateTime(2025, 1, 2),
    );
    fs.seedFile(
      r'C:\analysis\root\nested\b.bin',
      size: 120,
      modified: DateTime(2025, 2, 3),
    );
    fs.seedFile(r'C:\analysis\root\nested\small.txt', size: 5);
    fs.seedLink(r'C:\analysis\root\link');
    fs.seedFile(r'C:\analysis\root\skip\c.bin', size: 700);
    return fs;
  }

  test('reads sizes from the detailed listing without per-file stat', () async {
    final fs = seeded();
    final operations = <String>[];
    fs.onOperation = (operation, path) async {
      operations.add('${operation.toLowerCase()}:${path.toLowerCase()}');
    };

    final files = <String, int>{};
    final result = await FileTreeWalker(
      root: root,
      excludedPaths: const [r'C:\analysis\root\skip'],
      fileSystem: fs,
      semantics: const WindowsPathSemantics(),
    ).walk(onFile: (path, stat) => files[path.toLowerCase()] = stat.size);

    expect(result.rootMissing, isFalse);
    expect(result.errorCount, 0);
    expect(result.scannedFiles, 3);
    expect(result.scannedBytes, 425);
    expect(files, {
      r'c:\analysis\root\a.bin': 300,
      r'c:\analysis\root\nested\b.bin': 120,
      r'c:\analysis\root\nested\small.txt': 5,
    });
    expect(
      operations.where((value) => value.startsWith('listdetailed:')),
      hasLength(2),
    );
    expect(operations.where((value) => value.startsWith('stat:')), isEmpty);
  });

  test(
    'falls back to list plus stat when detailed listing is disabled',
    () async {
      final fs = seeded();
      final operations = <String>[];
      fs.onOperation = (operation, path) async {
        operations.add('${operation.toLowerCase()}:${path.toLowerCase()}');
      };

      final files = <String, int>{};
      final result = await FileTreeWalker(
        root: root,
        excludedPaths: const [r'C:\analysis\root\skip'],
        fileSystem: fs,
        useDetailedListing: false,
      ).walk(onFile: (path, stat) => files[path.toLowerCase()] = stat.size);

      expect(result.errorCount, 0);
      expect(files, hasLength(3));
      expect(
        operations.where((value) => value.startsWith('list:')),
        hasLength(2),
      );
      expect(
        operations.where((value) => value.startsWith('stat:')),
        hasLength(3),
      );
    },
  );

  test('counts stat failures in the fallback path', () async {
    final fs = seeded();
    fs.onOperation = (operation, path) {
      if (operation == 'stat' && path.toLowerCase().endsWith('b.bin')) {
        throw const FileSystemException('cannot stat');
      }
    };

    final files = <String>[];
    final result = await FileTreeWalker(
      root: root,
      excludedPaths: const [r'C:\analysis\root\skip'],
      fileSystem: fs,
      semantics: const WindowsPathSemantics(),
      useDetailedListing: false,
    ).walk(onFile: (path, stat) => files.add(path.toLowerCase()));

    expect(result.errorCount, 1);
    expect(files..sort(), [
      r'c:\analysis\root\a.bin',
      r'c:\analysis\root\nested\small.txt',
    ]);
  });

  test('reports a missing root', () async {
    final result = await FileTreeWalker(
      root: r'C:\analysis\missing',
      fileSystem: MemoryFileSystem(),
      semantics: const WindowsPathSemantics(),
    ).walk(onFile: (path, stat) {});

    expect(result.rootMissing, isTrue);
    expect(result.scannedFiles, 0);
  });

  test('stops after maxFiles complete files', () async {
    final fs = MemoryFileSystem();
    fs.seedDirectory(root);
    for (var index = 0; index < 3; index++) {
      fs.seedFile('$root\\f$index.bin', size: 1);
    }

    final seen = <String>[];
    final result = await FileTreeWalker(
      root: root,
      fileSystem: fs,
      semantics: const WindowsPathSemantics(),
      maxFiles: 2,
    ).walk(onFile: (path, stat) => seen.add(path));

    expect(seen, hasLength(2));
    expect(result.scannedFiles, 2);
    expect(result.truncated, isTrue);
  });

  test('reports cancellation without completing the walk', () async {
    final fs = seeded();
    var checks = 0;

    final result = await FileTreeWalker(
      root: root,
      excludedPaths: const [r'C:\analysis\root\skip'],
      fileSystem: fs,
    ).walk(onFile: (path, stat) {}, isCancelled: () => ++checks > 2);

    expect(result.cancelled, isTrue);
  });
}
