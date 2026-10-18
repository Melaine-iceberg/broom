import 'dart:io';

import 'package:path/path.dart' as p;

/// Converts between the Win32 path forms used on disk and the canonical form
/// stored in Broom's own records.
///
/// Directory enumeration does not accept paths longer than MAX_PATH even when
/// the process is long-path aware; those calls need the extended-length
/// `\\?\` / `\\?\UNC\` namespace. Records and UI keep the canonical form so
/// path guards and stored sessions stay readable and comparable.
abstract final class WindowsPath {
  static const _extendedPrefix = '\\\\?\\';
  static const _uncExtendedPrefix = '\\\\?\\UNC\\';

  // MAX_PATH is 260. Keep a margin for the `\*` mask appended by directory
  // enumeration and for calls that append a component internally.
  static const _extendedThreshold = 240;

  static bool isExtended(String path) => path.startsWith(_extendedPrefix);

  /// Strips the extended-length prefix. Other paths are returned unchanged.
  static String canonical(String path) {
    if (path.toLowerCase().startsWith(_uncExtendedPrefix.toLowerCase())) {
      return '\\\\${path.substring(_uncExtendedPrefix.length)}';
    }
    if (path.startsWith(_extendedPrefix)) {
      return path.substring(_extendedPrefix.length);
    }
    return path;
  }

  /// Returns a path that Windows file APIs can use. Long absolute paths get
  /// the extended-length prefix; short paths are left untouched.
  static String forIo(String path) {
    if (!Platform.isWindows) return path;
    if (path.startsWith(_extendedPrefix)) return path;
    if (path.length < _extendedThreshold) return path;
    return extended(path);
  }

  /// Always returns an extended-length absolute path on Windows. Exposed for
  /// native calls and tests that need the prefix regardless of length.
  static String extended(String path) {
    if (!Platform.isWindows) return path;
    if (path.startsWith(_extendedPrefix)) return path;
    final canonicalPath = canonical(path);
    final normalized = p.windows.normalize(canonicalPath);
    if (!p.windows.isAbsolute(normalized)) return path;
    if (normalized.startsWith('\\\\')) {
      return '$_uncExtendedPrefix${normalized.substring(2)}';
    }
    return '$_extendedPrefix$normalized';
  }
}
