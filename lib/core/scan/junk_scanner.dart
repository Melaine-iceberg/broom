import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/scan_models.dart';
import '../platform/windows_path.dart';
import '../safety/path_guard.dart';

const defaultMaxScanItems = 100000;

class JunkScanner {
  JunkScanner({
    required this.jobs,
    this.excludedPaths = const [],
    this.maxItems = defaultMaxScanItems,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    for (final path in excludedPaths) {
      _excludedKeys.add(_key(path));
    }
  }

  final List<ScanJob> jobs;
  final List<String> excludedPaths;
  final int maxItems;
  final DateTime Function() _clock;
  final Set<String> _excludedKeys = {};

  static String _key(String path) => PathGuard.normalize(path).toLowerCase();

  Future<ScanResult> scan({
    void Function(ScanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final items = <JunkItem>[];
    final seen = <String>{};
    var scannedFiles = 0;
    var foundBytes = 0;
    var directoryErrors = 0;
    var truncated = false;
    var cancelled = false;
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    var currentRuleId = jobs.isEmpty ? null : jobs.first.ruleId;

    void report({bool force = false, int jobIndex = 0}) {
      final now = DateTime.now();
      if (!force &&
          now.difference(lastProgressAt) < const Duration(milliseconds: 300)) {
        return;
      }
      lastProgressAt = now;
      onProgress?.call(
        ScanProgress(
          jobIndex: jobIndex,
          jobCount: jobs.length,
          ruleId: currentRuleId,
          scannedFiles: scannedFiles,
          foundFiles: items.length,
          foundBytes: foundBytes,
        ),
      );
    }

    scanLoop:
    for (var jobIndex = 0; jobIndex < jobs.length; jobIndex++) {
      final job = jobs[jobIndex];
      currentRuleId = job.ruleId;
      report(force: true, jobIndex: jobIndex);

      for (final rawRoot in job.roots) {
        final root = WindowsPath.canonical(rawRoot);
        if (await FileSystemEntity.type(
              WindowsPath.forIo(root),
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
          continue;
        }
        final rootKey = _key(root);
        if (_isExcluded(rootKey)) continue;

        final pending = Queue<({String directory, String root})>();
        pending.add((directory: root, root: root));

        while (pending.isNotEmpty) {
          if (isCancelled?.call() ?? false) {
            cancelled = true;
            break scanLoop;
          }
          final current = pending.removeLast();
          final directoryKey = _key(current.directory);
          if (_isExcluded(directoryKey)) continue;

          try {
            await for (final entity in Directory(
              WindowsPath.forIo(current.directory),
            ).list(followLinks: false)) {
              if (isCancelled?.call() ?? false) {
                cancelled = true;
                break scanLoop;
              }
              if (entity is Link) continue;
              final entityPath = WindowsPath.canonical(entity.path);
              final entityKey = _key(entityPath);
              if (_isExcluded(entityKey)) continue;

              if (entity is Directory) {
                pending.add((directory: entityPath, root: current.root));
                continue;
              }
              if (entity is! File) continue;
              if (!_isWithin(rootKey, entityKey)) continue;
              if (!_acceptsExtension(job, entityPath)) continue;

              scannedFiles++;
              FileStat stat;
              try {
                stat = await entity.stat();
              } on FileSystemException {
                directoryErrors++;
                continue;
              }
              if (stat.type != FileSystemEntityType.file) continue;
              if (job.minAge > Duration.zero &&
                  _clock().difference(stat.modified) < job.minAge) {
                continue;
              }
              if (!seen.add(entityKey)) continue;
              if (items.length >= maxItems) {
                truncated = true;
                break scanLoop;
              }

              foundBytes += stat.size;
              items.add(
                JunkItem(
                  ruleId: job.ruleId,
                  rootPath: current.root,
                  path: entityPath,
                  size: stat.size,
                  modified: stat.modified,
                ),
              );
              report(jobIndex: jobIndex);
            }
          } on FileSystemException {
            directoryErrors++;
          }
        }
      }
      report(force: true, jobIndex: jobIndex);
    }

    report(force: true, jobIndex: jobs.isEmpty ? 0 : jobs.length - 1);

    return ScanResult(
      items: items,
      scannedFiles: scannedFiles,
      directoryErrors: directoryErrors,
      truncated: truncated,
      cancelled: cancelled,
    );
  }

  bool _acceptsExtension(ScanJob job, String path) {
    final extensions = job.extensions;
    if (extensions == null) return true;
    var extension = p.windows.extension(path).toLowerCase();
    if (extension.startsWith('.')) extension = extension.substring(1);
    return extensions.contains(extension);
  }

  bool _isExcluded(String key) =>
      _excludedKeys.any((excluded) => _isWithin(excluded, key));

  static bool _isWithin(String rootKey, String candidateKey) {
    if (candidateKey == rootKey) return true;
    final prefix = rootKey.endsWith(p.windows.separator)
        ? rootKey
        : '$rootKey${p.windows.separator}';
    return candidateKey.startsWith(prefix);
  }
}
