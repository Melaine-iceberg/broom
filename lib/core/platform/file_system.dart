import 'dart:io';

import 'directory_enum.dart';
import 'windows_path.dart';

/// Minimal filesystem surface used by the scan and quarantine engines.
///
/// Production code uses [IoFileSystem]; tests and benchmarks can provide an
/// in-memory implementation instead of relying on real temporary directories,
/// disk timing or platform-specific attributes. Errors keep using
/// [FileSystemException] so existing error classification stays valid.
enum FsEntityType { file, directory, link, notFound }

class FsStat {
  const FsStat({
    required this.type,
    required this.size,
    required this.modified,
    this.mode = 0,
  });

  final FsEntityType type;
  final int size;
  final DateTime modified;
  final int mode;
}

class FsEntry {
  const FsEntry({required this.path, required this.type});

  final String path;
  final FsEntityType type;
}

/// A directory child returned together with the metadata a scan needs.
///
/// [name] is the last path component only: enumerating a large directory should
/// not repeat the parent path once per child.
class FsEntryDetail {
  const FsEntryDetail({
    required this.name,
    required this.type,
    required this.size,
    required this.modified,
  });

  final String name;
  final FsEntityType type;
  final int size;
  final DateTime modified;
}

/// Optional capability: list a directory with sizes and timestamps included.
///
/// `list` only yields names, so a scanner that needs sizes must issue one
/// `stat` per child. A backend that can obtain both from the same enumeration
/// (Windows `FindFirstFileW`) implements this instead, halving the number of
/// system calls per file. Callers must treat it as an optional fast path and
/// keep the `list` + `stat` fallback.
abstract interface class DetailedDirectoryListing {
  /// Direct children of [path], without following links.
  Stream<FsEntryDetail> listDetailed(String path);
}

/// Append-mode file handle. Mirrors the subset of `RandomAccessFile` the
/// quarantine journal relies on so rollback of an unwritten entry can be
/// tested without touching disk.
abstract interface class FsFileWriter {
  Future<int> position();
  Future<void> setPosition(int position);
  Future<void> writeString(String contents);
  Future<void> flush();
  Future<void> truncate(int length);
  Future<void> close();
}

abstract interface class BroomFileSystem {
  Future<FsEntityType> type(String path);

  Future<FsStat> stat(String path);

  /// Direct children of [path], without following links.
  Stream<FsEntry> list(String path);

  Future<void> createDirectory(String path, {bool recursive = true});

  Future<String> readString(String path);

  Future<List<String>> readLines(String path);

  Future<List<int>> readBytes(String path);

  Future<void> writeString(
    String path,
    String contents, {
    bool append = false,
    bool flush = true,
  });

  Future<FsFileWriter> openAppend(String path);

  /// Opens a handle positioned at the start, truncating any existing file.
  Future<FsFileWriter> openWrite(String path);

  Future<void> rename(String from, String to);

  Future<void> copy(String from, String to);

  Future<void> deleteFile(String path);

  Future<void> deleteDirectory(String path, {bool recursive = false});

  Future<int> length(String path);
}

/// Filesystem backed by `dart:io`.
///
/// Directory listings first try the native Windows enumerator, which returns
/// names together with sizes and timestamps; everything else (and every other
/// platform) keeps using `Directory.list` plus `stat`.
class IoFileSystem implements BroomFileSystem, DetailedDirectoryListing {
  const IoFileSystem();

  static final MethodChannelDirectoryEnumerator _enumerator =
      MethodChannelDirectoryEnumerator();

  @override
  Future<FsEntityType> type(String path) async {
    final value = await FileSystemEntity.type(
      WindowsPath.forIo(path),
      followLinks: false,
    );
    return _mapType(value);
  }

  @override
  Future<FsStat> stat(String path) async {
    final stat = await FileStat.stat(WindowsPath.forIo(path));
    return FsStat(
      type: _mapType(stat.type),
      size: stat.size,
      modified: stat.modified,
      mode: stat.mode,
    );
  }

  @override
  Stream<FsEntry> list(String path) {
    return Directory(WindowsPath.forIo(path))
        .list(followLinks: false)
        .map((entity) => FsEntry(path: entity.path, type: _mapEntity(entity)));
  }

  @override
  Stream<FsEntryDetail> listDetailed(String path) async* {
    final entries = await _enumerator.list(path);
    if (entries != null) {
      yield* Stream<FsEntryDetail>.fromIterable(entries);
      return;
    }
    yield* _listDetailedWithStat(path);
  }

  /// Fallback for environments without the native enumerator: list names, then
  /// stat every child. Children that cannot be stat-ed are skipped, matching the
  /// scanner's previous per-file behaviour.
  Stream<FsEntryDetail> _listDetailedWithStat(String path) async* {
    await for (final entity in list(path)) {
      if (entity.type == FsEntityType.notFound) continue;
      var size = 0;
      var modified = DateTime.fromMillisecondsSinceEpoch(0);
      if (entity.type == FsEntityType.file) {
        try {
          final value = await stat(entity.path);
          size = value.size;
          modified = value.modified;
        } on FileSystemException {
          continue;
        }
      }
      yield FsEntryDetail(
        name: _leafName(entity.path),
        type: entity.type,
        size: size,
        modified: modified,
      );
    }
  }

  static String _leafName(String path) {
    final backslash = path.lastIndexOf(r'\');
    final slash = path.lastIndexOf('/');
    final cut = backslash > slash ? backslash : slash;
    return cut < 0 ? path : path.substring(cut + 1);
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) {
    return Directory(WindowsPath.forIo(path)).create(recursive: recursive);
  }

  @override
  Future<String> readString(String path) =>
      File(WindowsPath.forIo(path)).readAsString();

  @override
  Future<List<String>> readLines(String path) =>
      File(WindowsPath.forIo(path)).readAsLines();

  @override
  Future<List<int>> readBytes(String path) =>
      File(WindowsPath.forIo(path)).readAsBytes();

  @override
  Future<void> writeString(
    String path,
    String contents, {
    bool append = false,
    bool flush = true,
  }) {
    return File(WindowsPath.forIo(path)).writeAsString(
      contents,
      mode: append ? FileMode.append : FileMode.write,
      flush: flush,
    );
  }

  @override
  Future<FsFileWriter> openAppend(String path) async {
    final file = await File(WindowsPath.forIo(path))
        .open(mode: FileMode.append);
    return _IoFileWriter(file);
  }

  @override
  Future<FsFileWriter> openWrite(String path) async {
    final file = await File(WindowsPath.forIo(path)).open(mode: FileMode.write);
    return _IoFileWriter(file);
  }

  @override
  Future<void> rename(String from, String to) {
    return File(WindowsPath.forIo(from)).rename(WindowsPath.forIo(to));
  }

  @override
  Future<void> copy(String from, String to) {
    return File(WindowsPath.forIo(from)).copy(WindowsPath.forIo(to));
  }

  @override
  Future<void> deleteFile(String path) {
    return File(WindowsPath.forIo(path)).delete();
  }

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) {
    return Directory(WindowsPath.forIo(path)).delete(recursive: recursive);
  }

  @override
  Future<int> length(String path) => File(WindowsPath.forIo(path)).length();

  static FsEntityType _mapType(FileSystemEntityType value) {
    return switch (value) {
      FileSystemEntityType.file => FsEntityType.file,
      FileSystemEntityType.directory => FsEntityType.directory,
      FileSystemEntityType.link => FsEntityType.link,
      _ => FsEntityType.notFound,
    };
  }

  static FsEntityType _mapEntity(FileSystemEntity entity) {
    if (entity is Link) return FsEntityType.link;
    if (entity is Directory) return FsEntityType.directory;
    if (entity is File) return FsEntityType.file;
    return FsEntityType.notFound;
  }
}

class _IoFileWriter implements FsFileWriter {
  _IoFileWriter(this._file);

  final RandomAccessFile _file;

  @override
  Future<int> position() => _file.position();

  @override
  Future<void> setPosition(int position) => _file.setPosition(position);

  @override
  Future<void> writeString(String contents) => _file.writeString(contents);

  @override
  Future<void> flush() => _file.flush();

  @override
  Future<void> truncate(int length) => _file.truncate(length);

  @override
  Future<void> close() => _file.close();
}
