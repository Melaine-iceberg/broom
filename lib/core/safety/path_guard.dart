import 'dart:io';

import '../platform/path_semantics.dart';

class PathGuard {
  PathGuard({required List<String> protectedRoots, PathSemantics? semantics})
    : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform(),
      _protectedRoots = _normalizeRoots(
        protectedRoots,
        semantics ?? PathSemanticsFactory.forCurrentPlatform(),
      );

  static List<String> _normalizeRoots(
    List<String> protectedRoots,
    PathSemantics semantics,
  ) => protectedRoots
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
      semantics: const WindowsPathSemantics(),
    );
  }

  factory PathGuard.forPosix({
    List<String> additionalProtectedRoots = const [],
  }) {
    return PathGuard(
      protectedRoots: [
        '/usr',
        '/etc',
        '/boot',
        '/dev',
        '/proc',
        '/sys',
        '/run',
        '/bin',
        '/sbin',
        '/lib',
        '/lib64',
        '/opt',
        '/var',
        '/snap',
        '/nix',
        ...additionalProtectedRoots,
      ],
      semantics: const PosixPathSemantics(),
    );
  }

  final PathSemantics semantics;
  final List<String> _protectedRoots;

  List<String> get protectedRoots => List.unmodifiable(_protectedRoots);

  String _key(String path) => semantics.key(path);

  /// Retained for persisted records created before path semantics were
  /// injectable. Prefer [PathSemantics.key] in new code.
  static String normalize(String path) {
    final semantics = PathSemanticsFactory.forCurrentPlatform();
    return semantics.normalize(semantics.absolute(semantics.canonical(path)));
  }

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
