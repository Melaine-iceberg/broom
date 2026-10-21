import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/file_system.dart';
import '../platform/windows_path.dart';
import '../safety/path_guard.dart';

const defaultAnalysisMaxFiles = 200000;

class FileWalkResult {
  const FileWalkResult({
    required this.scannedFiles,
    required this.scannedBytes,
    required this.errorCount,
    required this.truncated,
    required this.cancelled,
    required this.rootMissing,
  });

  final int scannedFiles;
  final int scannedBytes;
  final int errorCount;
  final bool truncated;
  final bool cancelled;
  final bool rootMissing;
}

typedef FileWalkVisitor = void Function(String path, FsStat stat);
typedef FileWalkProgress = void Function(
  int scannedFiles,
  int scannedBytes,
  String currentPath,
);

/// Read-only recursive walker shared by the analysis tools.
///
/// Follows no links, skips excluded subtrees and reports inaccessible entries
/// instead of aborting the whole scan.
///
/// When [fileSystem] can also provide a [DetailedDirectoryListing], the walker
/// reads names, sizes and timestamps from the same enumeration instead of
/// issuing one `stat` per file. [useDetailedListing] lets a spawned isolate
/// disable that path when it cannot reach the native enumerator.
class FileTreeWalker {
  FileTreeWalker({
    required String root,
    this.excludedPaths = const [],
    this.maxFiles = defaultAnalysisMaxFiles,
    this.fileSystem = const IoFileSystem(),
    this.useDetailedListing = true,
  }) : root = _normalize(root) {
    for (final path in excludedPaths) {
      _excludedKeys.add(_key(path));
    }
  }

  final String root;
  final List<String> excludedPaths;
  final int maxFiles;
  final BroomFileSystem fileSystem;
  final bool useDetailedListing;
  final Set<String> _excludedKeys = {};

  static String _normalize(String path) => PathGuard.normalize(path);

  static String _key(String path) => _normalize(path).toLowerCase();

  Future<FileWalkResult> walk({
    required FileWalkVisitor onFile,
    FileWalkProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    var scannedFiles = 0;
    var scannedBytes = 0;
    var errorCount = 0;
    var truncated = false;
    var cancelled = false;
    var lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

    void report(String currentPath, {bool force = false}) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (!force &&
          now.difference(lastReportAt) < const Duration(milliseconds: 160)) {
        return;
      }
      lastReportAt = now;
      onProgress(scannedFiles, scannedBytes, currentPath);
    }

    FileWalkResult build({bool rootMissing = false}) => FileWalkResult(
      scannedFiles: scannedFiles,
      scannedBytes: scannedBytes,
      errorCount: errorCount,
      truncated: truncated,
      cancelled: cancelled,
      rootMissing: rootMissing,
    );

    FsEntityType rootType;
    try {
      rootType = await fileSystem.type(root);
    } on FileSystemException {
      return build(rootMissing: true);
    }
    if (rootType != FsEntityType.directory) {
      return build(rootMissing: true);
    }
    if (_isExcludedKey(_key(root))) {
      return build();
    }

    final detailed =
        useDetailedListing && fileSystem is DetailedDirectoryListing
        ? fileSystem as DetailedDirectoryListing
        : null;

    Stream<({String path, FsEntityType type, int size, DateTime modified})>
    listingOf(String directory) async* {
      if (detailed != null) {
        await for (final entry in detailed.listDetailed(directory)) {
          if (entry.type == FsEntityType.link ||
              entry.type == FsEntityType.notFound) {
            continue;
          }
          final path = WindowsPath.canonical(_join(directory, entry.name));
          if (_isExcludedKey(_key(path))) continue;
          yield (
            path: path,
            type: entry.type,
            size: entry.size,
            modified: entry.modified,
          );
        }
        return;
      }

      await for (final entry in fileSystem.list(directory)) {
        if (entry.type == FsEntityType.link ||
            entry.type == FsEntityType.notFound) {
          continue;
        }
        final path = WindowsPath.canonical(entry.path);
        if (_isExcludedKey(_key(path))) continue;
        if (entry.type == FsEntityType.directory) {
          yield (
            path: path,
            type: FsEntityType.directory,
            size: 0,
            modified: _epoch,
          );
          continue;
        }
        if (entry.type != FsEntityType.file) continue;
        FsStat stat;
        try {
          stat = await fileSystem.stat(path);
        } on FileSystemException {
          errorCount++;
          continue;
        }
        if (stat.type != FsEntityType.file) continue;
        yield (
          path: path,
          type: FsEntityType.file,
          size: stat.size,
          modified: stat.modified,
        );
      }
    }

    final seenDirectories = <String>{_key(root)};
    final pending = Queue<String>()..add(root);

    scanLoop:
    while (pending.isNotEmpty) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final current = pending.removeLast();
      try {
        await for (final listed in listingOf(current)) {
          if (isCancelled?.call() ?? false) {
            cancelled = true;
            break scanLoop;
          }

          if (listed.type == FsEntityType.directory) {
            if (seenDirectories.add(_key(listed.path))) {
              pending.add(listed.path);
            }
            continue;
          }
          if (listed.type != FsEntityType.file) continue;

          if (scannedFiles >= maxFiles) {
            truncated = true;
            break scanLoop;
          }

          scannedFiles++;
          scannedBytes += listed.size;
          onFile(
            listed.path,
            FsStat(
              type: FsEntityType.file,
              size: listed.size,
              modified: listed.modified,
            ),
          );
          report(listed.path);
        }
      } on FileSystemException {
        errorCount++;
      }
    }

    report('', force: true);
    return build();
  }

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  static String _join(String directory, String name) {
    final separator = p.windows.separator;
    return directory.endsWith(separator) || directory.endsWith('/')
        ? '$directory$name'
        : '$directory$separator$name';
  }

  bool _isExcludedKey(String key) =>
      _excludedKeys.any((excluded) => _isWithin(excluded, key));

  static bool _isWithin(String rootKey, String candidateKey) {
    if (candidateKey == rootKey) return true;
    final prefix = rootKey.endsWith(p.windows.separator)
        ? rootKey
        : '$rootKey${p.windows.separator}';
    return candidateKey.startsWith(prefix);
  }
}
