import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/clean_history_models.dart';
import '../models/clean_models.dart';
import '../models/scan_models.dart';
import '../platform/async_mutex.dart';
import '../platform/file_system.dart';
import '../platform/filesystem_error.dart';
import '../platform/path_semantics.dart';
import '../platform/windows_path.dart';
import '../safety/path_exclusions.dart';
import '../safety/path_guard.dart';
import 'clean_history_store.dart';
import 'file_metadata.dart';
import 'quarantine_session_schema.dart';

const _schemaVersion = currentQuarantineSessionSchemaVersion;
const _maxFailureDetails = 100;
const _maxAclLength = 64 * 1024;
const _maxStoredNameLength = 200;
const _maxSessionIdLength = 64;

/// Files below this size get a full SHA-256 in the undo record.
///
/// Hashing is a full read of the file that the move does not otherwise need,
/// and this cleaner mostly handles caches with tens of thousands of small
/// files. The digest runs on the UI isolate, so the cap also bounds the worst
/// frame hitch to a few milliseconds; files above the cap are verified by size
/// on restore, exactly like files above the former 32 MiB limit.
const _integrityHashLimitBytes = 256 * 1024;

/// How many undo records are appended before the journal is flushed to disk.
///
/// Each flush is a `FlushFileBuffers` on Windows — a device-wide barrier that
/// costs about as much as the file move itself. Records still reach the OS
/// before the file is moved, so a process crash leaves them intact; only a
/// power loss can drop the last partial batch, and the affected files stay in
/// the quarantine and can be restored or purged from their stored names.
const _journalFlushInterval = 32;

class QuarantineService {
  factory QuarantineService({
    required String quarantineRoot,
    required PathGuard guard,
    required FileMetadataAccess metadataAccess,
    PathExclusionSource? exclusions,
    DateTime Function()? clock,
    Future<int?> Function(String path)? freeSpaceProbe,
    CleanHistoryStore? historyStore,
    BroomFileSystem fileSystem = const IoFileSystem(),
  }) {
    if (!p.windows.isAbsolute(quarantineRoot)) {
      throw ArgumentError.value(
        quarantineRoot,
        'quarantineRoot',
        '隔离区路径必须是绝对路径',
      );
    }
    final normalized = PathGuard.normalize(quarantineRoot);
    if (p.windows.rootPrefix(normalized) == normalized) {
      throw ArgumentError.value(
        quarantineRoot,
        'quarantineRoot',
        '隔离区不能是磁盘根目录',
      );
    }
    return QuarantineService._(
      normalized,
      guard,
      metadataAccess,
      exclusions ?? const EmptyPathExclusionSource(),
      clock ?? DateTime.now,
      freeSpaceProbe,
      historyStore,
      fileSystem,
    );
  }

  QuarantineService._(
    this.quarantineRoot,
    this.guard,
    this._metadata,
    this._exclusions,
    this._clock,
    this._freeSpaceProbe,
    this._historyStore,
    this._files,
  );

  final String quarantineRoot;
  final PathGuard guard;
  final FileMetadataAccess _metadata;
  final PathExclusionSource _exclusions;
  final DateTime Function() _clock;
  final Future<int?> Function(String path)? _freeSpaceProbe;
  final CleanHistoryStore? _historyStore;
  final BroomFileSystem _files;
  final AsyncMutex _mutations = AsyncMutex();

  CleanHistoryStore? get historyStore => _historyStore;

  /// True while a mutating operation is running or queued. Read-only queries do
  /// not take the lock.
  bool get operationInProgress => _mutations.isBusy;

  static final Random _random = Random.secure();
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

  Future<CleanReport> clean(
    List<JunkItem> items, {
    required ScanRoots roots,
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    return _mutations.run(
      () => _clean(
        items,
        roots: roots,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  Future<CleanReport> _clean(
    List<JunkItem> items, {
    required ScanRoots roots,
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (items.isEmpty) {
      return const CleanReport(
        sessionId: null,
        movedCount: 0,
        movedBytes: 0,
        failureCount: 0,
        failures: [],
        cancelled: false,
      );
    }

    // Check space before creating the session or touching any file. A
    // cross-volume move is a copy followed by a delete, so running out of
    // space midway would leave a partial file in the quarantine.
    await _ensureSpaceAvailable(items);

    final baseDir = Directory(quarantineRoot);
    await _files.createDirectory(baseDir.path);

    final sessionId = await _createSessionId(baseDir.path);
    final sessionDir = Directory(p.windows.join(baseDir.path, sessionId));
    final filesDir = Directory(p.windows.join(sessionDir.path, 'files'));
    final createdAt = _clock().toUtc().toIso8601String();

    try {
      await _files.createDirectory(filesDir.path);
      await _writePlan(sessionDir, items, roots);
      await _writeSessionJson(sessionDir, {
        'schemaVersion': _schemaVersion,
        'id': sessionId,
        'createdAt': createdAt,
        'status': 'cleaning',
        'entryCount': 0,
        'totalBytes': 0,
        'pendingCount': 0,
        'pendingBytes': 0,
        'failureCount': 0,
        'skippedCount': 0,
        'plannedCount': items.length,
        'remainingCount': items.length,
        'updatedAt': createdAt,
      });
    } catch (_) {
      await _deleteSessionDirectory(sessionDir);
      rethrow;
    }

    return _runSession(
      sessionDir: sessionDir,
      sessionId: sessionId,
      createdAt: createdAt,
      items: items,
      planItems: items,
      roots: roots,
      plannedCount: items.length,
      previousFailureCount: 0,
      previousSkippedCount: 0,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// Continues an interrupted cleanup using the plan written before the first
  /// file was moved. Entries already in [entries.jsonl] are never touched, so
  /// a resumed run cannot move content that appeared at an original path after
  /// the interruption.
  Future<CleanReport> resumeClean(
    String sessionId, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    return _mutations.run(
      () => _resumeClean(
        sessionId,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  Future<CleanReport> _resumeClean(
    String sessionId, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
    final meta = await _readSessionJson(sessionDir);
    if (meta == null || _parseStatus(meta['status']) == null) {
      throw StateError('隔离区记录格式无效');
    }

    final plan = await _readPlan(sessionDir);
    final plannedCount = _readCount(
      meta,
      'plannedCount',
      fallback: plan.items.length,
    );
    if (plan.items.isEmpty ||
        plannedCount <= 0 ||
        plan.items.length != plannedCount) {
      throw StateError('找不到可继续的清理计划');
    }

    final journal = await _readEntryJournal(sessionDir);
    if (journal.rejected > 0) {
      throw StateError('隔离区记录包含无法解析的条目，已停止续跑');
    }
    final entries = journal.entries;
    final donePaths = {for (final entry in entries) entry.originalPath};
    final remaining = [
      for (final item in plan.items)
        if (!donePaths.contains(item.path)) item,
    ];
    final createdAt = meta['createdAt'] is String
        ? meta['createdAt'] as String
        : _clock().toUtc().toIso8601String();
    final previousFailureCount = _readCount(meta, 'failureCount');
    final previousSkippedCount = _readCount(meta, 'skippedCount');

    if (remaining.isEmpty) {
      final removedDirectoryCount = await _tryRemoveEmptyDirectories(
        sessionDir,
      );
      final outcome = await _finalizeSession(
        sessionDir: sessionDir,
        sessionId: sessionId,
        createdAt: createdAt,
        plannedCount: plannedCount,
        remainingCount: 0,
        failureCount: previousFailureCount,
        skippedCount: previousSkippedCount,
      );
      await _recordHistory(
        sessionId: sessionId,
        createdAt: createdAt,
        planItems: plan.items,
        roots: plan.roots,
        movedCount: entries.length,
        movedBytes: entries.fold<int>(0, (total, entry) => total + entry.size),
        skippedCount: previousSkippedCount,
        failureCount: previousFailureCount,
        remainingCount: 0,
        outcome: CleanHistoryOutcome.completed,
      );
      return CleanReport(
        sessionId: outcome.sessionRemoved ? null : sessionId,
        movedCount: 0,
        movedBytes: 0,
        failureCount: 0,
        failures: const [],
        cancelled: false,
        removedDirectoryCount: removedDirectoryCount,
      );
    }

    await _ensureSpaceAvailable(remaining);

    final restoredNames = await _readRestoredNames(sessionDir);
    final pending = await _pendingEntries(sessionDir, entries, restoredNames);
    await _writeSessionJson(sessionDir, {
      'schemaVersion': _schemaVersion,
      'id': sessionId,
      'createdAt': createdAt,
      'status': 'cleaning',
      'entryCount': entries.length,
      'totalBytes': entries.fold<int>(0, (total, entry) => total + entry.size),
      'pendingCount': pending.length,
      'pendingBytes': pending.fold<int>(
        0,
        (total, entry) => total + entry.size,
      ),
      'failureCount': previousFailureCount,
      'skippedCount': previousSkippedCount,
      'plannedCount': plannedCount,
      'remainingCount': remaining.length,
      'updatedAt': _clock().toUtc().toIso8601String(),
    });

    return _runSession(
      sessionDir: sessionDir,
      sessionId: sessionId,
      createdAt: createdAt,
      items: remaining,
      planItems: plan.items,
      roots: plan.roots,
      plannedCount: plannedCount,
      previousFailureCount: previousFailureCount,
      previousSkippedCount: previousSkippedCount,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// Estimates whether the quarantine volume can hold the cross-volume copies
  /// this batch would require. Same-volume moves are renames and need no
  /// additional data space. When no probe is configured the assessment is
  /// unknown and [QuarantineSpaceAssessment.sufficient] stays true.
  Future<QuarantineSpaceAssessment> assessSpace(List<JunkItem> items) async {
    var requiredBytes = 0;
    var crossVolumeCount = 0;
    for (final item in items) {
      if (!_requiresCopy(item.path)) continue;
      requiredBytes += item.size;
      crossVolumeCount++;
    }

    int? freeBytes;
    final probe = _freeSpaceProbe;
    if (probe != null && crossVolumeCount > 0) {
      try {
        final value = await probe(_volumeRoot(quarantineRoot));
        if (value != null && value >= 0) freeBytes = value;
      } catch (_) {
        freeBytes = null;
      }
    }
    return QuarantineSpaceAssessment(
      requiredBytes: requiredBytes,
      crossVolumeCount: crossVolumeCount,
      freeBytes: freeBytes,
      quarantineRoot: quarantineRoot,
    );
  }

  Future<void> _ensureSpaceAvailable(List<JunkItem> items) async {
    final assessment = await assessSpace(items);
    if (!assessment.sufficient) {
      throw QuarantineSpaceException(assessment: assessment);
    }
  }

  bool _requiresCopy(String sourcePath) {
    try {
      final sourceRoot = p.windows
          .rootPrefix(PathGuard.normalize(sourcePath))
          .toLowerCase();
      final quarantineVolume = _volumeRoot(quarantineRoot).toLowerCase();
      return sourceRoot != quarantineVolume;
    } catch (_) {
      // If the volume cannot be determined, assume a copy is needed. That is
      // the conservative choice for a preflight check.
      return true;
    }
  }

  static String _volumeRoot(String path) {
    final root = p.windows.rootPrefix(path);
    return root.isEmpty ? path : root;
  }

  Future<CleanReport> _runSession({
    required Directory sessionDir,
    required String sessionId,
    required String createdAt,
    required List<JunkItem> items,
    required List<JunkItem> planItems,
    required ScanRoots roots,
    required int plannedCount,
    required int previousFailureCount,
    required int previousSkippedCount,
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final failures = <CleanFailure>[];
    final skips = <CleanFailure>[];
    final filesDir = Directory(p.windows.join(sessionDir.path, 'files'));
    final priorEntries = await _readEntries(sessionDir);
    final priorEntryBytes = priorEntries.fold<int>(
      0,
      (total, entry) => total + entry.size,
    );
    var sequence = _maxSequence(priorEntries);
    var failureCount = 0;
    var skippedCount = 0;
    var movedCount = 0;
    var movedBytes = 0;
    var removedDirectoryCount = 0;
    var processed = 0;
    var cancelled = false;
    var spaceExhausted = false;
    var historyRecorded = false;
    var lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);
    var unflushedJournalWrites = 0;
    FsFileWriter? entriesFile;

    void recordFailure(String path, Object error) {
      failureCount++;
      if (failures.length < _maxFailureDetails) {
        failures.add(CleanFailure(path: path, reason: _failureReason(error)));
      }
    }

    void recordSkip(String path, Object reason) {
      skippedCount++;
      if (skips.length < _maxFailureDetails) {
        skips.add(CleanFailure(path: path, reason: _failureReason(reason)));
      }
    }

    void recordAttemptError(String path, Object error) {
      if (_isSkippableError(error)) {
        recordSkip(path, error);
      } else {
        recordFailure(path, error);
      }
    }

    void report({bool force = false, String? currentPath}) {
      final now = DateTime.now();
      if (!force &&
          now.difference(lastReportAt) < const Duration(milliseconds: 120)) {
        return;
      }
      lastReportAt = now;
      onProgress?.call(
        CleanProgress(
          moved: movedCount,
          processed: processed,
          total: items.length,
          movedBytes: movedBytes,
          skipped: skippedCount,
          currentPath: currentPath,
        ),
      );
    }

    CleanReport buildReport({required bool sessionRemoved}) => CleanReport(
      sessionId: sessionRemoved ? null : sessionId,
      movedCount: movedCount,
      movedBytes: movedBytes,
      skippedCount: skippedCount,
      skips: List.unmodifiable(skips),
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
      cancelled: cancelled,
      remainingCount: items.length - processed,
      removedDirectoryCount: removedDirectoryCount,
      spaceExhausted: spaceExhausted,
    );

    Future<void> recordHistory(CleanHistoryOutcome outcome) async {
      await _recordHistory(
        sessionId: sessionId,
        createdAt: createdAt,
        planItems: planItems,
        roots: roots,
        movedCount: priorEntries.length + movedCount,
        movedBytes: priorEntryBytes + movedBytes,
        skippedCount: previousSkippedCount + skippedCount,
        failureCount: previousFailureCount + failureCount,
        remainingCount: items.length - processed,
        outcome: outcome,
      );
    }

    var sessionRemoved = false;
    try {
      await _files.createDirectory(filesDir.path);
      entriesFile = await _files.openAppend(
        p.windows.join(sessionDir.path, 'entries.jsonl'),
      );
      // Only this process appends to the journal, so its write offset can be
      // tracked locally. One query at open replaces one per file; the offset
      // is still exact because every appended line is measured in UTF-8 bytes.
      var journalOffset = await entriesFile.position();

      for (final item in items) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        processed++;
        final root = roots.at(item.rootIndex);

        if (_exclusions.excludes(item.path)) {
          recordSkip(item.path, '位于排除列表中，已跳过');
          report(currentPath: item.path);
          continue;
        }

        if (!guard.allows(path: item.path, root: root.rootPath)) {
          recordFailure(item.path, '未通过路径安全检查');
          report(currentPath: item.path);
          continue;
        }

        // One metadata query per file: the stat below carries the type, the
        // size and the timestamps, and `_captureMetadata` only adds what a
        // stat cannot report (a cross-volume DACL). Probing type and size with
        // separate calls cost two extra syscalls per file.
        int size;
        FileMetadata? metadata;
        try {
          final stat = await _files.stat(item.path);
          if (stat.type != FsEntityType.file) {
            recordSkip(item.path, '文件已不存在或不是普通文件');
            report(currentPath: item.path);
            continue;
          }
          size = stat.size;
          metadata = await _captureMetadata(item.path, stat);
        } on FileSystemException catch (error) {
          if (_isMissingError(error)) {
            recordSkip(item.path, '文件已不存在或不是普通文件');
          } else {
            recordAttemptError(item.path, error);
          }
          report(currentPath: item.path);
          continue;
        }

        sequence++;
        final storedName = _storedName(sequence, item.path);
        final digest = await _tryHashFile(item.path, size);
        final entry = <String, Object?>{
          'originalPath': item.path,
          'rootPath': root.rootPath,
          'storedName': storedName,
          'size': size,
          'sha256': ?digest,
          'modified': (metadata?.modified ?? item.modified)
              .toUtc()
              .toIso8601String(),
          'ruleId': root.ruleId,
        };
        if (metadata?.created case final created?) {
          entry['created'] = created.toUtc().toIso8601String();
        }
        if (metadata?.accessed case final accessed?) {
          entry['accessed'] = accessed.toUtc().toIso8601String();
        }
        if (metadata?.readOnly case final readOnly?) {
          entry['readOnly'] = readOnly;
        }
        final acl = metadata?.acl;
        final aclTooLarge = acl != null && acl.length > _maxAclLength;
        if (acl != null && !aclTooLarge) {
          entry['acl'] = acl;
        }
        if ((metadata?.aclUnavailable ?? false) || aclTooLarge) {
          entry['aclUnavailable'] = true;
        }

        // Write the undo record before moving: a crash can leave an unused
        // record, but never an unrecorded file inside the quarantine.
        final writer = entriesFile;
        final line = '${jsonEncode(entry)}\n';
        final entryStart = journalOffset;
        try {
          await writer.writeString(line);
          // Measuring the encoded length costs one small allocation, far less
          // than the per-file `position()` it replaces, and keeps the offset
          // exactly equal to what dart:io appended.
          journalOffset += utf8.encode(line).length;
          unflushedJournalWrites++;
          if (unflushedJournalWrites >= _journalFlushInterval) {
            await writer.flush();
            unflushedJournalWrites = 0;
          }
        } on FileSystemException catch (error) {
          recordFailure(item.path, '无法写入撤销记录：${_failureReason(error)}');
          report(force: true, currentPath: item.path);
          break;
        }

        final destinationPath = p.windows.join(filesDir.path, storedName);
        try {
          await _moveFile(item.path, destinationPath);
        } on FileSystemException catch (error) {
          final discarded = await _discardEntryWithoutStoredFile(
            writer,
            entryStart,
            destinationPath,
            _files,
          );
          if (discarded) journalOffset = entryStart;
          if (_isDiskFullError(error)) {
            // Stop before attempting more copies. The plan stays on disk and
            // the session becomes partial so cleanup can resume after the user
            // frees space.
            recordFailure(item.path, error);
            spaceExhausted = true;
            report(force: true, currentPath: item.path);
            break;
          }
          recordAttemptError(item.path, error);
          report(currentPath: item.path);
          continue;
        }

        movedCount++;
        movedBytes += size;
        report(currentPath: item.path);
      }

      if (unflushedJournalWrites > 0) {
        // Durability for the tail of the journal, matching what the previous
        // per-entry flush guaranteed for the whole run.
        await entriesFile.flush();
        unflushedJournalWrites = 0;
      }
      await entriesFile.close();
      entriesFile = null;

      if (!cancelled) {
        removedDirectoryCount = await _tryRemoveEmptyDirectories(sessionDir);
      }

      final outcome = await _finalizeSession(
        sessionDir: sessionDir,
        sessionId: sessionId,
        createdAt: createdAt,
        plannedCount: plannedCount,
        remainingCount: items.length - processed,
        failureCount: previousFailureCount + failureCount,
        skippedCount: previousSkippedCount + skippedCount,
      );
      sessionRemoved = outcome.sessionRemoved;
      historyRecorded = true;
      await recordHistory(
        cancelled
            ? CleanHistoryOutcome.cancelled
            : items.length - processed > 0
            ? CleanHistoryOutcome.partial
            : CleanHistoryOutcome.completed,
      );
      report(force: true);
      return buildReport(sessionRemoved: sessionRemoved);
    } catch (_) {
      try {
        await entriesFile?.close();
      } on FileSystemException {
        // Ignore cleanup failures; the session metadata is updated below.
      }
      entriesFile = null;
      try {
        await _finalizeSession(
          sessionDir: sessionDir,
          sessionId: sessionId,
          createdAt: createdAt,
          plannedCount: plannedCount,
          remainingCount: items.length - processed,
          failureCount: previousFailureCount + failureCount,
          skippedCount: previousSkippedCount + skippedCount,
        );
      } on FileSystemException {
        // The plan and entries on disk still allow a later resume.
      }
      if (!historyRecorded) {
        historyRecorded = true;
        await recordHistory(CleanHistoryOutcome.failed);
      }
      rethrow;
    } finally {
      try {
        await entriesFile?.close();
      } on FileSystemException {
        // Nothing else to do.
      }
      report(force: true);
    }
  }

  Future<int> _tryRemoveEmptyDirectories(Directory sessionDir) async {
    try {
      return await _removeEmptyDirectories(sessionDir);
    } catch (_) {
      // Empty-directory cleanup is best-effort; moved files stay undoable.
      return 0;
    }
  }

  /// Removes only directories below the rule roots that are empty after this
  /// session's files moved out. A directory is considered only when it is a
  /// strict ancestor of a moved file, so directories that were already empty
  /// before cleanup are left untouched.
  Future<int> _removeEmptyDirectories(Directory sessionDir) async {
    final entries = await _readEntries(sessionDir);
    if (entries.isEmpty) return 0;

    final candidates = <String, _RemovedDirectory>{};
    for (final entry in entries) {
      var directory = p.windows.dirname(entry.originalPath);
      while (guard.allows(path: directory, root: entry.rootPath)) {
        final key = _key(directory);
        candidates.putIfAbsent(
          key,
          () => _RemovedDirectory(path: directory, rootPath: entry.rootPath),
        );
        final parent = p.windows.dirname(directory);
        if (parent == directory) break;
        directory = parent;
      }
    }
    if (candidates.isEmpty) return 0;

    final recorded = {
      for (final directory in await _readRemovedDirectories(sessionDir))
        _key(directory.path),
    };
    final ordered = candidates.values.toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));

    var removedCount = 0;
    FsFileWriter? recordFile;
    try {
      recordFile = await _files.openAppend(
        p.windows.join(sessionDir.path, 'removed_dirs.jsonl'),
      );

      for (final directory in ordered) {
        if (_exclusions.excludes(directory.path)) continue;
        if (_isInsideQuarantine(directory.path)) continue;
        if (!await _isDirectoryEmpty(directory.path)) continue;

        // Record before deleting so a crash can never lose a directory that
        // undo would need to recreate.
        final key = _key(directory.path);
        final alreadyRecorded = recorded.contains(key);
        final recordStart = await recordFile.position();
        if (!alreadyRecorded) {
          try {
            await recordFile.writeString(
              '${jsonEncode({'path': directory.path, 'rootPath': directory.rootPath})}\n',
            );
            await recordFile.flush();
          } on FileSystemException {
            continue;
          }
        }

        try {
          // Non-recursive so content that appeared after the emptiness check
          // is never deleted.
          await _files.deleteDirectory(directory.path);
          removedCount++;
          recorded.add(key);
        } on FileSystemException {
          if (!alreadyRecorded) {
            try {
              await recordFile.truncate(recordStart);
              await recordFile.setPosition(recordStart);
              await recordFile.flush();
            } on FileSystemException {
              // An extra record only causes a no-op recreation during undo.
            }
          }
        }
      }
    } on FileSystemException {
      // Every removal is preceded by a record; stopping early is safe.
    } finally {
      try {
        await recordFile?.close();
      } on FileSystemException {
        // Nothing else to do.
      }
    }
    return removedCount;
  }

  static bool _isRelatedToEntries(
    _RemovedDirectory directory,
    List<_StoredEntry> entries,
  ) {
    final directoryKey = _key(directory.path);
    final rootKey = _key(directory.rootPath);
    for (final entry in entries) {
      if (_key(entry.rootPath) != rootKey) continue;
      final entryKey = _key(entry.originalPath);
      if (entryKey != directoryKey && _isWithinKey(directoryKey, entryKey)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _isDirectoryEmpty(String path) async {
    try {
      final type = await _files.type(path);
      if (type != FsEntityType.directory) return false;
      await for (final _ in _files.list(path)) {
        return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  bool _isInsideQuarantine(String path) {
    return _isWithinKey(_key(quarantineRoot), _key(path));
  }

  Future<({bool sessionRemoved, int remainingCount})> _finalizeSession({
    required Directory sessionDir,
    required String sessionId,
    required String createdAt,
    required int plannedCount,
    required int remainingCount,
    required int failureCount,
    required int skippedCount,
  }) async {
    final journal = await _readEntryJournal(sessionDir);
    final entries = journal.entries;
    final restoredNames = await _readRestoredNames(sessionDir);
    // Every planned file was moved and the journal parsed cleanly, so the stored
    // files exist by construction. Probing each one with a `type` call would
    // cost one syscall per file to re-prove what the loop just did; only a
    // failed, skipped or interrupted run needs the per-entry check. The
    // difference is limited to files deleted behind our back right after being
    // moved: here they stay pending, which is the more conservative outcome.
    final movedEverything =
        failureCount == 0 &&
        skippedCount == 0 &&
        remainingCount == 0 &&
        journal.rejected == 0;
    final List<_StoredEntry> pending;
    if (movedEverything) {
      pending = [
        for (final entry in entries)
          if (!restoredNames.contains(entry.storedName)) entry,
      ];
    } else {
      pending = await _pendingEntries(sessionDir, entries, restoredNames);
    }
    final pendingCount = pending.length + journal.rejected;

    // An entry is written before the move so a crash cannot lose undo data.
    // If every move failed (for example on read-only media), no stored file is
    // left to restore and the empty session must not be kept as pending.
    if (pendingCount == 0 && remainingCount == 0) {
      await _deleteSessionDirectory(sessionDir);
      return (sessionRemoved: true, remainingCount: 0);
    }

    if (remainingCount == 0) {
      await _deletePlanFile(sessionDir);
    }

    await _writeSessionJson(sessionDir, {
      'schemaVersion': _schemaVersion,
      'id': sessionId,
      'createdAt': createdAt,
      'status': remainingCount > 0 ? 'partial' : 'ready',
      'entryCount': entries.length,
      'totalBytes': entries.fold<int>(0, (total, entry) => total + entry.size),
      'pendingCount': pendingCount,
      'pendingBytes': pending.fold<int>(
        0,
        (total, entry) => total + entry.size,
      ),
      'failureCount': failureCount,
      'skippedCount': skippedCount,
      'plannedCount': plannedCount,
      'remainingCount': remainingCount,
      'updatedAt': _clock().toUtc().toIso8601String(),
    });
    return (sessionRemoved: false, remainingCount: remainingCount);
  }

  Future<UndoReport> undo(
    String sessionId, {
    Set<String>? storedNames,
    UndoConflictPolicy conflictPolicy = UndoConflictPolicy.skip,
    Map<String, UndoConflictPolicy> conflictPolicies = const {},
  }) {
    return _mutations.run(
      () => _undo(
        sessionId,
        storedNames: storedNames,
        conflictPolicy: conflictPolicy,
        conflictPolicies: conflictPolicies,
      ),
    );
  }

  Future<UndoReport> _undo(
    String sessionId, {
    Set<String>? storedNames,
    UndoConflictPolicy conflictPolicy = UndoConflictPolicy.skip,
    Map<String, UndoConflictPolicy> conflictPolicies = const {},
  }) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
    await _requireSessionMeta(sessionDir);
    final journal = await _readEntryJournal(sessionDir);
    final entries = journal.entries;
    final restoredNames = await _readRestoredNames(sessionDir);
    final restoredAfter = <String>{...restoredNames};
    final targets = storedNames == null
        ? entries
        : entries
              .where((entry) => storedNames.contains(entry.storedName))
              .toList();
    final removedDirectories = await _readRemovedDirectories(sessionDir);
    final filesDir = p.windows.join(sessionDir.path, 'files');
    final failures = <CleanFailure>[];
    var failureCount = 0;
    var restoredCount = 0;
    var restoredBytes = 0;
    var conflictCount = 0;
    var keptBothCount = 0;
    var overwrittenCount = 0;
    var missingCount = 0;
    var integrityFailureCount = 0;
    var metadataFailureCount = 0;
    var recreatedDirectoryCount = 0;
    var directoryFailureCount = 0;
    final metadataWarnings = <CleanFailure>[];
    final directoryWarnings = <CleanFailure>[];
    final conflicts = <UndoConflict>[];

    void recordFailure(String path, Object error) {
      failureCount++;
      if (failures.length < _maxFailureDetails) {
        failures.add(CleanFailure(path: path, reason: _failureReason(error)));
      }
    }

    void recordMetadataWarning(String path, Object error) {
      metadataFailureCount++;
      if (metadataWarnings.length < _maxFailureDetails) {
        metadataWarnings.add(
          CleanFailure(path: path, reason: _failureReason(error)),
        );
      }
    }

    void recordDirectoryWarning(String path, Object error) {
      directoryFailureCount++;
      if (directoryWarnings.length < _maxFailureDetails) {
        directoryWarnings.add(
          CleanFailure(path: path, reason: _failureReason(error)),
        );
      }
    }

    Future<void> restoreMetadata(String path, _StoredEntry entry) async {
      final metadata = entry.metadata;
      if (metadata == null) return;
      if (metadata.hasRestorableValues) {
        try {
          await _metadata.apply(path, metadata);
        } catch (error) {
          recordMetadataWarning(path, error);
          return;
        }
      }
      if (metadata.aclUnavailable) {
        recordMetadataWarning(path, 'ACL 未能在清理时保存');
      }
    }

    void recordRestored(_StoredEntry entry) {
      restoredCount++;
      restoredBytes += entry.size;
      restoredAfter.add(entry.storedName);
    }

    Future<void> markRestored(_StoredEntry entry) async {
      try {
        await _files.writeString(
          p.windows.join(sessionDir.path, 'restored.jsonl'),
          '${entry.storedName}\n',
          append: true,
        );
      } on FileSystemException {
        // If the marker cannot be written, a retry will see the restored
        // original path and skip it as a conflict instead of overwriting.
      }
    }

    final directoryTargets = <String, _RemovedDirectory>{};
    for (final directory in removedDirectories) {
      if (!_isRelatedToEntries(directory, entries)) continue;
      directoryTargets.putIfAbsent(_key(directory.path), () => directory);
    }
    final orderedDirectories = directoryTargets.values.toList()
      ..sort((a, b) => a.path.length.compareTo(b.path.length));
    for (final directory in orderedDirectories) {
      if (_exclusions.excludes(directory.path)) {
        recordDirectoryWarning(directory.path, '目录位于排除列表中，未重建');
        continue;
      }
      if (!guard.allows(path: directory.path, root: directory.rootPath)) {
        recordDirectoryWarning(directory.path, '目录未通过安全检查');
        continue;
      }

      FsEntityType type;
      try {
        type = await _files.type(directory.path);
      } on FileSystemException catch (error) {
        recordDirectoryWarning(directory.path, error);
        continue;
      }
      if (type == FsEntityType.directory) continue;
      if (type != FsEntityType.notFound) {
        recordDirectoryWarning(directory.path, '路径已被其他文件占用，无法重建目录');
        continue;
      }

      try {
        await _files.createDirectory(directory.path);
        recreatedDirectoryCount++;
      } on FileSystemException catch (error) {
        recordDirectoryWarning(directory.path, error);
      }
    }

    for (final entry in targets) {
      if (restoredNames.contains(entry.storedName)) continue;
      if (!_isSafeStoredName(entry.storedName)) {
        recordFailure(entry.originalPath, '隔离区记录包含非法文件名');
        continue;
      }

      final storedPath = p.windows.join(filesDir, entry.storedName);
      final storedCheck = await _verifyStoredFile(storedPath, entry);
      if (storedCheck.missing) {
        missingCount++;
        continue;
      }
      if (storedCheck.reason case final reason?) {
        integrityFailureCount++;
        recordFailure(entry.originalPath, reason);
        continue;
      }

      if (_exclusions.excludes(entry.originalPath)) {
        recordFailure(entry.originalPath, '原路径位于排除列表中，未恢复');
        continue;
      }

      if (!guard.allows(path: entry.originalPath, root: entry.rootPath)) {
        recordFailure(entry.originalPath, '原路径未通过安全检查');
        continue;
      }

      FsEntityType targetType;
      try {
        targetType = await _files.type(entry.originalPath);
      } on FileSystemException catch (error) {
        recordFailure(entry.originalPath, error);
        continue;
      }
      if (targetType != FsEntityType.notFound) {
        // Per-file decisions win; the batch policy remains the fallback for
        // callers that restore a whole session from a single action.
        final effectivePolicy =
            conflictPolicies[entry.storedName] ?? conflictPolicy;
        switch (effectivePolicy) {
          case UndoConflictPolicy.skip:
            conflictCount++;
            conflicts.add(
              UndoConflict(
                storedName: entry.storedName,
                originalPath: entry.originalPath,
                policy: effectivePolicy,
                applied: false,
                reason: '原位置已有文件，已跳过',
              ),
            );
            continue;
          case UndoConflictPolicy.keepBoth:
            final destinationPath = await _availableRestorePath(
              entry.originalPath,
            );
            if (destinationPath == null) {
              conflicts.add(
                UndoConflict(
                  storedName: entry.storedName,
                  originalPath: entry.originalPath,
                  policy: effectivePolicy,
                  applied: false,
                  reason: '无法为冲突文件生成可用的新名称',
                ),
              );
              recordFailure(entry.originalPath, '无法为冲突文件生成可用的新名称');
              continue;
            }
            if (_exclusions.excludes(destinationPath) ||
                !guard.allows(path: destinationPath, root: entry.rootPath)) {
              conflicts.add(
                UndoConflict(
                  storedName: entry.storedName,
                  originalPath: entry.originalPath,
                  policy: effectivePolicy,
                  applied: false,
                  reason: '恢复路径未通过安全检查',
                ),
              );
              recordFailure(destinationPath, '恢复路径未通过安全检查');
              continue;
            }
            try {
              await _moveFile(storedPath, destinationPath);
            } on FileSystemException catch (error) {
              conflicts.add(
                UndoConflict(
                  storedName: entry.storedName,
                  originalPath: entry.originalPath,
                  policy: effectivePolicy,
                  applied: false,
                  reason: _failureReason(error),
                ),
              );
              recordFailure(entry.originalPath, error);
              continue;
            }
            conflicts.add(
              UndoConflict(
                storedName: entry.storedName,
                originalPath: entry.originalPath,
                policy: effectivePolicy,
                applied: true,
                reason: '已保存为 $destinationPath',
              ),
            );
            await restoreMetadata(destinationPath, entry);
            recordRestored(entry);
            keptBothCount++;
            await markRestored(entry);
            continue;
          case UndoConflictPolicy.overwrite:
            if (targetType != FsEntityType.file) {
              conflicts.add(
                UndoConflict(
                  storedName: entry.storedName,
                  originalPath: entry.originalPath,
                  policy: effectivePolicy,
                  applied: false,
                  reason: '原位置不是普通文件，无法覆盖',
                ),
              );
              recordFailure(entry.originalPath, '原位置不是普通文件，无法覆盖');
              continue;
            }
            // Re-check immediately before replacing: the target may have
            // changed since the initial validation above.
            if (_exclusions.excludes(entry.originalPath) ||
                !guard.allows(path: entry.originalPath, root: entry.rootPath)) {
              conflicts.add(
                UndoConflict(
                  storedName: entry.storedName,
                  originalPath: entry.originalPath,
                  policy: effectivePolicy,
                  applied: false,
                  reason: '原路径未通过安全检查',
                ),
              );
              recordFailure(entry.originalPath, '原路径未通过安全检查');
              continue;
            }
            try {
              await _replaceFile(storedPath, entry.originalPath);
            } on FileSystemException catch (error) {
              conflicts.add(
                UndoConflict(
                  storedName: entry.storedName,
                  originalPath: entry.originalPath,
                  policy: effectivePolicy,
                  applied: false,
                  reason: _failureReason(error),
                ),
              );
              recordFailure(entry.originalPath, error);
              continue;
            }
            conflicts.add(
              UndoConflict(
                storedName: entry.storedName,
                originalPath: entry.originalPath,
                policy: effectivePolicy,
                applied: true,
                reason: '已覆盖原位置内容',
              ),
            );
            await restoreMetadata(entry.originalPath, entry);
            recordRestored(entry);
            overwrittenCount++;
            await markRestored(entry);
            continue;
        }
      }

      try {
        await _files.createDirectory(p.windows.dirname(entry.originalPath));
        await _moveFile(storedPath, entry.originalPath);
      } on FileSystemException catch (error) {
        recordFailure(entry.originalPath, error);
        continue;
      }

      await restoreMetadata(entry.originalPath, entry);
      recordRestored(entry);
      await markRestored(entry);
    }

    final pending = await _pendingEntries(sessionDir, entries, restoredAfter);
    if (journal.rejected > 0) {
      recordFailure(
        sessionDir.path,
        '隔离区记录包含 ${journal.rejected} 条无法解析的条目，已保留会话',
      );
    }
    final pendingCount = pending.length + journal.rejected;
    final pendingBytes = pending.fold<int>(
      0,
      (total, entry) => total + entry.size,
    );

    if (pendingCount == 0) {
      await _deleteSessionDirectory(sessionDir);
    } else {
      final meta = await _readSessionJson(sessionDir) ?? const {};
      await _writeSessionJson(sessionDir, {
        'schemaVersion': _schemaVersion,
        'id': sessionId,
        'createdAt': meta['createdAt'] ?? _clock().toUtc().toIso8601String(),
        'status': 'partial',
        'entryCount': (meta['entryCount'] as num?)?.toInt() ?? entries.length,
        'totalBytes':
            (meta['totalBytes'] as num?)?.toInt() ??
            entries.fold<int>(0, (total, entry) => total + entry.size),
        'pendingCount': pendingCount,
        'pendingBytes': pendingBytes,
        'failureCount': failureCount,
        'skippedCount': (meta['skippedCount'] as num?)?.toInt() ?? 0,
        'plannedCount': (meta['plannedCount'] as num?)?.toInt() ?? 0,
        'remainingCount': (meta['remainingCount'] as num?)?.toInt() ?? 0,
        'updatedAt': _clock().toUtc().toIso8601String(),
      });
    }

    return UndoReport(
      restoredCount: restoredCount,
      restoredBytes: restoredBytes,
      conflictCount: conflictCount,
      keptBothCount: keptBothCount,
      overwrittenCount: overwrittenCount,
      missingCount: missingCount,
      failureCount: failureCount,
      integrityFailureCount: integrityFailureCount,
      failures: List.unmodifiable(failures),
      sessionRemoved: pendingCount == 0,
      conflicts: List.unmodifiable(conflicts),
      metadataFailureCount: metadataFailureCount,
      metadataWarnings: List.unmodifiable(metadataWarnings),
      recreatedDirectoryCount: recreatedDirectoryCount,
      directoryFailureCount: directoryFailureCount,
      directoryWarnings: List.unmodifiable(directoryWarnings),
    );
  }

  Future<List<QuarantineEntry>> listEntries(String sessionId) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
    await _requireSessionMeta(sessionDir);
    final entries = await _readEntries(sessionDir);
    final restoredNames = await _readRestoredNames(sessionDir);
    final filesDir = p.windows.join(sessionDir.path, 'files');
    final result = <QuarantineEntry>[];

    for (final entry in entries) {
      var present = false;
      String? integrityFailure;
      if (_isSafeStoredName(entry.storedName)) {
        final storedPath = p.windows.join(filesDir, entry.storedName);
        try {
          present = await _files.type(storedPath) == FsEntityType.file;
          if (present) {
            final length = await _files.length(storedPath);
            if (length != entry.size) {
              integrityFailure =
                  '隔离文件大小与清理记录不一致'
                  '（记录 ${entry.size} 字节，实际 $length 字节）';
            }
          }
        } on FileSystemException {
          present = true;
          integrityFailure = '无法读取隔离文件，完整性未知';
        }
      }

      var originalExists = false;
      try {
        originalExists =
            await _files.type(entry.originalPath) != FsEntityType.notFound;
      } on FileSystemException {
        originalExists = true;
      }

      result.add(
        QuarantineEntry(
          storedName: entry.storedName,
          originalPath: entry.originalPath,
          size: entry.size,
          restored: restoredNames.contains(entry.storedName),
          present: present,
          originalExists: originalExists,
          integrityFailure: integrityFailure,
        ),
      );
    }

    return result;
  }

  Future<QuarantinePurgeReport> purgeSession(String sessionId) {
    return _mutations.run(() => _purgeSession(sessionId));
  }

  Future<QuarantinePurgeReport> _purgeSession(String sessionId) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
    await _requireSessionMeta(sessionDir);
    final failures = <CleanFailure>[];
    var failureCount = 0;
    var removedCount = 0;
    var removedBytes = 0;

    void recordFailure(String path, Object error) {
      failureCount++;
      if (failures.length < _maxFailureDetails) {
        failures.add(CleanFailure(path: path, reason: _failureReason(error)));
      }
    }

    final filesDir = p.windows.join(sessionDir.path, 'files');
    try {
      if (await _files.type(filesDir) == FsEntityType.directory) {
        await for (final entity in _files.list(filesDir)) {
          if (entity.type != FsEntityType.file) continue;
          var length = 0;
          try {
            length = await _files.length(entity.path);
          } on FileSystemException {
            length = 0;
          }
          try {
            await _deleteFile(entity.path);
            removedCount++;
            removedBytes += length;
          } on FileSystemException catch (error) {
            recordFailure(entity.path, error);
          }
        }
      }
    } on FileSystemException catch (error) {
      recordFailure(filesDir, error);
    }

    var sessionRemoved = false;
    if (failureCount == 0) {
      try {
        await _files.deleteDirectory(sessionDir.path, recursive: true);
        sessionRemoved = true;
      } on FileSystemException catch (error) {
        recordFailure(sessionDir.path, error);
      }
    }

    return QuarantinePurgeReport(
      removedCount: removedCount,
      removedBytes: removedBytes,
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
      sessionRemoved: sessionRemoved,
    );
  }

  Future<QuarantinePurgeReport> purgeAllSessions() {
    return _mutations.run(_purgeAllSessions);
  }

  Future<QuarantinePurgeReport> _purgeAllSessions() async {
    final sessions = await listSessions();
    final failures = <CleanFailure>[];
    var failureCount = 0;
    var removedCount = 0;
    var removedBytes = 0;
    var allRemoved = true;

    for (final session in sessions) {
      try {
        final report = await _purgeSession(session.id);
        removedCount += report.removedCount;
        removedBytes += report.removedBytes;
        failureCount += report.failureCount;
        allRemoved = allRemoved && report.sessionRemoved;
        if (failures.length < _maxFailureDetails) {
          failures.addAll(
            report.failures.take(_maxFailureDetails - failures.length),
          );
        }
      } catch (error) {
        failureCount++;
        allRemoved = false;
        if (failures.length < _maxFailureDetails) {
          failures.add(
            CleanFailure(
              path: p.windows.join(quarantineRoot, session.id),
              reason: _failureReason(error),
            ),
          );
        }
      }
    }

    return QuarantinePurgeReport(
      removedCount: removedCount,
      removedBytes: removedBytes,
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
      sessionRemoved: allRemoved,
    );
  }

  Future<List<QuarantineSessionInfo>> listSessions() async {
    if (await _files.type(quarantineRoot) != FsEntityType.directory) {
      return const [];
    }

    final sessions = <QuarantineSessionInfo>[];
    try {
      await for (final entity in _files.list(quarantineRoot)) {
        if (entity.type != FsEntityType.directory) continue;
        final id = p.windows.basename(entity.path);
        if (!_isValidSessionId(id)) continue;

        try {
          final info = await _readSessionInfo(Directory(entity.path));
          if (info != null) sessions.add(info);
        } on QuarantineSessionFormatException {
          // Sessions from an unsupported format are not listed or processed.
          // They remain on disk untouched so a newer Broom build can still
          // open them.
          continue;
        }
      }
    } on FileSystemException {
      return sessions;
    }

    sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sessions;
  }

  Future<QuarantineSessionInfo> getSession(String sessionId) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
    final info = await _readSessionInfo(sessionDir);
    if (info == null) {
      throw StateError('找不到隔离区记录');
    }
    return info;
  }

  Future<QuarantineSessionInfo?> _readSessionInfo(Directory sessionDir) async {
    final meta = await _readSessionJson(sessionDir);
    if (meta == null) return null;

    var status = _parseStatus(meta['status']);
    if (status == null) return null;
    var entryCount = _readCount(meta, 'entryCount');
    var totalBytes = _readCount(meta, 'totalBytes');
    var pendingCount = _readCount(meta, 'pendingCount', fallback: entryCount);
    var pendingBytes = _readCount(meta, 'pendingBytes', fallback: totalBytes);
    var plannedCount = _readCount(meta, 'plannedCount');
    var remainingCount = 0;

    if (status == QuarantineStatus.cleaning) {
      final journal = await _readEntryJournal(sessionDir);
      final entries = journal.entries;
      final plan = await _readPlan(sessionDir);
      final planned = plannedCount > 0 ? plannedCount : plan.items.length;
      final planComplete =
          plan.items.isNotEmpty && plan.items.length == planned;
      final restoredNames = await _readRestoredNames(sessionDir);
      final pending = await _pendingEntries(sessionDir, entries, restoredNames);
      entryCount = entries.length;
      totalBytes = entries.fold<int>(0, (total, entry) => total + entry.size);
      pendingCount = pending.length + journal.rejected;
      pendingBytes = pending.fold<int>(0, (total, entry) => total + entry.size);
      plannedCount = planned;
      if (planComplete) {
        final donePaths = {for (final entry in entries) entry.originalPath};
        remainingCount = plan.items
            .where((item) => !donePaths.contains(item.path))
            .length;
      }
      if (entries.isEmpty && remainingCount == 0 && journal.rejected == 0) {
        return null;
      }
      status = planComplete && remainingCount == 0
          ? QuarantineStatus.ready
          : QuarantineStatus.partial;
    } else if (status == QuarantineStatus.partial) {
      final plan = await _readPlan(sessionDir);
      final planComplete =
          plan.items.isNotEmpty &&
          (plannedCount <= 0 || plan.items.length == plannedCount);
      if (planComplete) {
        plannedCount = plan.items.length;
        final storedRemaining = meta.containsKey('remainingCount')
            ? _readCount(meta, 'remainingCount')
            : null;
        if (storedRemaining != null) {
          remainingCount = storedRemaining > plannedCount
              ? plannedCount
              : storedRemaining;
        } else {
          final entries = await _readEntries(sessionDir);
          final donePaths = {for (final entry in entries) entry.originalPath};
          remainingCount = plan.items
              .where((item) => !donePaths.contains(item.path))
              .length;
        }
      }
    }

    if (pendingCount <= 0 && remainingCount <= 0) return null;

    final id = p.windows.basename(sessionDir.path);
    final createdAt =
        DateTime.tryParse('${meta['createdAt'] ?? ''}') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return QuarantineSessionInfo(
      id: id,
      createdAt: createdAt,
      status: status,
      entryCount: entryCount,
      totalBytes: totalBytes,
      pendingCount: pendingCount,
      pendingBytes: pendingBytes,
      plannedCount: plannedCount,
      remainingCount: remainingCount,
    );
  }

  Future<Directory> _requireSessionDirectory(String sessionId) async {
    if (!_isValidSessionId(sessionId)) {
      throw ArgumentError.value(sessionId, 'sessionId', '无效的清理会话编号');
    }
    final sessionDir = Directory(p.windows.join(quarantineRoot, sessionId));
    final type = await _files.type(sessionDir.path);
    if (type == FsEntityType.notFound) {
      throw StateError('找不到隔离区记录');
    }
    if (type != FsEntityType.directory) {
      throw StateError('隔离区记录格式无效');
    }
    return sessionDir;
  }

  Future<List<_StoredEntry>> _pendingEntries(
    Directory sessionDir,
    List<_StoredEntry> entries,
    Set<String> restoredNames,
  ) async {
    final filesDir = p.windows.join(sessionDir.path, 'files');
    final pending = <_StoredEntry>[];
    for (final entry in entries) {
      if (restoredNames.contains(entry.storedName)) continue;
      if (!_isSafeStoredName(entry.storedName)) {
        pending.add(entry);
        continue;
      }
      try {
        final type = await _files.type(
          p.windows.join(filesDir, entry.storedName),
        );
        if (type == FsEntityType.file) {
          pending.add(entry);
        }
      } on FileSystemException {
        pending.add(entry);
      }
    }
    return pending;
  }

  Future<String> _createSessionId(String baseDirPath) async {
    for (var attempt = 0; attempt < 32; attempt++) {
      final id = _newSessionId();
      if (await _files.type(p.windows.join(baseDirPath, id)) ==
          FsEntityType.notFound) {
        return id;
      }
    }
    throw StateError('无法创建唯一的清理会话编号');
  }

  String _newSessionId() {
    final now = _clock();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final suffix = List.generate(
      4,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '${stamp}_$suffix';
  }

  static bool _isValidSessionId(String id) {
    if (id.length > _maxSessionIdLength) return false;
    if (!RegExp(r'^[0-9A-Za-z][0-9A-Za-z_]*$').hasMatch(id)) return false;
    return !_pathSemantics.isReservedComponent(id);
  }

  static bool _isSafeStoredName(String name) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    if (name.length > _maxStoredNameLength) return false;
    if (name.contains('/') || name.contains(r'\')) return false;
    if (name.contains(':')) return false;
    if (name.endsWith('.') || name.endsWith(' ')) return false;
    if (RegExp(r'[\x00-\x1F<>"|?*]').hasMatch(name)) return false;
    if (_pathSemantics.isReservedComponent(name)) return false;
    return p.windows.basename(name) == name;
  }

  static const PathSemantics _pathSemantics = WindowsPathSemantics();

  static String _storedName(int sequence, String sourcePath) {
    var name = p.windows.basename(sourcePath);
    if (name.isEmpty) name = 'file';
    name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    if (name.length > 80) name = name.substring(0, 80);
    return '${sequence.toString().padLeft(6, '0')}_$name';
  }

  static String _key(String path) => PathGuard.normalize(path).toLowerCase();

  static bool _isWithinKey(String rootKey, String candidateKey) {
    if (candidateKey == rootKey) return true;
    final prefix = rootKey.endsWith(p.windows.separator)
        ? rootKey
        : '$rootKey${p.windows.separator}';
    return candidateKey.startsWith(prefix);
  }

  static String _failureReason(Object error) => describeFilesystemError(error);

  static bool _isDiskFullError(Object error) {
    if (error is! FileSystemException) return false;
    final code = error.osError?.errorCode;
    // ERROR_DISK_FULL (112), ERROR_HANDLE_DISK_FULL (39) and POSIX ENOSPC.
    return code == 112 || code == 39 || code == 28;
  }

  static bool _isSkippableError(Object error) {
    if (isFileLockConflict(error)) return true;
    return _isMissingError(error);
  }

  /// A path that vanished between preview and clean. Reported as a skip rather
  /// than a failure: the user already got what they wanted for that entry.
  static bool _isMissingError(Object error) {
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      return code == 2 || code == 3;
    }
    return false;
  }

  /// Removes the just-written undo record when a failed move left nothing in
  /// the quarantine. If a partial copy exists, the record is kept so the file
  /// can still be restored or purged.
  ///
  /// Returns true when the record was removed, which lets the caller keep its
  /// running journal offset in sync.
  static Future<bool> _discardEntryWithoutStoredFile(
    FsFileWriter writer,
    int entryStart,
    String storedPath,
    BroomFileSystem files,
  ) async {
    try {
      final type = await files.type(storedPath);
      if (type != FsEntityType.notFound) return false;
      await writer.truncate(entryStart);
      await writer.setPosition(entryStart);
      await writer.flush();
      return true;
    } on FileSystemException {
      // An extra entry without a stored file is harmless and can be purged.
      return false;
    }
  }

  /// Adds the undo values a [stat] cannot report, reusing that same query.
  ///
  /// Metadata is best effort: a failure here degrades the undo record (it
  /// falls back to the scanned modification time) but must not stop the clean.
  Future<FileMetadata?> _captureMetadata(String path, FsStat stat) async {
    try {
      return await _metadata.read(
        path,
        stat: stat,
        captureAcl: shouldCaptureAcl(path, quarantineRoot),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _tryHashFile(String path, int size) async {
    if (size > _integrityHashLimitBytes) return null;
    try {
      // Ask for one byte past the recorded size: a shorter result proves the
      // file still ends exactly there, so the common case is a single read.
      // `readBytes` would need an extra read at EOF to learn the same thing.
      final bytes = await _files.readBytesUpTo(path, size + 1);
      if (bytes.length > size) {
        // The file grew between the stat and the hash. Restore compares the
        // digest of the whole stored file, so hash everything to stay byte
        // exact instead of recording a truncated prefix.
        return sha256.convert(await _files.readBytes(path)).toString();
      }
      return sha256.convert(bytes).toString();
    } on FileSystemException {
      return null;
    }
  }

  Future<({bool missing, String? reason})> _verifyStoredFile(
    String storedPath,
    _StoredEntry entry,
  ) async {
    FsEntityType type;
    try {
      type = await _files.type(storedPath);
    } on FileSystemException catch (error) {
      return (missing: false, reason: '无法读取隔离文件：${_failureReason(error)}');
    }
    if (type != FsEntityType.file) {
      return (missing: true, reason: null);
    }

    int length;
    try {
      length = await _files.length(storedPath);
    } on FileSystemException catch (error) {
      return (missing: false, reason: '无法读取隔离文件：${_failureReason(error)}');
    }
    if (length != entry.size) {
      return (
        missing: false,
        reason:
            '隔离文件大小与清理记录不一致'
            '（记录 ${entry.size} 字节，实际 $length 字节）',
      );
    }

    final expectedDigest = entry.sha256;
    if (expectedDigest != null) {
      String actualDigest;
      try {
        // The length check above already pinned the file at `size`, so reading
        // that many bytes avoids the extra read `readBytes` makes at EOF.
        final bytes = await _files.readBytesUpTo(storedPath, entry.size);
        actualDigest = sha256.convert(bytes).toString();
      } on FileSystemException catch (error) {
        return (missing: false, reason: '无法校验隔离文件：${_failureReason(error)}');
      }
      if (actualDigest != expectedDigest) {
        return (missing: false, reason: '隔离文件内容校验失败（SHA-256 与清理记录不一致）');
      }
    }

    return (missing: false, reason: null);
  }

  Future<String?> _availableRestorePath(String originalPath) async {
    final directory = p.windows.dirname(originalPath);
    final extension = p.windows.extension(originalPath);
    final base = p.windows.basenameWithoutExtension(originalPath);
    for (var index = 1; index <= 999; index++) {
      final suffix = index == 1 ? ' (已恢复)' : ' (已恢复 $index)';
      final candidate = p.windows.join(directory, '$base$suffix$extension');
      try {
        final type = await _files.type(candidate);
        if (type == FsEntityType.notFound) return candidate;
      } on FileSystemException {
        // Try the next suffix.
      }
    }
    return null;
  }

  /// Moves the occupied target aside first so a failed restore never
  /// destroys the file that currently occupies the original path.
  Future<void> _replaceFile(String sourcePath, String targetPath) async {
    final backupPath = await _backupPath(targetPath);
    await _files.rename(targetPath, backupPath);
    try {
      await _moveFile(sourcePath, targetPath);
    } catch (_) {
      try {
        await _files.rename(backupPath, targetPath);
      } on FileSystemException {
        // The previous content stays at the backup path rather than being lost.
      }
      rethrow;
    }
    try {
      await _deleteFile(backupPath);
    } on FileSystemException {
      // The restored file is in place; a leftover backup is not fatal.
    }
  }

  Future<String> _backupPath(String targetPath) async {
    final directory = p.windows.dirname(targetPath);
    for (var attempt = 0; attempt < 8; attempt++) {
      final suffix = List.generate(
        4,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final candidate = p.windows.join(directory, '.broom-backup-$suffix.tmp');
      try {
        final type = await _files.type(candidate);
        if (type == FsEntityType.notFound) return candidate;
      } on FileSystemException {
        // Try another candidate.
      }
    }
    throw FileSystemException('无法创建覆盖前的临时备份路径', targetPath);
  }

  Future<void> _moveFile(String sourcePath, String destinationPath) async {
    try {
      await _files.rename(sourcePath, destinationPath);
      return;
    } on FileSystemException {
      // Rename only works within one volume; fall through for cross-volume
      // moves. A locked source will also be cleaned up safely below.
    }

    try {
      await _files.copy(sourcePath, destinationPath);
    } on FileSystemException {
      // A failed copy can leave a truncated destination (for example when the
      // disk fills up). Remove it so the quarantine never reports a partial
      // file as restorable.
      try {
        await _deleteFile(destinationPath);
      } on FileSystemException {
        // Best effort; the caller reports the original copy failure.
      }
      rethrow;
    }
    try {
      await _deleteFile(sourcePath);
    } catch (_) {
      try {
        await _deleteFile(destinationPath);
      } on FileSystemException {
        // The orphaned copy is harmless and remains in the quarantine.
      }
      rethrow;
    }
  }

  Future<void> _deleteFile(String path) async {
    var readOnly = false;
    try {
      final stat = await _files.stat(path);
      readOnly = stat.type == FsEntityType.file && isReadOnlyMode(stat.mode);
    } on FileSystemException {
      // Let the delete attempt report the real error.
    }

    if (readOnly) {
      try {
        await _metadata.apply(path, const FileMetadata(readOnly: false));
      } catch (error) {
        throw FileSystemException('无法清除只读属性：$error', path);
      }
    }
    try {
      await _files.deleteFile(path);
    } catch (_) {
      if (readOnly) {
        try {
          await _metadata.apply(path, const FileMetadata(readOnly: true));
        } catch (_) {
          // The original error is more useful than a failed attribute restore.
        }
      }
      rethrow;
    }
  }

  Future<void> _deleteSessionDirectory(Directory directory) async {
    try {
      await _files.deleteDirectory(directory.path, recursive: true);
    } on FileSystemException {
      // A failed cleanup must not turn a completed undo into an error.
    }
  }

  /// History is informational and deliberately best-effort; a failure to
  /// write it must not turn a successful cleanup into an error.
  Future<void> _recordHistory({
    required String sessionId,
    required String createdAt,
    required List<JunkItem> planItems,
    required ScanRoots roots,
    required int movedCount,
    required int movedBytes,
    required int skippedCount,
    required int failureCount,
    required int remainingCount,
    required CleanHistoryOutcome outcome,
  }) async {
    final store = _historyStore;
    if (store == null) return;
    try {
      final grouped = <String, ({int count, int bytes})>{};
      for (final item in planItems) {
        final ruleId = roots.at(item.rootIndex).ruleId;
        final current = grouped[ruleId];
        grouped[ruleId] = current == null
            ? (count: 1, bytes: item.size)
            : (count: current.count + 1, bytes: current.bytes + item.size);
      }
      final rules = [
        for (final entry in grouped.entries)
          CleanHistoryRule(
            ruleId: entry.key,
            fileCount: entry.value.count,
            bytes: entry.value.bytes,
          ),
      ]..sort((a, b) => b.bytes.compareTo(a.bytes));
      final completedAt = _clock().toUtc();
      await store.upsert(
        CleanHistoryRecord(
          sessionId: sessionId,
          startedAt: DateTime.tryParse(createdAt)?.toUtc() ?? completedAt,
          completedAt: completedAt,
          outcome: outcome,
          plannedCount: planItems.length,
          plannedBytes: planItems.fold<int>(
            0,
            (total, item) => total + item.size,
          ),
          movedCount: movedCount,
          movedBytes: movedBytes,
          skippedCount: skippedCount,
          failureCount: failureCount,
          remainingCount: remainingCount,
          rules: List.unmodifiable(rules),
        ),
      );
    } catch (_) {
      // See the method contract above.
    }
  }

  Future<Map<String, dynamic>?> _readSessionJson(Directory sessionDir) async {
    final path = p.windows.join(sessionDir.path, 'session.json');
    try {
      if (await _files.type(path) == FsEntityType.notFound) return null;
      final value = jsonDecode(await _files.readString(path));
      if (value is! Map<String, dynamic>) return null;
      // Migration errors propagate: callers that touch a single session must
      // refuse an unknown format instead of guessing at its contents.
      return migrateQuarantineSessionJson(value);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<Map<String, dynamic>> _requireSessionMeta(Directory sessionDir) async {
    final meta = await _readSessionJson(sessionDir);
    if (meta == null || _parseStatus(meta['status']) == null) {
      throw StateError('隔离区记录格式无效');
    }
    return meta;
  }

  Future<void> _writeSessionJson(
    Directory sessionDir,
    Map<String, dynamic> data,
  ) async {
    final path = p.windows.join(sessionDir.path, 'session.json');
    final tempPath = '$path.tmp';
    await _files.writeString(tempPath, jsonEncode(data));
    await _files.rename(tempPath, path);
  }

  Future<List<_StoredEntry>> _readEntries(Directory sessionDir) async {
    return (await _readEntryJournal(sessionDir)).entries;
  }

  Future<_EntryJournal> _readEntryJournal(Directory sessionDir) async {
    final path = p.windows.join(sessionDir.path, 'entries.jsonl');
    if (await _files.type(path) == FsEntityType.notFound) {
      return const _EntryJournal(entries: [], rejected: 0);
    }
    final entries = <_StoredEntry>[];
    var rejected = 0;
    try {
      final lines = await _files.readLines(path);
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final map = jsonDecode(line);
          if (map is! Map<String, dynamic>) {
            rejected++;
            continue;
          }
          final originalPath = map['originalPath'];
          final rootPath = map['rootPath'];
          final storedName = map['storedName'];
          final size = map['size'];
          if (originalPath is! String ||
              rootPath is! String ||
              storedName is! String ||
              size is! num ||
              !_isValidStoredEntry(
                originalPath: originalPath,
                rootPath: rootPath,
                storedName: storedName,
                size: size,
              )) {
            rejected++;
            continue;
          }
          final rawDigest = map['sha256'];
          final digest =
              rawDigest is String && _sha256Pattern.hasMatch(rawDigest)
              ? rawDigest.toLowerCase()
              : null;
          entries.add(
            _StoredEntry(
              originalPath: originalPath,
              rootPath: rootPath,
              storedName: storedName,
              size: size.toInt(),
              sha256: digest,
              metadata: _parseMetadata(map),
            ),
          );
        } on FormatException {
          rejected++;
          continue;
        }
      }
    } on FileSystemException {
      return _EntryJournal(entries: entries, rejected: rejected + 1);
    }
    return _EntryJournal(entries: entries, rejected: rejected);
  }

  Future<List<_RemovedDirectory>> _readRemovedDirectories(
    Directory sessionDir,
  ) async {
    final path = p.windows.join(sessionDir.path, 'removed_dirs.jsonl');
    if (await _files.type(path) == FsEntityType.notFound) return const [];
    final directories = <_RemovedDirectory>[];
    try {
      final lines = await _files.readLines(path);
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final map = jsonDecode(line);
          if (map is! Map<String, dynamic>) continue;
          final path = map['path'];
          final rootPath = map['rootPath'];
          if (path is! String ||
              rootPath is! String ||
              !_isValidRemovedDirectory(path: path, rootPath: rootPath)) {
            continue;
          }
          directories.add(
            _RemovedDirectory(
              path: WindowsPath.canonical(path),
              rootPath: WindowsPath.canonical(rootPath),
            ),
          );
        } on FormatException {
          continue;
        }
      }
    } on FileSystemException {
      return directories;
    }
    return directories;
  }

  static FileMetadata? _parseMetadata(Map<String, dynamic> map) {
    final rawModified = map['modified'];
    final modified = rawModified is String
        ? DateTime.tryParse(rawModified)
        : null;
    final rawCreated = map['created'];
    final created = rawCreated is String ? DateTime.tryParse(rawCreated) : null;
    final rawAccessed = map['accessed'];
    final accessed = rawAccessed is String
        ? DateTime.tryParse(rawAccessed)
        : null;
    final rawReadOnly = map['readOnly'];
    final readOnly = rawReadOnly is bool ? rawReadOnly : null;
    final rawAcl = map['acl'];
    final aclValid =
        rawAcl is String && rawAcl.isNotEmpty && rawAcl.length <= _maxAclLength;
    final acl = aclValid ? rawAcl : null;
    final aclUnavailable =
        map['aclUnavailable'] == true ||
        (rawAcl is String && rawAcl.isNotEmpty && !aclValid);
    if (modified == null &&
        created == null &&
        accessed == null &&
        readOnly == null &&
        acl == null &&
        !aclUnavailable) {
      return null;
    }
    return FileMetadata(
      created: created,
      modified: modified,
      accessed: accessed,
      readOnly: readOnly,
      acl: acl,
      aclUnavailable: aclUnavailable,
    );
  }

  Future<Set<String>> _readRestoredNames(Directory sessionDir) async {
    final path = p.windows.join(sessionDir.path, 'restored.jsonl');
    if (await _files.type(path) == FsEntityType.notFound) return <String>{};
    try {
      final lines = await _files.readLines(path);
      return lines
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toSet();
    } on FileSystemException {
      return <String>{};
    }
  }

  /// How many plan lines are joined into a single append.
  ///
  /// The plan is written once, before the first file is touched, and is only
  /// read by the resume path. Batching therefore changes nothing but the number
  /// of write syscalls: one per line would cost one per file.
  static const _planWriteBatch = 64;

  Future<void> _writePlan(
    Directory sessionDir,
    List<JunkItem> items,
    ScanRoots roots,
  ) async {
    final planPath = p.windows.join(sessionDir.path, 'plan.jsonl');
    final tempPath = '$planPath.tmp';
    final writer = await _files.openWrite(tempPath);
    var closed = false;
    try {
      final buffer = StringBuffer();
      var batched = 0;
      for (final item in items) {
        final root = roots.at(item.rootIndex);
        buffer.writeln(
          jsonEncode({
            'originalPath': item.path,
            'rootPath': root.rootPath,
            'ruleId': root.ruleId,
            'size': item.size,
            'modified': item.modified.toUtc().toIso8601String(),
          }),
        );
        batched++;
        if (batched >= _planWriteBatch) {
          await writer.writeString(buffer.toString());
          buffer.clear();
          batched = 0;
        }
      }
      if (batched > 0) await writer.writeString(buffer.toString());
      await writer.flush();
      await writer.close();
      closed = true;
    } finally {
      if (!closed) {
        try {
          await writer.close();
        } on FileSystemException {
          // The incomplete temporary plan is removed below.
        }
        try {
          await _files.deleteFile(tempPath);
        } on FileSystemException {
          // A leftover temporary plan is never read.
        }
      }
    }
    try {
      await _files.rename(tempPath, planPath);
    } on FileSystemException {
      try {
        await _files.deleteFile(tempPath);
      } on FileSystemException {
        // A leftover temporary plan is never read.
      }
      rethrow;
    }
  }

  Future<_PlanData> _readPlan(Directory sessionDir) async {
    final path = p.windows.join(sessionDir.path, 'plan.jsonl');
    if (await _files.type(path) == FsEntityType.notFound) {
      return const _PlanData(items: [], roots: ScanRoots.empty);
    }
    final items = <JunkItem>[];
    final roots = <ScanRoot>[];
    final rootIndexes = <String, int>{};
    try {
      final lines = await _files.readLines(path);
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final map = jsonDecode(line);
          if (map is! Map<String, dynamic>) continue;
          final originalPath = map['originalPath'];
          final rootPath = map['rootPath'];
          final size = map['size'];
          if (originalPath is! String ||
              rootPath is! String ||
              size is! num ||
              !_isValidPlanEntry(originalPath, rootPath, size)) {
            continue;
          }
          final rawModified = map['modified'];
          final modified = rawModified is String
              ? DateTime.tryParse(rawModified)
              : null;
          final rawRuleId = map['ruleId'];
          final ruleId = rawRuleId is String ? rawRuleId : '';
          final rootIndex = rootIndexes.putIfAbsent(
            '$ruleId\u0000$rootPath',
            () {
              roots.add(ScanRoot(ruleId: ruleId, rootPath: rootPath));
              return roots.length - 1;
            },
          );
          items.add(
            JunkItem(
              rootIndex: rootIndex,
              path: originalPath,
              size: size.toInt(),
              modifiedMicros: (modified ?? _clock()).microsecondsSinceEpoch,
            ),
          );
        } on FormatException {
          continue;
        }
      }
    } on FileSystemException {
      return const _PlanData(items: [], roots: ScanRoots.empty);
    }
    return _PlanData(items: items, roots: ScanRoots(roots));
  }

  static bool _isValidStoredEntry({
    required String originalPath,
    required String rootPath,
    required String storedName,
    required num size,
  }) {
    if (!_isSafeStoredName(storedName)) return false;
    if (!p.windows.isAbsolute(originalPath) ||
        !p.windows.isAbsolute(rootPath)) {
      return false;
    }
    if (size < 0 || !size.isFinite || size > 9007199254740991) return false;
    final rootKey = _key(rootPath);
    final pathKey = _key(originalPath);
    // Undo must never be able to write outside the root recorded at cleanup.
    return pathKey != rootKey && _isWithinKey(rootKey, pathKey);
  }

  static bool _isValidRemovedDirectory({
    required String path,
    required String rootPath,
  }) {
    if (!p.windows.isAbsolute(path) || !p.windows.isAbsolute(rootPath)) {
      return false;
    }
    final rootKey = _key(rootPath);
    final pathKey = _key(path);
    return pathKey != rootKey && _isWithinKey(rootKey, pathKey);
  }

  static bool _isValidPlanEntry(String path, String rootPath, num size) {
    if (!p.windows.isAbsolute(path) || !p.windows.isAbsolute(rootPath)) {
      return false;
    }
    if (size < 0 || !size.isFinite || size > 9007199254740991) return false;
    final rootKey = _key(rootPath);
    final pathKey = _key(path);
    return pathKey != rootKey && _isWithinKey(rootKey, pathKey);
  }

  Future<void> _deletePlanFile(Directory sessionDir) async {
    try {
      final path = p.windows.join(sessionDir.path, 'plan.jsonl');
      if (await _files.type(path) != FsEntityType.notFound) {
        await _files.deleteFile(path);
      }
    } on FileSystemException {
      // A leftover plan on a completed session is ignored.
    }
  }

  static int _maxSequence(List<_StoredEntry> entries) {
    var sequence = 0;
    for (final entry in entries) {
      final separator = entry.storedName.indexOf('_');
      if (separator <= 0) continue;
      final parsed = int.tryParse(entry.storedName.substring(0, separator));
      if (parsed != null && parsed > sequence) {
        sequence = parsed;
      }
    }
    return sequence;
  }

  static int _readCount(
    Map<String, dynamic> meta,
    String key, {
    int fallback = 0,
  }) {
    final raw = meta[key];
    if (raw is int) return raw < 0 ? 0 : raw;
    if (raw is double && raw.isFinite) {
      final value = raw.toInt();
      return value < 0 ? 0 : value;
    }
    return fallback;
  }

  static QuarantineStatus? _parseStatus(Object? raw) {
    switch (raw) {
      case 'ready':
        return QuarantineStatus.ready;
      case 'partial':
        return QuarantineStatus.partial;
      case 'cleaning':
        return QuarantineStatus.cleaning;
      case 'restored':
        return QuarantineStatus.restored;
      default:
        return null;
    }
  }
}

class _PlanData {
  const _PlanData({required this.items, required this.roots});

  final List<JunkItem> items;
  final ScanRoots roots;
}

class _RemovedDirectory {
  const _RemovedDirectory({required this.path, required this.rootPath});

  final String path;
  final String rootPath;
}

class _EntryJournal {
  const _EntryJournal({required this.entries, required this.rejected});

  final List<_StoredEntry> entries;

  /// Number of non-empty lines that could not be interpreted safely. A session
  /// with rejected records is kept for manual purge instead of being deleted
  /// automatically.
  final int rejected;
}

class _StoredEntry {
  const _StoredEntry({
    required this.originalPath,
    required this.rootPath,
    required this.storedName,
    required this.size,
    this.sha256,
    this.metadata,
  });

  final String originalPath;
  final String rootPath;
  final String storedName;
  final int size;
  final String? sha256;
  final FileMetadata? metadata;
}
