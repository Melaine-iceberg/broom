import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import '../models/scan_models.dart';
import '../platform/path_semantics.dart';
import 'scan_writer_isolate.dart';

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
  const StoredScanData({
    required this.summary,
    required this.groups,
    required this.extensionsByRule,
    this.roots = ScanRoots.empty,
    this.totalItems = 0,
  });

  final StoredScanSummary summary;

  /// Items grouped by rule id and sorted by size, descending.
  ///
  /// Parsing, grouping and sorting all happen in a worker isolate; the calling
  /// isolate only receives the finished lists.
  final Map<String, List<JunkItem>> groups;

  /// Distinct extensions per rule id, collected while grouping in the worker.
  final Map<String, Set<String>> extensionsByRule;

  /// Root table for the items in [groups]. Rebuilt from the `ruleId` /
  /// `rootPath` columns in `items.jsonl`, so the file format is unchanged.
  final ScanRoots roots;

  /// Valid items read from disk before [allowedRuleIds] filtering.
  final int totalItems;
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
    required ScanRoots roots,
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
      roots,
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

  Future<StoredScanData?> load(
    StoredScanSummary summary, {
    Set<String>? allowedRuleIds,
  }) async {
    final itemsFile = File(
      semantics.forIo(
        semantics.join(
          semantics.join(rootDirectory, summary.id),
          _itemsFileName,
        ),
      ),
    );
    if (!await itemsFile.exists()) return null;
    final itemsPath = itemsFile.path;
    try {
      final parsed = await Isolate.run(
        () => _parseItemsFile(itemsPath, allowedRuleIds),
      );
      return StoredScanData(
        summary: summary,
        groups: parsed.groups,
        extensionsByRule: parsed.extensionsByRule,
        roots: parsed.roots,
        totalItems: parsed.totalItems,
      );
    } on FileSystemException catch (error) {
      throw ScanResultStoreException('无法读取上次扫描结果：${error.message}');
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
    this.roots,
  );

  final String id;
  final List<String> ruleIds;
  final String rulesVersion;
  final ScanRoots roots;
  final Directory _directory;
  final ScanResultStore _store;
  ScanWriterIsolate? _writer;
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
    _writer = await ScanWriterIsolate.start(
      path: file.path,
      roots: roots,
      maxBytes: _store.maxItemsFileBytes,
    );
  }

  Future<void> addItems(List<JunkItem> items) async {
    if (_closed || _persistenceLimited || items.isEmpty) return;
    final writer = _writer;
    if (writer == null) return;
    try {
      await writer.append(items);
    } on ScanWriterException catch (failure) {
      _persistenceError = failure.message;
      _persistenceLimited = true;
    }
    _itemsWritten = writer.itemsWritten;
    if (writer.limited) _persistenceLimited = true;
    final writerError = writer.error;
    if (writerError != null) {
      _persistenceError = writerError;
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
    final writer = _writer;
    _writer = null;
    try {
      await writer?.complete();
    } on ScanWriterException catch (failure) {
      throw ScanResultStoreException('无法保存扫描结果：${failure.message}');
    }
    _itemsWritten = writer?.itemsWritten ?? _itemsWritten;
    if (writer?.limited ?? false) _persistenceLimited = true;
    final writerError = writer?.error;
    if (writerError != null) {
      _persistenceError = writerError;
      _persistenceLimited = true;
    }
    try {
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
    final writer = _writer;
    _writer = null;
    await writer?.abort();
    _itemsWritten = writer?.itemsWritten ?? _itemsWritten;
    if (writer?.limited ?? false) _persistenceLimited = true;
    final writerError = writer?.error;
    if (writerError != null) {
      _persistenceError = writerError;
      _persistenceLimited = true;
    }
    try {
      if (await _directory.exists()) {
        await _directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Best effort; orphan directories are ignored by readers.
    }
  }
}

class _ParsedScanFile {
  const _ParsedScanFile({
    required this.groups,
    required this.extensionsByRule,
    required this.roots,
    required this.totalItems,
  });

  final Map<String, List<JunkItem>> groups;
  final Map<String, Set<String>> extensionsByRule;
  final ScanRoots roots;
  final int totalItems;
}

/// Parses, filters, groups and sorts a result file inside a worker isolate.
Future<_ParsedScanFile> _parseItemsFile(
  String path,
  Set<String>? allowedRuleIds,
) async {
  final groups = <String, List<JunkItem>>{};
  final extensionsByRule = <String, Set<String>>{};
  final roots = <ScanRoot>[];
  final rootIndexes = <String, int>{};
  var totalItems = 0;
  await for (final line in File(
    path,
  ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final decoded = _decodeLine(line);
    if (decoded == null) continue;
    totalItems++;
    if (allowedRuleIds != null && !allowedRuleIds.contains(decoded.ruleId)) {
      continue;
    }
    final rootIndex = rootIndexes.putIfAbsent(
      '${decoded.ruleId}\u0000${decoded.rootPath}',
      () {
        roots.add(ScanRoot(ruleId: decoded.ruleId, rootPath: decoded.rootPath));
        return roots.length - 1;
      },
    );
    (groups[decoded.ruleId] ??= []).add(
      JunkItem(
        rootIndex: rootIndex,
        path: decoded.path,
        size: decoded.size,
        modifiedMicros: decoded.modifiedMicros,
      ),
    );
    final extension = extensionOfPath(decoded.path);
    if (extension.isNotEmpty) {
      (extensionsByRule[decoded.ruleId] ??= <String>{}).add(extension);
    }
  }
  for (final items in groups.values) {
    items.sort((a, b) => b.size.compareTo(a.size));
  }
  return _ParsedScanFile(
    groups: groups,
    extensionsByRule: extensionsByRule,
    roots: ScanRoots(roots),
    totalItems: totalItems,
  );
}

({String ruleId, String rootPath, String path, int size, int modifiedMicros})?
_decodeLine(String line) {
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
    return (
      ruleId: ruleId,
      rootPath: rootPath,
      path: path,
      size: size,
      modifiedMicros: time.microsecondsSinceEpoch,
    );
  } on FormatException {
    return null;
  }
}
