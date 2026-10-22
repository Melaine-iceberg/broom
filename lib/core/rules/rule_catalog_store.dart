import 'dart:convert';
import 'dart:io';

import '../models/cleaner_rule.dart';
import '../platform/path_semantics.dart';
import 'rule_catalog.dart';
import 'windows_rules.dart';

/// Persists an activated rule catalog and keeps the previous one for rollback.
///
/// Loading is synchronous because the app needs the active rule list before the
/// first frame. Corrupt or incompatible catalogs fall back to the built-in
/// catalog and surface [loadError] instead of being partially applied.
class RuleCatalogStore {
  RuleCatalogStore({
    required this.directoryPath,
    List<CleanerRule>? builtinRules,
    PathSemantics? semantics,
  }) : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform(),
       builtin = RuleCatalog(
         version: 'builtin',
         source: 'builtin',
         rules: builtinRules ?? windowsCleanupRules,
       ) {
    if (!this.semantics.isAbsolute(directoryPath)) {
      throw ArgumentError.value(directoryPath, 'directoryPath', '规则目录必须是绝对路径');
    }
    _current = builtin;
  }

  static const activeFileName = 'active.json';
  static const previousFileName = 'previous.json';

  static String defaultDirectory(
    String quarantineRoot, {
    PathSemantics? semantics,
  }) {
    final paths = semantics ?? PathSemanticsFactory.forCurrentPlatform();
    return paths.join(paths.dirname(quarantineRoot), 'rules');
  }

  final String directoryPath;
  final PathSemantics semantics;
  final RuleCatalog builtin;

  late RuleCatalog _current;
  String? _loadError;

  RuleCatalog get current => _current;
  String? get loadError => _loadError;

  String get activePath => semantics.join(directoryPath, activeFileName);
  String get previousPath => semantics.join(directoryPath, previousFileName);

  bool get hasPrevious => File(previousPath).existsSync();

  RuleCatalog loadSync() {
    _loadError = null;
    try {
      final active = File(activePath);
      if (!active.existsSync()) {
        _current = builtin;
        return _current;
      }
      final decoded = jsonDecode(active.readAsStringSync());
      final catalog = RuleCatalogCodec.decodeCatalog(decoded);
      _validate(catalog);
      _current = catalog;
    } on FormatException catch (error) {
      _loadError = '规则目录无效，已回退到内置规则：${error.message}';
      _current = builtin;
    } on FileSystemException catch (error) {
      _loadError = '无法读取规则目录，已回退到内置规则：${error.message}';
      _current = builtin;
    }
    return _current;
  }

  Future<void> saveActive(RuleCatalog catalog) async {
    _validate(catalog);
    final directory = Directory(directoryPath);
    await directory.create(recursive: true);
    final active = File(activePath);
    if (await active.exists()) {
      await _writeAtomic(previousPath, await active.readAsString());
    }
    await _writeAtomic(
      activePath,
      const JsonEncoder.withIndent('  ')
          .convert(RuleCatalogCodec.encodeCatalog(catalog)),
    );
    _current = catalog;
    _loadError = null;
  }

  Future<RuleCatalog?> rollback() async {
    final previous = File(previousPath);
    if (!await previous.exists()) return null;
    final catalog = RuleCatalogCodec.decodeCatalog(
      jsonDecode(await previous.readAsString()),
    );
    _validate(catalog);
    await _writeAtomic(
      activePath,
      const JsonEncoder.withIndent('  ')
          .convert(RuleCatalogCodec.encodeCatalog(catalog)),
    );
    await previous.delete();
    _current = catalog;
    _loadError = null;
    return catalog;
  }

  Future<RuleCatalog> resetToBuiltin() async {
    final active = File(activePath);
    if (await active.exists()) {
      await _writeAtomic(previousPath, await active.readAsString());
      await active.delete();
    }
    _current = builtin;
    _loadError = null;
    return builtin;
  }

  void _validate(RuleCatalog catalog) {
    final baselineIds = {for (final rule in builtin.rules) rule.id};
    final ids = catalog.rules.map((rule) => rule.id).toSet();
    final missing = baselineIds.where((id) => !ids.contains(id)).toList();
    if (missing.isNotEmpty) {
      throw FormatException('规则目录缺少内置规则：${missing.join(', ')}');
    }
  }

  Future<void> _writeAtomic(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString(content, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(path);
  }
}
