import 'dart:collection';
import 'dart:io';

import '../models/scan_models.dart';
import '../platform/file_system.dart';
import '../platform/path_semantics.dart';
import 'ntfs_index.dart';

/// Number of `stat` calls one directory walk keeps in flight.
///
/// Enumeration itself only reveals names; sizes and timestamps need a separate
/// call per file. Awaited one at a time that call is pure latency (the thread
/// idles while the disk queue holds a single request), so the walk pipelines a
/// bounded number of them. 8 keeps the NVMe queue busy without flooding a
/// mechanical disk's reorder window.
const int defaultStatConcurrency = 8;

/// How many files one directory walk buffers before it starts stat-ing them.
const int _fileChunkSize = 512;

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
    this.useDetailedListing = true,
    this.statConcurrency = defaultStatConcurrency,
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

  /// Whether a [DetailedDirectoryListing] file system may be used to obtain
  /// sizes and timestamps from the directory enumeration itself.
  ///
  /// The scan coordinator turns this off for worker isolates that cannot reach
  /// the platform channel; the listing plus per-file `stat` path stays correct
  /// either way.
  final bool useDetailedListing;

  /// Bounded parallelism for per-file `stat` calls inside one directory.
  final int statConcurrency;
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
    ///
    /// [key] lets callers reuse the comparison key they already computed for
    /// the same path; recomputing it dominates the per-file CPU cost.
    bool acceptItem(JunkItem item, {String? key}) {
      if (!seen.add(key ?? _key(item.path))) return false;
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
      required String pathKey,
    }) async {
      if (_isWithin(rootKey, pathKey) == false) return;
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
        key: pathKey,
      );
      if (stopped) throw const _LimitReached();
    }

    /// Stats (when the listing did not provide them) and accepts one chunk of
    /// already-filtered files.
    ///
    /// Enumerations that return metadata leave [files] entries with a stat, so
    /// no extra call is needed at all; for plain listings the `stat` calls run
    /// concurrently, bounded by [statConcurrency]. Results are consumed in
    /// listing order so dedupe and the item cap stay deterministic. Returns true
    /// when the item limit stopped the scan; a cancellation leaves the remaining
    /// entries unfinished and returns false, the caller then checks
    /// `isCancelled` on its next iteration.
    Future<bool> processFiles({
      required ScanJob job,
      required String root,
      required String rootKey,
      required List<({String path, String key, FsStat? stat})> files,
      required int jobIndex,
    }) async {
      if (files.isEmpty) return false;
      final stats = <FsStat?>[for (final file in files) file.stat];
      final errors = List<FileSystemException?>.filled(files.length, null);
      var next = 0;
      final workers = statConcurrency < 1 ? 1 : statConcurrency;

      Future<void> statWorker() async {
        while (true) {
          if (isCancelled?.call() ?? false) return;
          final index = next++;
          if (index >= files.length) return;
          if (stats[index] != null) continue;
          try {
            stats[index] = await fileSystem.stat(files[index].path);
          } on FileSystemException catch (error) {
            errors[index] = error;
          }
          report(jobIndex: jobIndex);
        }
      }

      if (files.any((file) => file.stat == null)) {
        await Future.wait([
          for (var index = 0; index < workers && index < files.length; index++)
            statWorker(),
        ]);
      }

      for (var index = 0; index < files.length; index++) {
        final error = errors[index];
        if (error != null) {
          reportIssue(_issue(job.ruleId, files[index].path, error));
          continue;
        }
        final stat = stats[index];
        if (stat == null) continue;
        if (_isWithin(rootKey, files[index].key) == false) continue;
        if (stat.type != FsEntityType.file) continue;
        if (job.minAge > Duration.zero &&
            _clock().difference(stat.modified) < job.minAge) {
          continue;
        }
        final stopped = acceptItem(
          JunkItem(
            ruleId: job.ruleId,
            rootPath: root,
            path: files[index].path,
            size: stat.size,
            modified: stat.modified,
          ),
          key: files[index].key,
        );
        if (stopped) return true;
      }
      return false;
    }

    // A backend that can return sizes and timestamps with the listing lets the
    // scan skip the per-file `stat` entirely (see DetailedDirectoryListing).
    final detailedListing =
        useDetailedListing && fileSystem is DetailedDirectoryListing
        ? fileSystem as DetailedDirectoryListing
        : null;

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
                    pathKey: entryKey,
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

        Stream<({String path, FsEntityType type, FsStat? stat})> listingOf(
          String directory,
        ) {
          if (detailedListing != null) {
            return detailedListing
                .listDetailed(directory)
                .map(
                  (entry) => (
                    path: _join(directory, entry.name),
                    type: entry.type,
                    stat: FsStat(
                      type: entry.type,
                      size: entry.size,
                      modified: entry.modified,
                    ),
                  ),
                );
          }
          return fileSystem
              .list(directory)
              .map((entry) => (path: entry.path, type: entry.type, stat: null));
        }

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

          // Files are collected per directory and processed in chunks so the
          // per-file `stat` calls pipeline instead of serialising on latency.
          final chunk = <({String path, String key, FsStat? stat})>[];
          try {
            await for (final listed in listingOf(current.directory)) {
              if (isCancelled?.call() ?? false) {
                cancelled = true;
                break scanLoop;
              }
              if (listed.type == FsEntityType.link) continue;
              if (listed.type == FsEntityType.notFound) continue;
              final entityPath = semantics.canonical(listed.path);
              final entityKey = _key(entityPath);
              if (_isExcluded(entityKey) || isJobExcluded(entityKey)) continue;

              if (listed.type == FsEntityType.directory) {
                pending.add((directory: entityPath, root: current.root));
                continue;
              }
              if (listed.type != FsEntityType.file) continue;
              if (!_acceptsExtension(job, entityPath)) continue;
              scannedFiles++;
              chunk.add((path: entityPath, key: entityKey, stat: listed.stat));
              if (chunk.length < _fileChunkSize) continue;
              final stopped = await processFiles(
                job: job,
                root: current.root,
                rootKey: rootKey,
                files: chunk,
                jobIndex: localJobIndex,
              );
              chunk.clear();
              report(jobIndex: localJobIndex);
              if (stopped) break scanLoop;
            }
            if (chunk.isNotEmpty) {
              final stopped = await processFiles(
                job: job,
                root: current.root,
                rootKey: rootKey,
                files: chunk,
                jobIndex: localJobIndex,
              );
              chunk.clear();
              report(jobIndex: localJobIndex);
              if (stopped) break scanLoop;
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
    // Same semantics as `PathSemantics.extension` without parsing the whole
    // path: only the component after the last dot of the basename counts, and
    // a leading dot (".gitignore") is not an extension.
    final dot = path.lastIndexOf('.');
    if (dot <= path.lastIndexOf(semantics.separator) + 1) return false;
    return extensions.contains(path.substring(dot + 1).toLowerCase());
  }

  String _join(String directory, String name) {
    final separator = semantics.separator;
    return directory.endsWith(separator)
        ? '$directory$name'
        : '$directory$separator$name';
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
