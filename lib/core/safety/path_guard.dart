import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/path_semantics.dart';
import '../platform/windows_path.dart';

class PathGuard {
  PathGuard({
    required List<String> protectedRoots,
    this.semantics = const WindowsPathSemantics(),
  }) : _protectedRoots = protectedRoots
           .where((root) => root.trim().isNotEmpty)
           .map(semantics.key)
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

  final PathSemantics semantics;
  final List<String> _protectedRoots;

  List<String> get protectedRoots => List.unmodifiable(_protectedRoots);

  String _key(String path) => semantics.key(path);

  /// Retained for persisted records created before path semantics were
  /// injectable. Prefer [PathSemantics.key] in new code.
  static String normalize(String path) =>
      p.windows.normalize(p.windows.absolute(WindowsPath.canonical(path)));

  bool isWithin(String root, String candidate) =>
      semantics.isWithin(root, candidate);

  bool isProtected(String path) {
    final key = _key(path);
    return _protectedRoots.any((root) => semantics.isWithin(root, key));
  }

  bool allows({required String path, required String root}) {
    final pathKey = _key(path);
    final rootKey = _key(root);
    if (!semantics.isWithin(rootKey, pathKey)) return false;
    if (pathKey == rootKey) return false;
    return !_protectedRoots.any(
      (protected) => semantics.isWithin(protected, pathKey),
    );
  }
}
