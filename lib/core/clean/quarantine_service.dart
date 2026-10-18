import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/clean_models.dart';
import '../models/scan_models.dart';
import '../platform/filesystem_error.dart';
import '../platform/windows_path.dart';
import '../safety/path_exclusions.dart';
import '../safety/path_guard.dart';
import 'file_metadata.dart';

const _schemaVersion = 1;
const _maxFailureDetails = 100;
const _maxAclLength = 64 * 1024;
const _integrityHashLimitBytes = 32 * 1024 * 1024;

class QuarantineService {
  factory QuarantineService({
    required String quarantineRoot,
    required PathGuard guard,
    required FileMetadataAccess metadataAccess,
    PathExclusionSource? exclusions,
    DateTime Function()? clock,
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
    );
  }

  QuarantineService._(
    this.quarantineRoot,
    this.guard,
    this._metadata,
    this._exclusions,
    this._clock,
  );

  final String quarantineRoot;
  final PathGuard guard;
  final FileMetadataAccess _metadata;
  final PathExclusionSource _exclusions;
  final DateTime Function() _clock;
  static final Random _random = Random.secure();
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

  Future<CleanReport> clean(
    List<JunkItem> items, {
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

    final baseDir = Directory(quarantineRoot);
    await baseDir.create(recursive: true);

    final sessionId = await _createSessionId(baseDir);
    final sessionDir = Directory(p.windows.join(baseDir.path, sessionId));
    final filesDir = Directory(p.windows.join(sessionDir.path, 'files'));
    final createdAt = _clock().toUtc().toIso8601String();

    try {
      await filesDir.create(recursive: true);
      await _writePlan(sessionDir, items);
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
        'plannedCount': items.length,
        'remainingCount': items.length,
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
      plannedCount: items.length,
      previousFailureCount: 0,
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
  }) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
    final meta = await _readSessionJson(sessionDir);
    if (meta == null) {
      throw StateError('隔离区记录格式无效');
    }

    final plan = await _readPlan(sessionDir);
    final plannedCount = (meta['plannedCount'] as num?)?.toInt() ?? plan.length;
    if (plan.isEmpty || plannedCount <= 0 || plan.length != plannedCount) {
      throw StateError('找不到可继续的清理计划');
    }

    final entries = await _readEntries(sessionDir);
    final donePaths = {for (final entry in entries) entry.originalPath};
    final remaining = [
      for (final item in plan)
        if (!donePaths.contains(item.path)) item,
    ];
    final createdAt = meta['createdAt'] is String
        ? meta['createdAt'] as String
        : _clock().toUtc().toIso8601String();
    final previousFailureCount = (meta['failureCount'] as num?)?.toInt() ?? 0;

    if (remaining.isEmpty) {
      final outcome = await _finalizeSession(
        sessionDir: sessionDir,
        sessionId: sessionId,
        createdAt: createdAt,
        plannedCount: plannedCount,
        remainingCount: 0,
        failureCount: previousFailureCount,
      );
      return CleanReport(
        sessionId: outcome.sessionRemoved ? null : sessionId,
        movedCount: 0,
        movedBytes: 0,
        failureCount: 0,
        failures: const [],
        cancelled: false,
      );
    }

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
      'plannedCount': plannedCount,
      'remainingCount': remaining.length,
    });

    return _runSession(
      sessionDir: sessionDir,
      sessionId: sessionId,
      createdAt: createdAt,
      items: remaining,
      plannedCount: plannedCount,
      previousFailureCount: previousFailureCount,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<CleanReport> _runSession({
    required Directory sessionDir,
    required String sessionId,
    required String createdAt,
    required List<JunkItem> items,
    required int plannedCount,
    required int previousFailureCount,
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final failures = <CleanFailure>[];
    final filesDir = Directory(p.windows.join(sessionDir.path, 'files'));
    final priorEntries = await _readEntries(sessionDir);
    var sequence = _maxSequence(priorEntries);
    var failureCount = 0;
    var movedCount = 0;
    var movedBytes = 0;
    var processed = 0;
    var cancelled = false;
    var lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);
    RandomAccessFile? entriesFile;

    void recordFailure(String path, Object error) {
      failureCount++;
      if (failures.length < _maxFailureDetails) {
        failures.add(CleanFailure(path: path, reason: _failureReason(error)));
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
          currentPath: currentPath,
        ),
      );
    }

    CleanReport buildReport({required bool sessionRemoved}) => CleanReport(
      sessionId: sessionRemoved ? null : sessionId,
      movedCount: movedCount,
      movedBytes: movedBytes,
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
      cancelled: cancelled,
      remainingCount: items.length - processed,
    );

    var sessionRemoved = false;
    try {
      await filesDir.create(recursive: true);
      entriesFile = await File(p.windows.join(sessionDir.path, 'entries.jsonl'))
          .open(mode: FileMode.append);

      for (final item in items) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        processed++;

        if (_exclusions.excludes(item.path)) {
          recordFailure(item.path, '位于排除列表中，已跳过');
          report(currentPath: item.path);
          continue;
        }

        if (!guard.allows(path: item.path, root: item.rootPath)) {
          recordFailure(item.path, '未通过路径安全检查');
          report(currentPath: item.path);
          continue;
        }

        FileSystemEntityType type;
        try {
          type = await FileSystemEntity.type(
            WindowsPath.forIo(item.path),
            followLinks: false,
          );
        } on FileSystemException catch (error) {
          recordFailure(item.path, error);
          report(currentPath: item.path);
          continue;
        }
        if (type != FileSystemEntityType.file) {
          recordFailure(item.path, '文件已不存在或不是普通文件');
          report(currentPath: item.path);
          continue;
        }

        int size;
        FileMetadata? metadata;
        try {
          final stat = await File(WindowsPath.forIo(item.path)).stat();
          if (stat.type != FileSystemEntityType.file) {
            recordFailure(item.path, '文件已不存在或不是普通文件');
            report(currentPath: item.path);
            continue;
          }
          size = stat.size;
          metadata = await _captureMetadata(item.path);
        } on FileSystemException catch (error) {
          recordFailure(item.path, error);
          report(currentPath: item.path);
          continue;
        }

        sequence++;
        final storedName = _storedName(sequence, item.path);
        final digest = await _tryHashFile(item.path, size);
        final entry = <String, Object?>{
          'originalPath': item.path,
          'rootPath': item.rootPath,
          'storedName': storedName,
          'size': size,
          'sha256': ?digest,
          'modified': (metadata?.modified ?? item.modified)
              .toUtc()
              .toIso8601String(),
          'ruleId': item.ruleId,
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
        try {
          await entriesFile.writeString('${jsonEncode(entry)}\n');
          await entriesFile.flush();
        } on FileSystemException catch (error) {
          recordFailure(item.path, '无法写入撤销记录：${_failureReason(error)}');
          report(force: true, currentPath: item.path);
          break;
        }

        try {
          await _moveFile(item.path, p.windows.join(filesDir.path, storedName));
        } on FileSystemException catch (error) {
          recordFailure(item.path, error);
          report(currentPath: item.path);
          continue;
        }

        movedCount++;
        movedBytes += size;
        report(currentPath: item.path);
      }

      await entriesFile.close();
      entriesFile = null;

      final outcome = await _finalizeSession(
        sessionDir: sessionDir,
        sessionId: sessionId,
        createdAt: createdAt,
        plannedCount: plannedCount,
        remainingCount: items.length - processed,
        failureCount: previousFailureCount + failureCount,
      );
      sessionRemoved = outcome.sessionRemoved;
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
        );
      } on FileSystemException {
        // The plan and entries on disk still allow a later resume.
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

  Future<({bool sessionRemoved, int remainingCount})> _finalizeSession({
    required Directory sessionDir,
    required String sessionId,
    required String createdAt,
    required int plannedCount,
    required int remainingCount,
    required int failureCount,
  }) async {
    final entries = await _readEntries(sessionDir);
    final restoredNames = await _readRestoredNames(sessionDir);
    final pending = await _pendingEntries(sessionDir, entries, restoredNames);

    // An entry is written before the move so a crash cannot lose undo data.
    // If every move failed (for example on read-only media), no stored file is
    // left to restore and the empty session must not be kept as pending.
    if (pending.isEmpty && remainingCount == 0) {
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
      'pendingCount': pending.length,
      'pendingBytes': pending.fold<int>(
        0,
        (total, entry) => total + entry.size,
      ),
      'failureCount': failureCount,
      'plannedCount': plannedCount,
      'remainingCount': remainingCount,
    });
    return (sessionRemoved: false, remainingCount: remainingCount);
  }

  Future<UndoReport> undo(
    String sessionId, {
    Set<String>? storedNames,
    UndoConflictPolicy conflictPolicy = UndoConflictPolicy.skip,
  }) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
    final entries = await _readEntries(sessionDir);
    final restoredNames = await _readRestoredNames(sessionDir);
    final restoredAfter = <String>{...restoredNames};
    final targets = storedNames == null
        ? entries
        : entries
              .where((entry) => storedNames.contains(entry.storedName))
              .toList();
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
    final metadataWarnings = <CleanFailure>[];

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
        await File(p.windows.join(sessionDir.path, 'restored.jsonl'))
            .writeAsString(
              '${entry.storedName}\n',
              mode: FileMode.append,
              flush: true,
            );
      } on FileSystemException {
        // If the marker cannot be written, a retry will see the restored
        // original path and skip it as a conflict instead of overwriting.
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

      FileSystemEntityType targetType;
      try {
        targetType = await FileSystemEntity.type(
          WindowsPath.forIo(entry.originalPath),
          followLinks: false,
        );
      } on FileSystemException catch (error) {
        recordFailure(entry.originalPath, error);
        continue;
      }
      if (targetType != FileSystemEntityType.notFound) {
        switch (conflictPolicy) {
          case UndoConflictPolicy.skip:
            conflictCount++;
            continue;
          case UndoConflictPolicy.keepBoth:
            final destinationPath = await _availableRestorePath(
              entry.originalPath,
            );
            if (destinationPath == null) {
              recordFailure(entry.originalPath, '无法为冲突文件生成可用的新名称');
              continue;
            }
            if (_exclusions.excludes(destinationPath) ||
                !guard.allows(path: destinationPath, root: entry.rootPath)) {
              recordFailure(destinationPath, '恢复路径未通过安全检查');
              continue;
            }
            try {
              await _moveFile(storedPath, destinationPath);
            } on FileSystemException catch (error) {
              recordFailure(entry.originalPath, error);
              continue;
            }
            await restoreMetadata(destinationPath, entry);
            recordRestored(entry);
            keptBothCount++;
            await markRestored(entry);
            continue;
          case UndoConflictPolicy.overwrite:
            if (targetType != FileSystemEntityType.file) {
              recordFailure(entry.originalPath, '原位置不是普通文件，无法覆盖');
              continue;
            }
            // Re-check immediately before replacing: the target may have
            // changed since the initial validation above.
            if (_exclusions.excludes(entry.originalPath) ||
                !guard.allows(path: entry.originalPath, root: entry.rootPath)) {
              recordFailure(entry.originalPath, '原路径未通过安全检查');
              continue;
            }
            try {
              await _replaceFile(storedPath, entry.originalPath);
            } on FileSystemException catch (error) {
              recordFailure(entry.originalPath, error);
              continue;
            }
            await restoreMetadata(entry.originalPath, entry);
            recordRestored(entry);
            overwrittenCount++;
            await markRestored(entry);
            continue;
        }
      }

      try {
        await Directory(
          WindowsPath.forIo(p.windows.dirname(entry.originalPath)),
        ).create(recursive: true);
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
    final pendingCount = pending.length;
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
      metadataFailureCount: metadataFailureCount,
      metadataWarnings: List.unmodifiable(metadataWarnings),
    );
  }

  Future<List<QuarantineEntry>> listEntries(String sessionId) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
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
          present =
              await FileSystemEntity.type(
                WindowsPath.forIo(storedPath),
                followLinks: false,
              ) ==
              FileSystemEntityType.file;
          if (present) {
            final length = await File(WindowsPath.forIo(storedPath)).length();
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
            await FileSystemEntity.type(
              WindowsPath.forIo(entry.originalPath),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound;
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

  Future<QuarantinePurgeReport> purgeSession(String sessionId) async {
    final sessionDir = await _requireSessionDirectory(sessionId);
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

    final filesDir = Directory(p.windows.join(sessionDir.path, 'files'));
    try {
      if (await filesDir.exists()) {
        await for (final entity in filesDir.list(followLinks: false)) {
          if (entity is! File) continue;
          var length = 0;
          try {
            length = await entity.length();
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
      recordFailure(filesDir.path, error);
    }

    var sessionRemoved = false;
    if (failureCount == 0) {
      try {
        await sessionDir.delete(recursive: true);
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

  Future<QuarantinePurgeReport> purgeAllSessions() async {
    final sessions = await listSessions();
    final failures = <CleanFailure>[];
    var failureCount = 0;
    var removedCount = 0;
    var removedBytes = 0;
    var allRemoved = true;

    for (final session in sessions) {
      try {
        final report = await purgeSession(session.id);
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
    final baseDir = Directory(quarantineRoot);
    if (!await baseDir.exists()) return const [];

    final sessions = <QuarantineSessionInfo>[];
    try {
      await for (final entity in baseDir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final id = p.windows.basename(entity.path);
        if (!_isValidSessionId(id)) continue;

        final info = await _readSessionInfo(entity);
        if (info != null) sessions.add(info);
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
    var entryCount = (meta['entryCount'] as num?)?.toInt() ?? 0;
    var totalBytes = (meta['totalBytes'] as num?)?.toInt() ?? 0;
    var pendingCount = (meta['pendingCount'] as num?)?.toInt() ?? entryCount;
    var pendingBytes = (meta['pendingBytes'] as num?)?.toInt() ?? totalBytes;
    var plannedCount = (meta['plannedCount'] as num?)?.toInt() ?? 0;
    var remainingCount = 0;

    if (status == QuarantineStatus.cleaning) {
      final entries = await _readEntries(sessionDir);
      final plan = await _readPlan(sessionDir);
      final planned = plannedCount > 0 ? plannedCount : plan.length;
      final planComplete = plan.isNotEmpty && plan.length == planned;
      final restoredNames = await _readRestoredNames(sessionDir);
      final pending = await _pendingEntries(sessionDir, entries, restoredNames);
      entryCount = entries.length;
      totalBytes = entries.fold<int>(0, (total, entry) => total + entry.size);
      pendingCount = pending.length;
      pendingBytes = pending.fold<int>(0, (total, entry) => total + entry.size);
      plannedCount = planned;
      if (planComplete) {
        final donePaths = {for (final entry in entries) entry.originalPath};
        remainingCount = plan
            .where((item) => !donePaths.contains(item.path))
            .length;
      }
      if (entries.isEmpty && remainingCount == 0) return null;
      status = planComplete && remainingCount == 0
          ? QuarantineStatus.ready
          : QuarantineStatus.partial;
    } else if (status == QuarantineStatus.partial) {
      final plan = await _readPlan(sessionDir);
      final planComplete =
          plan.isNotEmpty && (plannedCount <= 0 || plan.length == plannedCount);
      if (planComplete) {
        plannedCount = plan.length;
        final storedRemaining = (meta['remainingCount'] as num?)?.toInt();
        if (storedRemaining != null && storedRemaining >= 0) {
          remainingCount = storedRemaining > plannedCount
              ? plannedCount
              : storedRemaining;
        } else {
          final entries = await _readEntries(sessionDir);
          final donePaths = {for (final entry in entries) entry.originalPath};
          remainingCount = plan
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
    final type = await FileSystemEntity.type(
      sessionDir.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      throw StateError('找不到隔离区记录');
    }
    if (type != FileSystemEntityType.directory) {
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
        final type = await FileSystemEntity.type(
          p.windows.join(filesDir, entry.storedName),
          followLinks: false,
        );
        if (type == FileSystemEntityType.file) {
          pending.add(entry);
        }
      } on FileSystemException {
        pending.add(entry);
      }
    }
    return pending;
  }

  Future<String> _createSessionId(Directory baseDir) async {
    for (var attempt = 0; attempt < 32; attempt++) {
      final id = _newSessionId();
      if (!await Directory(p.windows.join(baseDir.path, id)).exists()) {
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

  static bool _isValidSessionId(String id) =>
      RegExp(r'^[0-9A-Za-z_]+$').hasMatch(id);

  static bool _isSafeStoredName(String name) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains(r'\')) return false;
    return p.windows.basename(name) == name;
  }

  static String _storedName(int sequence, String sourcePath) {
    var name = p.windows.basename(sourcePath);
    if (name.isEmpty) name = 'file';
    name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    if (name.length > 80) name = name.substring(0, 80);
    return '${sequence.toString().padLeft(6, '0')}_$name';
  }

  static String _failureReason(Object error) => describeFilesystemError(error);

  Future<FileMetadata?> _captureMetadata(String path) async {
    try {
      return await _metadata.read(
        path,
        captureAcl: shouldCaptureAcl(path, quarantineRoot),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _tryHashFile(String path, int size) async {
    if (size > _integrityHashLimitBytes) return null;
    try {
      final bytes = await File(WindowsPath.forIo(path)).readAsBytes();
      return sha256.convert(bytes).toString();
    } on FileSystemException {
      return null;
    }
  }

  static Future<({bool missing, String? reason})> _verifyStoredFile(
    String storedPath,
    _StoredEntry entry,
  ) async {
    FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(
        WindowsPath.forIo(storedPath),
        followLinks: false,
      );
    } on FileSystemException catch (error) {
      return (missing: false, reason: '无法读取隔离文件：${_failureReason(error)}');
    }
    if (type != FileSystemEntityType.file) {
      return (missing: true, reason: null);
    }

    int length;
    try {
      length = await File(WindowsPath.forIo(storedPath)).length();
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
        final bytes = await File(WindowsPath.forIo(storedPath)).readAsBytes();
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

  static Future<String?> _availableRestorePath(String originalPath) async {
    final directory = p.windows.dirname(originalPath);
    final extension = p.windows.extension(originalPath);
    final base = p.windows.basenameWithoutExtension(originalPath);
    for (var index = 1; index <= 999; index++) {
      final suffix = index == 1 ? ' (已恢复)' : ' (已恢复 $index)';
      final candidate = p.windows.join(directory, '$base$suffix$extension');
      try {
        final type = await FileSystemEntity.type(
          WindowsPath.forIo(candidate),
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) return candidate;
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
    await File(WindowsPath.forIo(targetPath)).rename(backupPath);
    try {
      await _moveFile(sourcePath, targetPath);
    } catch (_) {
      try {
        await File(WindowsPath.forIo(backupPath)).rename(targetPath);
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

  static Future<String> _backupPath(String targetPath) async {
    final directory = p.windows.dirname(targetPath);
    for (var attempt = 0; attempt < 8; attempt++) {
      final suffix = List.generate(
        4,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final candidate = p.windows.join(directory, '.broom-backup-$suffix.tmp');
      try {
        final type = await FileSystemEntity.type(
          WindowsPath.forIo(candidate),
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) return candidate;
      } on FileSystemException {
        // Try another candidate.
      }
    }
    throw FileSystemException('无法创建覆盖前的临时备份路径', targetPath);
  }

  Future<void> _moveFile(String sourcePath, String destinationPath) async {
    final source = File(WindowsPath.forIo(sourcePath));
    final destination = WindowsPath.forIo(destinationPath);
    try {
      await source.rename(destination);
      return;
    } on FileSystemException {
      // Rename only works within one volume; fall through for cross-volume
      // moves. A locked source will also be cleaned up safely below.
    }

    await source.copy(destination);
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
    final ioPath = WindowsPath.forIo(path);
    var readOnly = false;
    try {
      final stat = await File(ioPath).stat();
      readOnly =
          stat.type == FileSystemEntityType.file && isReadOnlyMode(stat.mode);
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
      await File(ioPath).delete();
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

  static Future<void> _deleteSessionDirectory(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A failed cleanup must not turn a completed undo into an error.
    }
  }

  Future<Map<String, dynamic>?> _readSessionJson(Directory sessionDir) async {
    final file = File(p.windows.join(sessionDir.path, 'session.json'));
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> _writeSessionJson(
    Directory sessionDir,
    Map<String, dynamic> data,
  ) async {
    final file = File(p.windows.join(sessionDir.path, 'session.json'));
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(file.path);
  }

  Future<List<_StoredEntry>> _readEntries(Directory sessionDir) async {
    final file = File(p.windows.join(sessionDir.path, 'entries.jsonl'));
    if (!await file.exists()) return const [];
    final entries = <_StoredEntry>[];
    try {
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final map = jsonDecode(line);
          if (map is! Map<String, dynamic>) continue;
          final originalPath = map['originalPath'];
          final rootPath = map['rootPath'];
          final storedName = map['storedName'];
          final size = map['size'];
          if (originalPath is! String ||
              rootPath is! String ||
              storedName is! String ||
              size is! num) {
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
          continue;
        }
      }
    } on FileSystemException {
      return entries;
    }
    return entries;
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

  static Future<Set<String>> _readRestoredNames(Directory sessionDir) async {
    final file = File(p.windows.join(sessionDir.path, 'restored.jsonl'));
    if (!await file.exists()) return <String>{};
    try {
      final lines = await file.readAsLines();
      return lines
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toSet();
    } on FileSystemException {
      return <String>{};
    }
  }

  Future<void> _writePlan(Directory sessionDir, List<JunkItem> items) async {
    final planFile = File(p.windows.join(sessionDir.path, 'plan.jsonl'));
    final temp = File('${planFile.path}.tmp');
    final sink = temp.openWrite();
    var closed = false;
    try {
      for (final item in items) {
        sink.writeln(
          jsonEncode({
            'originalPath': item.path,
            'rootPath': item.rootPath,
            'ruleId': item.ruleId,
            'size': item.size,
            'modified': item.modified.toUtc().toIso8601String(),
          }),
        );
      }
      await sink.close();
      closed = true;
    } finally {
      if (!closed) {
        try {
          await sink.close();
        } on FileSystemException {
          // The incomplete temporary plan is removed below.
        }
        try {
          await temp.delete();
        } on FileSystemException {
          // A leftover temporary plan is never read.
        }
      }
    }
    try {
      await temp.rename(planFile.path);
    } on FileSystemException {
      try {
        await temp.delete();
      } on FileSystemException {
        // A leftover temporary plan is never read.
      }
      rethrow;
    }
  }

  Future<List<JunkItem>> _readPlan(Directory sessionDir) async {
    final file = File(p.windows.join(sessionDir.path, 'plan.jsonl'));
    if (!await file.exists()) return const [];
    final items = <JunkItem>[];
    try {
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final map = jsonDecode(line);
          if (map is! Map<String, dynamic>) continue;
          final originalPath = map['originalPath'];
          final rootPath = map['rootPath'];
          final size = map['size'];
          if (originalPath is! String ||
              originalPath.isEmpty ||
              !p.windows.isAbsolute(originalPath) ||
              rootPath is! String ||
              rootPath.isEmpty ||
              !p.windows.isAbsolute(rootPath) ||
              size is! num ||
              size < 0) {
            continue;
          }
          final rawModified = map['modified'];
          final modified = rawModified is String
              ? DateTime.tryParse(rawModified)
              : null;
          final rawRuleId = map['ruleId'];
          items.add(
            JunkItem(
              ruleId: rawRuleId is String ? rawRuleId : '',
              rootPath: rootPath,
              path: originalPath,
              size: size.toInt(),
              modified: modified ?? _clock(),
            ),
          );
        } on FormatException {
          continue;
        }
      }
    } on FileSystemException {
      return items;
    }
    return items;
  }

  static Future<void> _deletePlanFile(Directory sessionDir) async {
    try {
      final file = File(p.windows.join(sessionDir.path, 'plan.jsonl'));
      if (await file.exists()) {
        await file.delete();
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
