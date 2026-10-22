import 'dart:convert';
import 'dart:io';

import '../platform/path_semantics.dart';
import '../safety/path_exclusions.dart';
import 'config_schema.dart';

class ExclusionException implements Exception {
  const ExclusionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ExclusionStore implements PathExclusionSource {
  ExclusionStore({
    required this.filePath,
    PathSemantics? semantics,
  }) : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform() {
    if (!this.semantics.isAbsolute(filePath)) {
      throw ArgumentError.value(filePath, 'filePath', '排除列表路径必须是绝对路径');
    }
    _exclusions = PathExclusions.empty(semantics: this.semantics);
  }

  static const fileName = 'exclusions.json';

  static String defaultFilePath(String quarantineRoot, {PathSemantics? semantics}) {
    final paths = semantics ?? PathSemanticsFactory.forCurrentPlatform();
    return paths.join(paths.dirname(quarantineRoot), fileName);
  }

  final String filePath;
  final PathSemantics semantics;

  late PathExclusions _exclusions;
  Future<void>? _loading;
  bool _loaded = false;
  String? _loadError;

  @override
  List<String> get paths => _exclusions.paths;

  bool get isLoaded => _loaded;

  String? get loadError => _loadError;

  @override
  bool excludes(String path) => _exclusions.excludes(path);

  bool intersects(String root) => _exclusions.intersects(root);

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> add(String rawPath) async {
    _requireLoaded();
    final normalized = _normalizeAbsolute(rawPath);
    final type = FileSystemEntity.typeSync(normalized, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw ExclusionException('找不到文件夹：$normalized');
    }
    if (type != FileSystemEntityType.directory) {
      throw ExclusionException('只能排除文件夹：$normalized');
    }
    if (_exclusions.paths.any(
      (existing) =>
          PathExclusions.overlaps(existing, normalized, semantics: semantics),
    )) {
      throw const ExclusionException('该文件夹与已有排除项重叠，请先移除已有排除项。');
    }

    final next = PathExclusions([...paths, normalized], semantics: semantics);
    await _save(next);
    _exclusions = next;
    _loadError = null;
  }

  Future<void> remove(String path) async {
    _requireLoaded();
    final key = _key(path);
    final remaining = paths.where((existing) => _key(existing) != key).toList();
    if (remaining.length == paths.length) return;

    final next = PathExclusions(remaining, semantics: semantics);
    await _save(next);
    _exclusions = next;
    _loadError = null;
  }

  Future<void> reset() async {
    final next = PathExclusions.empty(semantics: semantics);
    await _save(next);
    _exclusions = next;
    _loaded = true;
    _loadError = null;
  }

  /// Replaces all exclusions, including when the current file is corrupted.
  ///
  /// Unlike [add], imported paths do not need to exist on this machine: a
  /// configuration may be restored before an external drive is connected.
  /// Relative paths, volume roots, and overlapping folders are still rejected
  /// so a bad import cannot silently widen an exclusion.
  Future<void> replaceAll(Iterable<String> rawPaths) async {
    final normalized = <String>[];
    final keys = <String>{};
    for (final rawPath in rawPaths) {
      final path = _normalizeAbsolute(rawPath);
      if (!keys.add(_key(path))) continue;
      if (normalized.any(
        (existing) =>
            PathExclusions.overlaps(existing, path, semantics: semantics),
      )) {
        throw ExclusionException('导入的排除项互相重叠，请先整理后重试：$path');
      }
      normalized.add(path);
    }

    final next = PathExclusions(normalized, semantics: semantics);
    await _save(next);
    _exclusions = next;
    _loaded = true;
    _loadError = null;
  }

  Future<void> _load() async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        _exclusions = PathExclusions.empty(semantics: semantics);
        _loaded = true;
        _loadError = null;
        return;
      }

      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map<String, dynamic>) {
        throw const FormatException('排除列表格式无效');
      }
      _exclusions = PathExclusions(
        decodeExclusionsDocument(value, semantics: semantics),
        semantics: semantics,
      );
      _loaded = true;
      _loadError = null;
    } on FormatException catch (error) {
      _loadError = '排除列表数据无效：${error.message}';
      rethrow;
    } on ExclusionException catch (error) {
      _loadError = error.message;
      rethrow;
    } on FileSystemException catch (error) {
      _loadError = '无法读取排除列表：${error.message}';
      rethrow;
    }
  }

  Future<void> _save(PathExclusions exclusions) async {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      final temp = File('$filePath.tmp');
      temp.writeAsStringSync(
        jsonEncode(encodeExclusionsDocument(exclusions.paths)),
        flush: true,
      );
      temp.renameSync(filePath);
    } on FileSystemException catch (error) {
      throw ExclusionException('无法保存排除列表：${error.message}');
    }
  }

  void _requireLoaded() {
    if (!_loaded) {
      throw const ExclusionException('排除列表尚未加载，请稍后重试。');
    }
  }

  String _normalizeAbsolute(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      throw const ExclusionException('排除路径不能为空。');
    }
    if (!semantics.isAbsolute(trimmed)) {
      throw const ExclusionException('排除路径必须是绝对路径。');
    }
    final normalized = semantics.normalize(semantics.absolute(trimmed));
    if (semantics.rootPrefix(normalized) == normalized) {
      throw const ExclusionException('不能排除整个磁盘、文件系统或共享根目录。');
    }
    return normalized;
  }

  String _key(String path) => semantics.key(path);
}
