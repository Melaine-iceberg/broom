import 'dart:convert';
import 'dart:io';

import '../models/clean_history_models.dart';
import '../platform/path_semantics.dart';

const _schemaVersion = 1;

class CleanHistoryException implements Exception {
  const CleanHistoryException(this.message, {this.corrupt = false});

  final String message;
  final bool corrupt;

  @override
  String toString() => message;
}

/// Persistent, bounded cleaning history stored outside the quarantine tree.
///
/// History is informational: losing a record must never make cleaning fail.
/// [upsert] replaces the previous record for the same session so a resumed
/// cleanup updates its entry instead of appending duplicates.
class CleanHistoryStore {
  CleanHistoryStore({required this.filePath, PathSemantics? semantics})
    : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform() {
    if (!this.semantics.isAbsolute(filePath)) {
      throw ArgumentError.value(filePath, 'filePath', '清理历史路径必须是绝对路径');
    }
  }

  static const fileName = 'clean_history.json';
  static const int maxRecords = 200;

  static String defaultFilePath(
    String quarantineRoot, {
    PathSemantics? semantics,
  }) {
    final paths = semantics ?? PathSemanticsFactory.forCurrentPlatform();
    return paths.join(paths.dirname(quarantineRoot), fileName);
  }

  final String filePath;
  final PathSemantics semantics;

  Future<List<CleanHistoryRecord>> load() async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const CleanHistoryException('清理历史格式无效', corrupt: true);
      }
      final version = decoded['schemaVersion'];
      if (version != _schemaVersion) {
        throw CleanHistoryException('不支持的清理历史版本：$version', corrupt: true);
      }
      final rawRecords = decoded['records'];
      if (rawRecords is! List) {
        throw const CleanHistoryException('清理历史缺少记录数据', corrupt: true);
      }
      final records = <CleanHistoryRecord>[];
      for (final rawRecord in rawRecords) {
        final record = CleanHistoryRecord.fromJson(rawRecord);
        if (record != null) records.add(record);
      }
      records.sort((a, b) => b.completedAt.compareTo(a.completedAt));
      return List.unmodifiable(records);
    } on FormatException catch (error) {
      throw CleanHistoryException('清理历史数据无效：${error.message}', corrupt: true);
    } on FileSystemException catch (error) {
      throw CleanHistoryException('无法读取清理历史：${error.message}');
    }
  }

  Future<void> upsert(CleanHistoryRecord record) async {
    var records = <CleanHistoryRecord>[];
    try {
      records = List.of(await load());
    } on CleanHistoryException catch (error) {
      if (!error.corrupt) rethrow;
      await _archiveCorruptFile();
    }

    records.removeWhere((existing) => existing.sessionId == record.sessionId);
    records.insert(0, record);
    if (records.length > maxRecords) {
      records = records.sublist(0, maxRecords);
    }

    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final temp = File('$filePath.tmp');
      await temp.writeAsString(
        jsonEncode({
          'schemaVersion': _schemaVersion,
          'records': [for (final entry in records) entry.toJson()],
        }),
        flush: true,
      );
      await temp.rename(filePath);
    } on FileSystemException catch (error) {
      throw CleanHistoryException('无法保存清理历史：${error.message}');
    }
  }

  /// A corrupt history is never allowed to block new records. Keep the broken
  /// file for diagnostics and start a fresh list.
  Future<void> _archiveCorruptFile() async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return;
      final suffix = DateTime.now().millisecondsSinceEpoch;
      await file.rename('$filePath.corrupt-$suffix');
    } on FileSystemException {
      // If archiving fails, overwriting the file below is still preferable to
      // permanently disabling history.
    }
  }
}
