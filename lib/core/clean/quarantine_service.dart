import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../models/clean_models.dart';
import '../models/scan_models.dart';
import '../safety/path_guard.dart';

const _schemaVersion = 1;
const _maxFailureDetails = 100;

class QuarantineService {
  factory QuarantineService({
    required String quarantineRoot,
    required PathGuard guard,
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
    return QuarantineService._(normalized, guard, clock ?? DateTime.now);
  }

  QuarantineService._(this.quarantineRoot, this.guard, this._clock);

  final String quarantineRoot;
  final PathGuard guard;
  final DateTime Function() _clock;
  static final Random _random = Random.secure();

  Future<CleanReport> clean(
    List<JunkItem> items, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final failures = <CleanFailure>[];
    var failureCount = 0;
    var movedCount = 0;
    var movedBytes = 0;
    var processed = 0;
    var cancelled = false;
    var lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);
    RandomAccessFile? entriesFile;
    Directory? sessionDir;
    String? sessionId;
    String? createdAt;

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

    CleanReport buildReport() => CleanReport(
      sessionId: sessionId,
      movedCount: movedCount,
      movedBytes: movedBytes,
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
      cancelled: cancelled,
    );

    try {
      if (items.isEmpty) return buildReport();

      final baseDir = Directory(quarantineRoot);
      await baseDir.create(recursive: true);

      sessionId = await _createSessionId(baseDir);
      sessionDir = Directory(p.windows.join(baseDir.path, sessionId));
      final filesDir = Directory(p.windows.join(sessionDir.path, 'files'));
      await filesDir.create(recursive: true);

      final now = _clock();
      createdAt = now.toUtc().toIso8601String();
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
      });

      entriesFile = await File(p.windows.join(sessionDir.path, 'entries.jsonl'))
          .open(mode: FileMode.write);

      var sequence = 0;
      for (final item in items) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        processed++;

        if (!guard.allows(path: item.path, root: item.rootPath)) {
          recordFailure(item.path, '未通过路径安全检查');
          report(currentPath: item.path);
          continue;
        }

        FileSystemEntityType type;
        try {
          type = await FileSystemEntity.type(item.path, followLinks: false);
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
        try {
          size = await File(item.path).length();
        } on FileSystemException catch (error) {
          recordFailure(item.path, error);
          report(currentPath: item.path);
          continue;
        }

        sequence++;
        final storedName = _storedName(sequence, item.path);
        final entry = {
          'originalPath': item.path,
          'rootPath': item.rootPath,
          'storedName': storedName,
          'size': size,
          'modified': item.modified.toUtc().toIso8601String(),
          'ruleId': item.ruleId,
        };

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

      if (movedCount == 0) {
        await _deleteSessionDirectory(sessionDir);
        sessionDir = null;
        sessionId = null;
        report(force: true);
        return buildReport();
      }

      await _writeSessionJson(sessionDir, {
        'schemaVersion': _schemaVersion,
        'id': sessionId,
        'createdAt': createdAt,
        'status': 'ready',
        'entryCount': movedCount,
        'totalBytes': movedBytes,
        'pendingCount': movedCount,
        'pendingBytes': movedBytes,
        'failureCount': failureCount,
      });
      report(force: true);
      return buildReport();
    } catch (_) {
      try {
        await entriesFile?.close();
      } on FileSystemException {
        // Ignore cleanup failures; the session metadata is updated below.
      }
      entriesFile = null;
      if (sessionDir != null && movedCount > 0) {
        try {
          await _writeSessionJson(sessionDir, {
            'schemaVersion': _schemaVersion,
            'id': sessionId,
            'createdAt': createdAt,
            'status': 'partial',
            'entryCount': movedCount,
            'totalBytes': movedBytes,
            'pendingCount': movedCount,
            'pendingBytes': movedBytes,
            'failureCount': failureCount,
          });
        } on FileSystemException {
          // The initial metadata still allows crash recovery on next start.
        }
      } else if (sessionDir != null) {
        await _deleteSessionDirectory(sessionDir);
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

  Future<UndoReport> undo(String sessionId, {Set<String>? storedNames}) async {
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
    var missingCount = 0;

    void recordFailure(String path, Object error) {
      failureCount++;
      if (failures.length < _maxFailureDetails) {
        failures.add(CleanFailure(path: path, reason: _failureReason(error)));
      }
    }

    for (final entry in targets) {
      if (restoredNames.contains(entry.storedName)) continue;
      if (!_isSafeStoredName(entry.storedName)) {
        recordFailure(entry.originalPath, '隔离区记录包含非法文件名');
        continue;
      }

      final storedPath = p.windows.join(filesDir, entry.storedName);
      FileSystemEntityType storedType;
      try {
        storedType = await FileSystemEntity.type(
          storedPath,
          followLinks: false,
        );
      } on FileSystemException catch (error) {
        recordFailure(entry.originalPath, error);
        continue;
      }
      if (storedType != FileSystemEntityType.file) {
        missingCount++;
        continue;
      }

      if (!guard.allows(path: entry.originalPath, root: entry.rootPath)) {
        recordFailure(entry.originalPath, '原路径未通过安全检查');
        continue;
      }

      FileSystemEntityType targetType;
      try {
        targetType = await FileSystemEntity.type(
          entry.originalPath,
          followLinks: false,
        );
      } on FileSystemException catch (error) {
        recordFailure(entry.originalPath, error);
        continue;
      }
      if (targetType != FileSystemEntityType.notFound) {
        conflictCount++;
        continue;
      }

      try {
        await Directory(p.windows.dirname(entry.originalPath))
            .create(recursive: true);
        await _moveFile(storedPath, entry.originalPath);
      } on FileSystemException catch (error) {
        recordFailure(entry.originalPath, error);
        continue;
      }

      restoredCount++;
      restoredBytes += entry.size;
      restoredAfter.add(entry.storedName);
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
      missingCount: missingCount,
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
      sessionRemoved: pendingCount == 0,
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
      if (_isSafeStoredName(entry.storedName)) {
        try {
          present =
              await FileSystemEntity.type(
                p.windows.join(filesDir, entry.storedName),
                followLinks: false,
              ) ==
              FileSystemEntityType.file;
        } on FileSystemException {
          present = true;
        }
      }

      var originalExists = false;
      try {
        originalExists =
            await FileSystemEntity.type(
              entry.originalPath,
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
            await entity.delete();
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

        final meta = await _readSessionJson(entity);
        if (meta == null) continue;

        var status = _parseStatus(meta['status']);
        if (status == null) continue;
        var entryCount = (meta['entryCount'] as num?)?.toInt() ?? 0;
        var totalBytes = (meta['totalBytes'] as num?)?.toInt() ?? 0;
        var pendingCount =
            (meta['pendingCount'] as num?)?.toInt() ?? entryCount;
        var pendingBytes =
            (meta['pendingBytes'] as num?)?.toInt() ?? totalBytes;

        if (status == QuarantineStatus.cleaning) {
          final entries = await _readEntries(entity);
          if (entries.isEmpty) continue;
          entryCount = entries.length;
          totalBytes = entries.fold<int>(
            0,
            (total, entry) => total + entry.size,
          );
          pendingCount = entryCount;
          pendingBytes = totalBytes;
          status = QuarantineStatus.partial;
        }

        if (pendingCount <= 0) continue;

        final createdAt =
            DateTime.tryParse('${meta['createdAt'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        sessions.add(
          QuarantineSessionInfo(
            id: id,
            createdAt: createdAt,
            status: status,
            entryCount: entryCount,
            totalBytes: totalBytes,
            pendingCount: pendingCount,
            pendingBytes: pendingBytes,
          ),
        );
      }
    } on FileSystemException {
      return sessions;
    }

    sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sessions;
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

  static String _failureReason(Object error) {
    if (error is String) return error;
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      if (code == 2 || code == 3) return '文件或目录不存在';
      if (code == 5) return '没有访问权限';
      if (code == 32 || code == 33) return '文件正被其他程序占用';
      return error.message;
    }
    return error.toString();
  }

  static Future<void> _moveFile(
    String sourcePath,
    String destinationPath,
  ) async {
    final source = File(sourcePath);
    try {
      await source.rename(destinationPath);
      return;
    } on FileSystemException {
      // Rename only works within one volume; fall through for cross-volume
      // moves. A locked source will also be cleaned up safely below.
    }

    await source.copy(destinationPath);
    try {
      await source.delete();
    } catch (_) {
      try {
        await File(destinationPath).delete();
      } on FileSystemException {
        // The orphaned copy is harmless and remains in the quarantine.
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
    await file.writeAsString(jsonEncode(data), flush: true);
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
          entries.add(
            _StoredEntry(
              originalPath: originalPath,
              rootPath: rootPath,
              storedName: storedName,
              size: size.toInt(),
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
  });

  final String originalPath;
  final String rootPath;
  final String storedName;
  final int size;
}
