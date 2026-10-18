import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_path.dart';

/// Platform-neutral path operations used by the scan and safety layers.
///
/// Windows stays the only shipping target, but the engine must not grow new
/// `p.windows` calls directly. Tests can inject [PosixPathSemantics] to prove
/// case sensitivity, separators and containment rules are not hard-coded.
abstract interface class PathSemantics {
  String get separator;
  bool get caseSensitive;
  bool get supportsExtendedLengthPaths;

  String canonical(String path);
  String forIo(String path);
  String ensureLongPath(String path);
  String normalize(String path);
  String absolute(String path);
  bool isAbsolute(String path);
  String join(String parent, String child);
  String dirname(String path);
  String basename(String path);
  String extension(String path);
  String rootPrefix(String path);

  /// Normalized comparison key. Lowercases on case-insensitive platforms.
  String key(String path);

  bool same(String first, String second);
  bool isWithin(String root, String candidate);
  bool isReservedComponent(String component);
}

abstract final class PathSemanticsFactory {
  static PathSemantics forCurrentPlatform() {
    return Platform.isWindows
        ? const WindowsPathSemantics()
        : const PosixPathSemantics();
  }
}

class WindowsPathSemantics implements PathSemantics {
  const WindowsPathSemantics();

  @override
  String get separator => p.windows.separator;

  @override
  bool get caseSensitive => false;

  @override
  bool get supportsExtendedLengthPaths => true;

  @override
  String canonical(String path) => WindowsPath.canonical(path);

  @override
  String forIo(String path) => WindowsPath.forIo(path);

  @override
  String ensureLongPath(String path) => WindowsPath.extended(path);

  @override
  String normalize(String path) => p.windows.normalize(path);

  @override
  String absolute(String path) => p.windows.absolute(path);

  @override
  bool isAbsolute(String path) => p.windows.isAbsolute(path);

  @override
  String join(String parent, String child) => p.windows.join(parent, child);

  @override
  String dirname(String path) => p.windows.dirname(path);

  @override
  String basename(String path) => p.windows.basename(path);

  @override
  String extension(String path) => p.windows.extension(path);

  @override
  String rootPrefix(String path) => p.windows.rootPrefix(path);

  @override
  String key(String path) => normalize(absolute(canonical(path))).toLowerCase();

  @override
  bool same(String first, String second) => key(first) == key(second);

  @override
  bool isWithin(String root, String candidate) =>
      isWithinKey(key(root), key(candidate), separator);

  @override
  bool isReservedComponent(String component) {
    final upper = component.trim().toUpperCase();
    final stem = upper.contains('.')
        ? upper.substring(0, upper.indexOf('.'))
        : upper;
    return _windowsReservedNames.contains(stem);
  }
}

class PosixPathSemantics implements PathSemantics {
  const PosixPathSemantics();

  @override
  String get separator => p.posix.separator;

  @override
  bool get caseSensitive => true;

  @override
  bool get supportsExtendedLengthPaths => false;

  @override
  String canonical(String path) => path;

  @override
  String forIo(String path) => path;

  @override
  String ensureLongPath(String path) => path;

  @override
  String normalize(String path) => p.posix.normalize(path);

  @override
  String absolute(String path) => p.posix.absolute(path);

  @override
  bool isAbsolute(String path) => p.posix.isAbsolute(path);

  @override
  String join(String parent, String child) => p.posix.join(parent, child);

  @override
  String dirname(String path) => p.posix.dirname(path);

  @override
  String basename(String path) => p.posix.basename(path);

  @override
  String extension(String path) => p.posix.extension(path);

  @override
  String rootPrefix(String path) => p.posix.rootPrefix(path);

  @override
  String key(String path) => p.posix.normalize(p.posix.absolute(path));

  @override
  bool same(String first, String second) => key(first) == key(second);

  @override
  bool isWithin(String root, String candidate) =>
      isWithinKey(key(root), key(candidate), separator);

  @override
  bool isReservedComponent(String component) => false;
}

/// Shared containment check that respects separators and sibling prefixes.
bool isWithinKey(String rootKey, String candidateKey, String separator) {
  if (candidateKey == rootKey) return true;
  final prefix = rootKey.endsWith(separator) ? rootKey : '$rootKey$separator';
  return candidateKey.startsWith(prefix);
}

final _windowsReservedNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  for (final index in ['1', '2', '3', '4', '5', '6', '7', '8', '9']) ...[
    'COM$index',
    'LPT$index',
  ],
  'COM¹',
  'COM²',
  'COM³',
  'LPT¹',
  'LPT²',
  'LPT³',
};
