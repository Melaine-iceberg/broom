import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/scan_models.dart';
import '../platform/path_semantics.dart';

const _schemaVersion = 1;
const _itemsFileName = 'items.jsonl';
const _metaFileName = 'meta.json';
const _latestFileName = 'latest.json';

class ScanResultStoreException implements Exception {
  const ScanResultStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class StoredScanSummary {
  const StoredScanSummary({
    required this.id,
    required this.completedAt,
    required this.scannedFiles,
    required this.foundFiles,
    required this.foundBytes,
    required this.issueCount,
    required this.errorCounts,
    required this.truncated,
    required this.ruleIds,
    required this.rulesVersion,
    required this.persistedItemCount,
    this.persistenceLimited = false,
    this.persistenceError,
  });

  final String id;
  final DateTime completedAt;
  final int scannedFiles;
  final int foundFiles;
  final int foundBytes;
  final int issueCount;
  final Map<ScanErrorKind, int> errorCounts;
  final bool truncated;
  final List<String> ruleIds;
  final String rulesVersion;
  final int persistedItemCount;
  final bool persistenceLimited;
  final String? persistenceError;

  bool isExpired(DateTime now, {Duration maxAge = const Duration(hours: 24)}) {
    return now.difference(completedAt) > maxAge;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': _schemaVersion,
    'id': id,
    'completedAt': completedAt.toUtc().toIso8601String(),
    'scannedFiles': scannedFiles,
    'foundFiles': foundFiles,
    'foundBytes': foundBytes,
    'issueCount': issueCount,
    'errorCounts': {
      for (final entry in errorCounts.entries) entry.key.name: entry.value,
    },
    'truncated': truncated,
    'ruleIds': ruleIds,
    'rulesVersion': rulesVersion,
    'persistedItemCount': persistedItemCount,
    'persistenceLimited': persistenceLimited,
    if (persistenceError != null) 'persistenceError': persistenceError,
  };

  static StoredScanSummary? fromJson(Object? value, String id) {
    if (value is! Map<String, dynamic>) return null;
    if (value['schemaVersion'] != _schemaVersion) return null;
    final completedAt = DateTime.tryParse('${value['completedAt']}');
    final ruleIds = value['ruleIds'];
    if (completedAt == null || ruleIds is! List) return null;
    final counts = <ScanErrorKind, int>{};
    final rawCounts = value['errorCounts'];
    if (rawCounts is Map) {
      for (final entry in rawCounts.entries) {
        final kind = ScanErrorKind.values
            .where((candidate) => candidate.name == entry.key)
            .firstOrNull;
        if (kind != null && entry.value is int) {
          counts[kind] = entry.value as int;
        }
      }
    }
    return StoredScanSummary(
      id: id,
      completedAt: completedAt,
      scannedFiles: _int(value['scannedFiles']),
      foundFiles: _int(value['foundFiles']),
      foundBytes: _int(value['foundBytes']),
      issueCount: _int(value['issueCount']),
      errorCounts: Map.unmodifiable(counts),
      truncated: value['truncated'] == true,
      ruleIds: List.unmodifiable(ruleIds.whereType<String>()),
      rulesVersion: '${value['rulesVersion'] ?? 'builtin'}',
      persistedItemCount: _int(value['persistedItemCount']),
      persistenceLimited: value['persistenceLimited'] == true,
      persistenceError: value['persistenceError'] is String
          ? value['persistenceError'] as String
          : null,
    );
  }

  static int _int(Object? value) => value is int ? value : 0;
}

class StoredScanData {
  const StoredScanData({required this.summary, required this.items});

  final StoredScanSummary summary;
  final List<JunkItem> items;
}

/// Streams scan batches into a per-scan directory and publishes a small
/// metadata file only after the scan completes. Interrupted scans leave an
/// orphan directory that is ignored and cleaned up on the next scan.
class ScanResultStore {
  ScanResultStore({
    required this.rootDirectory,
    this.maxItemsFileBytes = 1024 * 1024 * 1024,
    this.semantics = const WindowsPathSemantics(),
  }) {
    if (!semantics.isAbsolute(rootDirectory)) {
      throw ArgumentError.value(
        rootDirectory,
        'rootDirectory',
        '扫描结果目录必须是绝对路径',
      );
    }
  }

  final String rootDirectory;
  final int maxItemsFileBytes;
  final PathSemantics semantics;
  final Random _random = Random();

  static final _scanIdPattern = RegExp(r'^[0-9]{8}_[0-9]{9}_[0-9a-f]{4}$');

  String get _latestPath => semantics.join(rootDirectory, _latestFileName);

  Future<ScanResultWriter> begin({
    required List<String> ruleIds,
    required String rulesVersion,
  }) async {
    final root = Directory(semantics.forIo(rootDirectory));
    await root.create(recursive: true);
    final id = _newId();
    final directory = Directory(
      semantics.forIo(semantics.join(rootDirectory, id)),
    );
    await directory.create(recursive: true);
    final writer = ScanResultWriter._(
      id,
      directory,
      this,
      List.unmodifiable(ruleIds),
      rulesVersion,
    );
    await writer._open();
    return writer;
  }

  Future<StoredScanSummary?> loadLatest({
    Duration maxAge = const Duration(hours: 24),
    DateTime Function()? clock,
  }) async {
    try {
      final latestFile = File(semantics.forIo(_latestPath));
      if (!await latestFile.exists()) return null;
      final latest = jsonDecode(await latestFile.readAsString());
      if (latest is! Map<String, dynamic>) return null;
      final id = latest['id'];
      if (id is! String || !_scanIdPattern.hasMatch(id)) return null;
      final metaFile = File(
        semantics.forIo(
          semantics.join(semantics.join(rootDirectory, id), _metaFileName),
        ),
      );
      if (!await metaFile.exists()) return null;
      final meta = jsonDecode(await metaFile.readAsString());
      final summary = StoredScanSummary.fromJson(meta, id);
      if (summary == null) return null;
      final now = (clock ?? DateTime.now)();
      if (summary.isExpired(now, maxAge: maxAge)) {
        return null;
      }
      return summary;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<StoredScanData?> load(StoredScanSummary summary) async {
    final itemsFile = File(
      semantics.forIo(
        semantics.join(
          semantics.join(rootDirectory, summary.id),
          _itemsFileName,
        ),
      ),
    );
    if (!await itemsFile.exists()) return null;
    final items = <JunkItem>[];
    try {
      await for (final line
          in itemsFile
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final item = _decodeItem(line);
        if (item != null) items.add(item);
      }
    } on FileSystemException catch (error) {
      throw ScanResultStoreException('无法读取上次扫描结果：${error.message}');
    }
    return StoredScanData(summary: summary, items: items);
  }

  JunkItem? _decodeItem(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return null;
      final path = value['path'];
      final rootPath = value['rootPath'];
      final ruleId = value['ruleId'];
      final size = value['size'];
      final modified = value['modified'];
      if (path is! String ||
          rootPath is! String ||
          ruleId is! String ||
          size is! int ||
          modified is! String) {
        return null;
      }
      final time = DateTime.tryParse(modified);
      if (time == null) return null;
      return JunkItem(
        ruleId: ruleId,
        rootPath: rootPath,
        path: path,
        size: size,
        modified: time,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _publish(StoredScanSummary summary) async {
    final metaFile = File(
      semantics.forIo(
        semantics.join(
          semantics.join(rootDirectory, summary.id),
          _metaFileName,
        ),
      ),
    );
    await metaFile.writeAsString(jsonEncode(summary.toJson()), flush: true);
    final latest = File(semantics.forIo(_latestPath));
    final temp = File(semantics.forIo('$_latestPath.tmp'));
    await temp.writeAsString(
      jsonEncode({'schemaVersion': _schemaVersion, 'id': summary.id}),
      flush: true,
    );
    if (await latest.exists()) await latest.delete();
    await temp.rename(latest.path);
    await _cleanupExcept(summary.id);
  }

  Future<void> _cleanupExcept(String keepId) async {
    try {
      await for (final entity in Directory(
        semantics.forIo(rootDirectory),
      ).list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = semantics.basename(semantics.canonical(entity.path));
        if (name == keepId) continue;
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          // A concurrent reader can hold a file; leave it for the next scan.
        }
      }
    } on FileSystemException {
      // Cleanup is best effort.
    }
  }

  String _newId() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final suffix = _random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return '${stamp}_$suffix';
  }
}

class ScanResultWriter {
  ScanResultWriter._(
    this.id,
    this._directory,
    this._store,
    this.ruleIds,
    this.rulesVersion,
  );

  final String id;
  final List<String> ruleIds;
  final String rulesVersion;
  final Directory _directory;
  final ScanResultStore _store;
  IOSink? _sink;
  int _bytesWritten = 0;
  int _itemsWritten = 0;
  bool _closed = false;
  bool _persistenceLimited = false;
  String? _persistenceError;

  bool get persistenceLimited => _persistenceLimited;
  String? get persistenceError => _persistenceError;
  int get itemsWritten => _itemsWritten;

  Future<void> _open() async {
    final file = File(
      _store.semantics.forIo(
        _store.semantics.join(_directory.path, _itemsFileName),
      ),
    );
    _sink = file.openWrite();
  }

  Future<void> addItems(List<JunkItem> items) async {
    if (_closed || _persistenceLimited || items.isEmpty) return;
    final sink = _sink;
    if (sink == null) return;
    // Encode each line once and hand bytes to the sink. Encoding the line to
    // measure it and then writing the joined String re-encoded the whole batch
    // a second time, on the UI isolate, for every batch of every scan.
    final buffer = BytesBuilder(copy: false);
    for (final item in items) {
      final line = jsonEncode({
        'ruleId': item.ruleId,
        'rootPath': item.rootPath,
        'path': item.path,
        'size': item.size,
        'modified': item.modified.toUtc().toIso8601String(),
      });
      final lineBytes = utf8.encode(line);
      final cost = lineBytes.length + 1;
      if (_bytesWritten + cost > _store.maxItemsFileBytes) {
        _persistenceLimited = true;
        break;
      }
      buffer
        ..add(lineBytes)
        ..addByte(0x0A);
      _bytesWritten += cost;
      _itemsWritten++;
    }
    try {
      if (buffer.isNotEmpty) {
        sink.add(buffer.takeBytes());
        await sink.flush();
      }
    } on FileSystemException catch (error) {
      _persistenceError = error.message;
      _persistenceLimited = true;
    }
  }

  Future<StoredScanSummary> complete({
    required int scannedFiles,
    required int foundFiles,
    required int foundBytes,
    required int issueCount,
    required Map<ScanErrorKind, int> errorCounts,
    required bool truncated,
  }) async {
    if (_closed) {
      throw const ScanResultStoreException('扫描结果写入器已关闭');
    }
    _closed = true;
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      final summary = StoredScanSummary(
        id: id,
        completedAt: DateTime.now(),
        scannedFiles: scannedFiles,
        foundFiles: foundFiles,
        foundBytes: foundBytes,
        issueCount: issueCount,
        errorCounts: errorCounts,
        truncated: truncated,
        ruleIds: ruleIds,
        rulesVersion: rulesVersion,
        persistedItemCount: _itemsWritten,
        persistenceLimited: _persistenceLimited,
        persistenceError: _persistenceError,
      );
      await _store._publish(summary);
      return summary;
    } on FileSystemException catch (error) {
      throw ScanResultStoreException('无法保存扫描结果：${error.message}');
    }
  }

  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sink?.close();
    } on FileSystemException {
      // Best effort.
    }
    _sink = null;
    try {
      if (await _directory.exists()) {
        await _directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Best effort; orphan directories are ignored by readers.
    }
  }
}
