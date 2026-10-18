import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

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

typedef FileWalkVisitor = void Function(File file, FileStat stat);
typedef FileWalkProgress = void Function(
  int scannedFiles,
  int scannedBytes,
  String currentPath,
);

/// Read-only recursive walker shared by the analysis tools.
///
/// Follows no links, skips excluded subtrees and reports inaccessible entries
/// instead of aborting the whole scan.
class FileTreeWalker {
  FileTreeWalker({
    required String root,
    this.excludedPaths = const [],
    this.maxFiles = defaultAnalysisMaxFiles,
  }) : root = _normalize(root) {
    for (final path in excludedPaths) {
      _excludedKeys.add(_key(path));
    }
  }

  final String root;
  final List<String> excludedPaths;
  final int maxFiles;
  final Set<String> _excludedKeys = {};

  static String _normalize(String path) =>
      p.windows.normalize(p.windows.absolute(path));

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

    FileSystemEntityType rootType;
    try {
      rootType = await FileSystemEntity.type(root, followLinks: false);
    } on FileSystemException {
      return build(rootMissing: true);
    }
    if (rootType != FileSystemEntityType.directory) {
      return build(rootMissing: true);
    }
    if (_isExcludedKey(_key(root))) {
      return build();
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
        await for (final entity in Directory(
          current,
        ).list(followLinks: false)) {
          if (isCancelled?.call() ?? false) {
            cancelled = true;
            break scanLoop;
          }
          if (entity is Link) continue;
          final entityKey = _key(entity.path);
          if (_isExcludedKey(entityKey)) continue;

          if (entity is Directory) {
            if (seenDirectories.add(entityKey)) {
              pending.add(entity.path);
            }
            continue;
          }
          if (entity is! File) continue;

          if (scannedFiles >= maxFiles) {
            truncated = true;
            break scanLoop;
          }

          FileStat stat;
          try {
            stat = await entity.stat();
          } on FileSystemException {
            errorCount++;
            continue;
          }
          if (stat.type != FileSystemEntityType.file) continue;

          scannedFiles++;
          scannedBytes += stat.size;
          onFile(entity, stat);
          report(entity.path);
        }
      } on FileSystemException {
        errorCount++;
      }
    }

    report('', force: true);
    return build();
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
