import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/system_models.dart';
import '../rules/windows_system_rules.dart';
import '../safety/path_guard.dart';
import 'system_access.dart';

abstract interface class SystemCachePlatform {
  bool get isSupported;
  List<SystemCacheRule> get rules;
  Future<List<String>> resolveRoots(SystemCacheRule rule);
}

class WindowsSystemCachePlatform implements SystemCachePlatform {
  WindowsSystemCachePlatform({
    required this.access,
    List<SystemCacheRule>? rules,
  }) : _rules = rules ?? windowsSystemCacheRules;

  final SystemAccess access;
  final List<SystemCacheRule> _rules;

  @override
  bool get isSupported => Platform.isWindows;

  @override
  List<SystemCacheRule> get rules => _rules;

  @override
  Future<List<String>> resolveRoots(SystemCacheRule rule) async {
    final roots = await access.locateSystemCacheRoots();
    final raw = roots.pathFor(rule.location).trim();
    if (raw.isEmpty || !p.windows.isAbsolute(raw)) {
      throw StateError('系统缓存目录不是绝对路径。');
    }

    final normalized = PathGuard.normalize(raw);
    if (p.windows.rootPrefix(normalized) == normalized) {
      throw StateError('系统缓存目录不能是磁盘根目录。');
    }
    if (!_matchesLocation(rule.location, normalized)) {
      throw StateError('系统缓存目录不符合规则声明：$normalized');
    }

    final type = await FileSystemEntity.type(normalized, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const [];
    if (type != FileSystemEntityType.directory) {
      throw StateError('系统缓存路径不是普通目录：$normalized');
    }
    return [normalized];
  }

  bool _matchesLocation(SystemCacheLocation location, String path) {
    final lower = path.toLowerCase();
    final basename = p.windows.basename(lower);
    final parent = p.windows.basename(p.windows.dirname(lower));
    return switch (location) {
      SystemCacheLocation.windowsUpdate =>
        basename == 'download' && parent == 'softwaredistribution',
      SystemCacheLocation.deliveryOptimization =>
        basename == 'cache' && parent == 'deliveryoptimization',
      SystemCacheLocation.windowsOld => basename == 'windows.old',
    };
  }
}

class UnsupportedSystemCachePlatform implements SystemCachePlatform {
  const UnsupportedSystemCachePlatform();

  @override
  bool get isSupported => false;

  @override
  List<SystemCacheRule> get rules => const [];

  @override
  Future<List<String>> resolveRoots(SystemCacheRule rule) async => const [];
}

SystemCachePlatform createSystemCachePlatform({required SystemAccess access}) {
  if (Platform.isWindows) {
    return WindowsSystemCachePlatform(access: access);
  }
  return const UnsupportedSystemCachePlatform();
}
