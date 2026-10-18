import 'dart:io';

import 'package:path/path.dart' as p;

class PathGuard {
  PathGuard({required List<String> protectedRoots})
      : _protectedRoots = protectedRoots
            .where((root) => root.trim().isNotEmpty)
            .map((root) => normalize(root).toLowerCase())
            .toList();

  factory PathGuard.forWindows({
    Map<String, String>? environment,
    List<String> additionalProtectedRoots = const [],
  }) {
    final env = {
      for (final entry in (environment ?? Platform.environment).entries)
        entry.key.toLowerCase(): entry.value,
    };
    String? lookup(String key) {
      final value = env[key.toLowerCase()];
      return value == null || value.isEmpty ? null : value;
    }

    return PathGuard(
      protectedRoots: [
        for (final name in const [
          'WINDIR',
          'ProgramFiles',
          'ProgramFiles(x86)',
          'ProgramData',
        ])
          ?lookup(name),
        ...additionalProtectedRoots,
      ],
    );
  }

  final List<String> _protectedRoots;

  List<String> get protectedRoots => List.unmodifiable(_protectedRoots);

  static String normalize(String path) =>
      p.windows.normalize(p.windows.absolute(path));

  bool isWithin(String root, String candidate) {
    final rootKey = normalize(root).toLowerCase();
    final candidateKey = normalize(candidate).toLowerCase();
    return _isWithinKey(rootKey, candidateKey);
  }

  bool isProtected(String path) {
    final key = normalize(path).toLowerCase();
    return _protectedRoots.any((root) => _isWithinKey(root, key));
  }

  bool allows({required String path, required String root}) {
    final pathKey = normalize(path).toLowerCase();
    final rootKey = normalize(root).toLowerCase();
    if (!_isWithinKey(rootKey, pathKey)) return false;
    if (pathKey == rootKey) return false;
    return !_protectedRoots.any((protected) => _isWithinKey(protected, pathKey));
  }

  static bool _isWithinKey(String rootKey, String candidateKey) {
    if (candidateKey == rootKey) return true;
    final prefix = rootKey.endsWith(p.windows.separator)
        ? rootKey
        : '$rootKey${p.windows.separator}';
    return candidateKey.startsWith(prefix);
  }
}
