import 'dart:collection';
import 'dart:io';

import '../models/scan_models.dart';
import '../platform/file_system.dart';
import '../platform/path_semantics.dart';
import 'ntfs_index.dart';

class JunkScanner {
  JunkScanner({
    required this.jobs,
    this.excludedPaths = const [],
    this.maxItems,
    this.batchSize = 256,
    this.semantics = const WindowsPathSemantics(),
    this.ntfsIndex,
    this.useNtfsIndex = false,
    this.jobIndexBase = 0,
    this.jobCountOverride,
    this.fileSystem = const IoFileSystem(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    for (final path in excludedPaths) {
      _excludedKeys.add(_key(path));
    }
  }

  final List<ScanJob> jobs;
  final List<String> excludedPaths;

  /// Null means unlimited. The former fixed 100,000 cap is intentionally gone;
  /// callers that need a safety limit must pass one explicitly and explain it.
  final int? maxItems;
  final int batchSize;
  final PathSemantics semantics;
  final NtfsIndex? ntfsIndex;
  final bool useNtfsIndex;
  final int jobIndexBase;
  final int? jobCountOverride;
  final BroomFileSystem fileSystem;
  final DateTime Function() _clock;
  final Set<String> _excludedKeys = {};

  String _key(String path) => semantics.key(path);

  Future<ScanResult> scan({
    void Function(ScanProgress progress)? onProgress,
    void Function(List<JunkItem> items)? onItems,
    void Function(ScanIssue issue)? onIssue,
    bool Function()? isCancelled,
    bool retainItems = true,
  }) async {
    final stopwatch = Stopwatch()..start();
    final items = <JunkItem>[];
    final issueList = <ScanIssue>[];
    final batch = <JunkItem>[];
    final seen = <String>{};
    var scannedFiles = 0;
    var foundFiles = 0;
    var foundBytes = 0;
    var truncated = false;
    var cancelled = false;
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    var currentRuleId = jobs.isEmpty ? null : jobs.first.ruleId;

    void flushBatch() {
      if (batch.isEmpty) return;
      onItems?.call(List<JunkItem>.of(batch));
      batch.clear();
    }

    void reportIssue(ScanIssue issue) {
      issueList.add(issue);
      onIssue?.call(issue);
    }

    void report({bool force = false, int jobIndex = 0}) {
      final now = DateTime.now();
      if (!force &&
          now.difference(lastProgressAt) < const Duration(milliseconds: 300)) {
        return;
      }
      lastProgressAt = now;
      onProgress?.call(
        ScanProgress(
          jobIndex: jobIndexBase + jobIndex,
          jobCount: jobCountOverride ?? jobs.length,
          ruleId: currentRuleId,
          scannedFiles: scannedFiles,
          foundFiles: foundFiles,
          foundBytes: foundBytes,
          errorCount: issueList.length,
          elapsed: stopwatch.elapsed,
        ),
      );
    }

    /// Returns true when the configured limit stopped the scan.
    bool acceptItem(JunkItem item) {
      if (!seen.add(_key(item.path))) return false;
      foundFiles++;
      foundBytes += item.size;
      if (retainItems) items.add(item);
      batch.add(item);
      if (batch.length >= batchSize) flushBatch();
      if (maxItems != null && foundFiles >= maxItems!) {
        truncated = true;
        return true;
      }
      return false;
    }

    bool withinJob(ScanJob job, String key, Set<String> jobExcludedKeys) {
      return !_isExcluded(key) &&
          !jobExcludedKeys.any((excluded) => _isWithin(excluded, key));
    }

    Future<void> processCandidate({
      required ScanJob job,
      required String root,
      required String rootKey,
      required String path,
    }) async {
      final entityKey = _key(path);
      if (_isWithin(rootKey, entityKey) == false) return;
      if (!_acceptsExtension(job, path)) return;
      scannedFiles++;
      FsStat stat;
      try {
        stat = await fileSystem.stat(path);
      } on FileSystemException catch (error) {
        reportIssue(_issue(job.ruleId, path, error));
        return;
      }
      if (stat.type != FsEntityType.file) return;
      if (job.minAge > Duration.zero &&
          _clock().difference(stat.modified) < job.minAge) {
        return;
      }
      final stopped = acceptItem(
        JunkItem(
          ruleId: job.ruleId,
          rootPath: root,
          path: path,
          size: stat.size,
          modified: stat.modified,
        ),
      );
      if (stopped) throw const _LimitReached();
    }

    scanLoop:
    for (var localJobIndex = 0; localJobIndex < jobs.length; localJobIndex++) {
      final job = jobs[localJobIndex];
      currentRuleId = job.ruleId;
      final jobExcludedKeys = {
        for (final path in job.excludedRoots) _key(path),
      };
      bool isJobExcluded(String key) =>
          jobExcludedKeys.any((excluded) => _isWithin(excluded, key));
      report(force: true, jobIndex: localJobIndex);

      for (final rawRoot in job.roots) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break scanLoop;
        }
        final root = semantics.canonical(rawRoot);
        final rootKey = _key(root);
        if (isJobExcluded(rootKey)) continue;

        if (useNtfsIndex && ntfsIndex != null) {
          try {
            final availability = await ntfsIndex!.probe(root);
            if (availability.isAvailable) {
              await for (final entry in ntfsIndex!.enumerate(
                root,
                extensions: job.extensions,
                maxItems: maxItems,
                isCancelled: isCancelled,
              )) {
                if (isCancelled?.call() ?? false) {
                  cancelled = true;
                  break scanLoop;
                }
                final entryPath = semantics.canonical(entry.path);
                final entryKey = _key(entryPath);
                if (!withinJob(job, entryKey, jobExcludedKeys)) continue;
                try {
                  await processCandidate(
                    job: job,
                    root: root,
                    rootKey: rootKey,
                    path: entryPath,
                  );
                } on _LimitReached {
                  break scanLoop;
                }
                report(jobIndex: localJobIndex);
              }
              report(force: true, jobIndex: localJobIndex);
              continue;
            }
          } catch (error) {
            if (error is _LimitReached) break scanLoop;
            reportIssue(
              ScanIssue(
                ruleId: job.ruleId,
                path: root,
                kind: classifyScanError(error),
                message: 'NTFS 索引不可用，已回退到目录扫描：$error',
                isDirectory: true,
              ),
            );
          }
        }

        if (await fileSystem.type(root) != FsEntityType.directory) {
          continue;
        }
        if (_isExcluded(rootKey) || isJobExcluded(rootKey)) continue;

        final pending = Queue<({String directory, String root})>();
        pending.add((directory: root, root: root));

        while (pending.isNotEmpty) {
          if (isCancelled?.call() ?? false) {
            cancelled = true;
            break scanLoop;
          }
          final current = pending.removeLast();
          final directoryKey = _key(current.directory);
          if (_isExcluded(directoryKey) || isJobExcluded(directoryKey)) {
            continue;
          }

          try {
            await for (final entity in fileSystem.list(current.directory)) {
              if (isCancelled?.call() ?? false) {
                cancelled = true;
                break scanLoop;
              }
              if (entity.type == FsEntityType.link) continue;
              if (entity.type == FsEntityType.notFound) continue;
              final entityPath = semantics.canonical(entity.path);
              final entityKey = _key(entityPath);
              if (_isExcluded(entityKey) || isJobExcluded(entityKey)) continue;

              if (entity.type == FsEntityType.directory) {
                pending.add((directory: entityPath, root: current.root));
                continue;
              }
              if (entity.type != FsEntityType.file) continue;
              try {
                await processCandidate(
                  job: job,
                  root: current.root,
                  rootKey: rootKey,
                  path: entityPath,
                );
              } on _LimitReached {
                break scanLoop;
              }
              report(jobIndex: localJobIndex);
            }
          } on FileSystemException catch (error) {
            reportIssue(
              _issue(job.ruleId, current.directory, error, isDirectory: true),
            );
          }
        }
      }
      report(force: true, jobIndex: localJobIndex);
    }

    flushBatch();
    report(force: true, jobIndex: jobs.isEmpty ? 0 : jobs.length - 1);
    stopwatch.stop();

    return ScanResult(
      items: items,
      scannedFiles: scannedFiles,
      directoryErrors: issueList.length,
      truncated: truncated,
      cancelled: cancelled,
      issues: issueList,
      elapsed: stopwatch.elapsed,
    );
  }

  bool _acceptsExtension(ScanJob job, String path) {
    final extensions = job.extensions;
    if (extensions == null) return true;
    var extension = semantics.extension(path).toLowerCase();
    if (extension.startsWith('.')) extension = extension.substring(1);
    return extensions.contains(extension);
  }

  bool _isExcluded(String key) =>
      _excludedKeys.any((excluded) => _isWithin(excluded, key));

  bool _isWithin(String rootKey, String candidateKey) =>
      isWithinKey(rootKey, candidateKey, semantics.separator);

  ScanIssue _issue(
    String ruleId,
    String path,
    FileSystemException error, {
    bool isDirectory = false,
  }) {
    final detail = error.osError?.message.trim();
    final message = detail == null || detail.isEmpty ? error.message : detail;
    return ScanIssue(
      ruleId: ruleId,
      path: path,
      kind: classifyScanError(error),
      message: message,
      isDirectory: isDirectory,
    );
  }
}

class _LimitReached implements Exception {
  const _LimitReached();
}
