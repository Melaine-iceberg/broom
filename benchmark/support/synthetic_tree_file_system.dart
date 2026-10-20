import 'dart:io';

import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/windows_path.dart';
import 'package:path/path.dart' as p;

/// Lazily generated Windows-like cache tree for large scan benchmarks.
///
/// A flat set of cache directories avoids allocating one million map entries.
/// Directory listings and file stats are synthesized on demand, which keeps the
/// benchmark focused on the scanning engine instead of fixture setup.
class SyntheticTreeFileSystem implements BroomFileSystem {
  SyntheticTreeFileSystem({
    this.root = r'C:\Bench\Cache',
    this.directoryCount = 100,
    this.filesPerDirectory = 1000,
    this.fileSize = 4096,
    DateTime? modified,
  }) : modified = modified ?? DateTime.utc(2026, 10, 01);

  final String root;
  final int directoryCount;
  final int filesPerDirectory;
  final int fileSize;
  final DateTime modified;

  String get rootKey => p.windows.normalize(root).toLowerCase();

  String directoryPath(int index) =>
      p.windows.join(root, 'd${index.toString().padLeft(4, '0')}');

  String filePath(int directory, int file) =>
      p.windows.join(directoryPath(directory), 'f$file.tmp');

  bool _isDirectoryPath(String path) {
    final normalized = p.windows.normalize(WindowsPath.canonical(path));
    if (normalized.toLowerCase() == rootKey) return true;
    final relative = p.windows.relative(normalized, from: root);
    if (relative.startsWith('..')) return false;
    return !relative.contains(p.windows.separator) && relative.isNotEmpty;
  }

  ({int directory, int file})? _parseFilePath(String path) {
    final normalized = p.windows.normalize(WindowsPath.canonical(path));
    final relative = p.windows.relative(normalized, from: root);
    final parts = p.windows.split(relative);
    if (parts.length != 2) return null;
    final directory = int.tryParse(
      parts[0].startsWith('d') ? parts[0].substring(1) : '',
    );
    if (directory == null || directory >= directoryCount) return null;
    final fileName = parts[1];
    if (!fileName.startsWith('f') || !fileName.endsWith('.tmp')) return null;
    final file = int.tryParse(fileName.substring(1, fileName.length - 4));
    if (file == null || file >= filesPerDirectory) return null;
    return (directory: directory, file: file);
  }

  @override
  Future<FsEntityType> type(String path) async {
    if (_isDirectoryPath(path)) return FsEntityType.directory;
    if (_parseFilePath(path) != null) return FsEntityType.file;
    return FsEntityType.notFound;
  }

  @override
  Future<FsStat> stat(String path) async {
    if (_isDirectoryPath(path)) {
      return FsStat(type: FsEntityType.directory, size: 0, modified: modified);
    }
    if (_parseFilePath(path) != null) {
      return FsStat(
        type: FsEntityType.file,
        size: fileSize,
        modified: modified,
      );
    }
    throw FileSystemException('not found', path, const OSError('not found', 2));
  }

  @override
  Stream<FsEntry> list(String path) async* {
    final normalized = p.windows.normalize(WindowsPath.canonical(path));
    if (normalized.toLowerCase() == rootKey) {
      for (var index = 0; index < directoryCount; index++) {
        yield FsEntry(path: directoryPath(index), type: FsEntityType.directory);
      }
      return;
    }
    if (!_isDirectoryPath(normalized)) {
      throw FileSystemException(
        'not a directory',
        path,
        const OSError('not found', 3),
      );
    }
    final relative = p.windows.relative(normalized, from: root);
    final directory = int.parse(relative.substring(1));
    for (var file = 0; file < filesPerDirectory; file++) {
      yield FsEntry(path: filePath(directory, file), type: FsEntityType.file);
    }
  }

  @override
  Future<int> length(String path) async => fileSize;

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<String> readString(String path) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<List<String>> readLines(String path) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<List<int>> readBytes(String path) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<List<int>> readBytesUpTo(String path, int limit) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<void> writeString(
    String path,
    String contents, {
    bool append = false,
    bool flush = true,
  }) => throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<FsFileWriter> openAppend(String path) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<FsFileWriter> openWrite(String path) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<void> rename(String from, String to) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<void> copy(String from, String to) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<void> deleteFile(String path) =>
      throw UnsupportedError('benchmark filesystem is read-only');

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) =>
      throw UnsupportedError('benchmark filesystem is read-only');
}
