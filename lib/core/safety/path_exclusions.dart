import '../platform/path_semantics.dart';

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
  PathExclusions(
    Iterable<String> paths, {
    PathSemantics? semantics,
  }) : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform(),
       paths = List.unmodifiable(
         _normalize(paths, semantics ?? PathSemanticsFactory.forCurrentPlatform()),
       );

  PathExclusions.empty({PathSemantics? semantics})
    : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform(),
      paths = const [];

  final PathSemantics semantics;

  @override
  final List<String> paths;

  @override
  bool excludes(String path) {
    final key = semantics.key(path);
    return paths.any(
      (excluded) => semantics.isWithin(semantics.key(excluded), key),
    );
  }

  bool intersects(String root) {
    final rootKey = semantics.key(root);
    return paths.any((excluded) {
      final excludedKey = semantics.key(excluded);
      return semantics.isWithin(rootKey, excludedKey) ||
          semantics.isWithin(excludedKey, rootKey);
    });
  }

  static bool overlaps(
    String first,
    String second, {
    PathSemantics? semantics,
  }) {
    final paths = semantics ?? PathSemanticsFactory.forCurrentPlatform();
    final firstKey = paths.key(first);
    final secondKey = paths.key(second);
    return paths.isWithin(firstKey, secondKey) ||
        paths.isWithin(secondKey, firstKey);
  }

  static List<String> _normalize(
    Iterable<String> paths,
    PathSemantics semantics,
  ) {
    final byKey = <String, String>{};
    for (final path in paths) {
      if (path.trim().isEmpty) continue;
      final normalized = semantics.normalize(semantics.absolute(path));
      byKey.putIfAbsent(semantics.key(normalized), () => normalized);
    }
    return byKey.values.toList()..sort();
  }
}
