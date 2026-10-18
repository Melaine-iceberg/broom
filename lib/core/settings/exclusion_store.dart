import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../safety/path_exclusions.dart';
import '../safety/path_guard.dart';

const _schemaVersion = 1;

class ExclusionException implements Exception {
  const ExclusionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ExclusionStore implements PathExclusionSource {
  ExclusionStore({required this.filePath}) {
    if (!p.windows.isAbsolute(filePath)) {
      throw ArgumentError.value(filePath, 'filePath', '排除列表路径必须是绝对路径');
    }
  }

  static const fileName = 'exclusions.json';

  static String defaultFilePath(String quarantineRoot) =>
      p.windows.join(p.windows.dirname(quarantineRoot), fileName);

  final String filePath;

  PathExclusions _exclusions = PathExclusions.empty();
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
      (existing) => PathExclusions.overlaps(existing, normalized),
    )) {
      throw const ExclusionException('该文件夹与已有排除项重叠，请先移除已有排除项。');
    }

    final next = PathExclusions([...paths, normalized]);
    await _save(next);
    _exclusions = next;
    _loadError = null;
  }

  Future<void> remove(String path) async {
    _requireLoaded();
    final key = _key(path);
    final remaining = paths.where((existing) => _key(existing) != key).toList();
    if (remaining.length == paths.length) return;

    final next = PathExclusions(remaining);
    await _save(next);
    _exclusions = next;
    _loadError = null;
  }

  Future<void> reset() async {
    final next = PathExclusions.empty();
    await _save(next);
    _exclusions = next;
    _loaded = true;
    _loadError = null;
  }

  Future<void> _load() async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        _exclusions = PathExclusions.empty();
        _loaded = true;
        _loadError = null;
        return;
      }

      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map<String, dynamic>) {
        throw const FormatException('排除列表格式无效');
      }
      final version = value['schemaVersion'];
      if (version != _schemaVersion) {
        throw FormatException('不支持的排除列表版本：$version');
      }
      final rawPaths = value['paths'];
      if (rawPaths is! List) {
        throw const FormatException('排除列表缺少路径数据');
      }

      final paths = <String>[];
      for (final raw in rawPaths) {
        if (raw is! String || raw.trim().isEmpty) {
          throw const FormatException('排除列表包含无效路径');
        }
        paths.add(_normalizeAbsolute(raw));
      }

      _exclusions = PathExclusions(paths);
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
        jsonEncode({
          'schemaVersion': _schemaVersion,
          'paths': exclusions.paths,
        }),
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

  static String _normalizeAbsolute(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      throw const ExclusionException('排除路径不能为空。');
    }
    if (!p.windows.isAbsolute(trimmed)) {
      throw const ExclusionException('排除路径必须是绝对路径。');
    }
    final normalized = PathGuard.normalize(trimmed);
    if (p.windows.rootPrefix(normalized) == normalized) {
      throw const ExclusionException('不能排除整个磁盘或共享根目录。');
    }
    return normalized;
  }

  static String _key(String path) => PathGuard.normalize(path).toLowerCase();
}
