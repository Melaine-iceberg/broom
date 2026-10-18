import 'package:path/path.dart' as p;

import 'path_guard.dart';

abstract interface class PathExclusionSource {
  List<String> get paths;

  bool excludes(String path);
}

class EmptyPathExclusionSource implements PathExclusionSource {
  const EmptyPathExclusionSource();

  @override
  List<String> get paths => const [];

  @override
  bool excludes(String path) => false;
}

class PathExclusions implements PathExclusionSource {
  PathExclusions(Iterable<String> paths)
    : paths = List.unmodifiable(_normalize(paths));

  PathExclusions.empty() : paths = const [];

  @override
  final List<String> paths;

  @override
  bool excludes(String path) {
    final key = _key(path);
    return paths.any((excluded) => _isWithin(_key(excluded), key));
  }

  bool intersects(String root) {
    final rootKey = _key(root);
    return paths.any((excluded) {
      final excludedKey = _key(excluded);
      return _isWithin(rootKey, excludedKey) || _isWithin(excludedKey, rootKey);
    });
  }

  static bool overlaps(String first, String second) {
    final firstKey = _key(first);
    final secondKey = _key(second);
    return _isWithin(firstKey, secondKey) || _isWithin(secondKey, firstKey);
  }

  static String _key(String path) => PathGuard.normalize(path).toLowerCase();

  static List<String> _normalize(Iterable<String> paths) {
    final byKey = <String, String>{};
    for (final path in paths) {
      if (path.trim().isEmpty) continue;
      final normalized = PathGuard.normalize(path);
      byKey.putIfAbsent(normalized.toLowerCase(), () => normalized);
    }
    return byKey.values.toList()..sort();
  }

  static bool _isWithin(String rootKey, String candidateKey) {
    if (candidateKey == rootKey) return true;
    final prefix = rootKey.endsWith(p.windows.separator)
        ? rootKey
        : '$rootKey${p.windows.separator}';
    return candidateKey.startsWith(prefix);
  }
}
