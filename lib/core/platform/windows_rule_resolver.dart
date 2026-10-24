import 'dart:convert';
import 'dart:io';

import '../models/cleaner_rule.dart';
import 'path_semantics.dart';

/// Resolves declarative rule patterns into existing cache directories.
///
/// Windows patterns use `%VAR%` placeholders. POSIX patterns additionally use
/// `$VAR`, `${VAR}` and a leading `~`. Wildcard expansion and containment use
/// the injected [PathSemantics], so the same resolver works on both platforms.
class RuleResolver {
  RuleResolver({
    Map<String, String>? environment,
    this.maxWildcardMatches = 512,
    this.semantics = const WindowsPathSemantics(),
    this.expandPosixVariables = false,
  }) : _environment = {
         for (final entry in (environment ?? Platform.environment).entries)
           entry.key.toLowerCase(): entry.value,
       };

  final Map<String, String> _environment;
  final int maxWildcardMatches;
  final PathSemantics semantics;
  final bool expandPosixVariables;

  Future<List<String>> resolve(CleanerRule rule) async {
    final roots = <String>{};
    for (final pattern in rule.pathPatterns) {
      final expanded = _expandEnvironment(pattern);
      if (expanded == null) continue;
      for (final root in await _expandWildcards(expanded)) {
        if (await FileSystemEntity.type(
              semantics.forIo(root),
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
          continue;
        }
        roots.add(semantics.normalize(semantics.absolute(root)));
      }
    }
    final result = roots.toList()..sort();
    if (!rule.keepActiveExtensionVersions) return result;
    return _resolveStaleExtensionVersions(result);
  }

  /// Resolves Chromium extension version directories that the profile's
  /// `Preferences` no longer references.
  ///
  /// The active version is read from `extensions.settings.<id>.path`. When the
  /// file is missing, unreadable, or does not name an existing version
  /// directory, that extension is skipped rather than guessed.
  Future<List<String>> _resolveStaleExtensionVersions(
    List<String> profiles,
  ) async {
    final roots = <String>{};
    for (final profile in profiles) {
      final preferences = File(
        semantics.forIo(semantics.join(profile, 'Preferences')),
      );
      if (!await preferences.exists()) continue;

      Object? decoded;
      try {
        decoded = jsonDecode(await preferences.readAsString());
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final extensions = decoded['extensions'];
      if (extensions is! Map) continue;
      final settings = extensions['settings'];
      if (settings is! Map) continue;

      for (final entry in settings.entries) {
        final id = entry.key;
        if (id is! String || !_extensionIdPattern.hasMatch(id)) continue;
        final value = entry.value;
        if (value is! Map) continue;
        final activeVersion = value['path'];
        if (activeVersion is! String || !_isSafeVersionSegment(activeVersion)) {
          continue;
        }

        final extensionRoot = semantics.join(
          semantics.join(profile, 'Extensions'),
          id,
        );
        final activePath = semantics.join(extensionRoot, activeVersion);
        if (await FileSystemEntity.type(
              semantics.forIo(activePath),
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
          continue;
        }

        try {
          await for (final entity in Directory(
            semantics.forIo(extensionRoot),
          ).list(followLinks: false)) {
            if (entity is! Directory) continue;
            final name = semantics.basename(semantics.canonical(entity.path));
            if (!_versionDirectoryPattern.hasMatch(name)) continue;
            if (name == activeVersion) continue;
            roots.add(semantics.normalize(semantics.absolute(entity.path)));
          }
        } on FileSystemException {
          continue;
        }
      }
    }
    final result = roots.toList()..sort();
    return result;
  }

  static final _extensionIdPattern = RegExp(r'^[a-p]{32}$');
  static final _versionDirectoryPattern = RegExp(r'^\d+(\.\d+)*(_\d+)?$');

  static bool _isSafeVersionSegment(String value) {
    if (value.isEmpty || value == '.' || value == '..') return false;
    if (value.contains('/') || value.contains('\\')) return false;
    return RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]*$').hasMatch(value);
  }

  String? _expandEnvironment(String pattern) {
    if (!expandPosixVariables) return _expandPercentVariables(pattern);

    var expanded = pattern;
    final home = _environment['home'];
    if (expanded == '~') {
      if (home == null || home.isEmpty) return null;
      expanded = home;
    } else if (expanded.startsWith('~/')) {
      if (home == null || home.isEmpty) return null;
      expanded = '$home/${expanded.substring(2)}';
    }

    var missing = false;
    expanded = expanded.replaceAllMapped(RegExp(r'\$\{([^}]+)\}'), (match) {
      final value = _environment[match.group(1)!.toLowerCase()];
      if (value == null || value.isEmpty) {
        missing = true;
        return '';
      }
      return value;
    });
    expanded = expanded.replaceAllMapped(
      RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)'),
      (match) {
        final value = _environment[match.group(1)!.toLowerCase()];
        if (value == null || value.isEmpty) {
          missing = true;
          return '';
        }
        return value;
      },
    );
    return missing ? null : expanded;
  }

  String? _expandPercentVariables(String pattern) {
    var missing = false;
    final expanded = pattern.replaceAllMapped(RegExp(r'%([^%]+)%'), (match) {
      final value = _environment[match.group(1)!.toLowerCase()];
      if (value == null || value.isEmpty) {
        missing = true;
        return '';
      }
      return value;
    });
    return missing ? null : expanded;
  }

  Future<List<String>> _expandWildcards(String pattern) async {
    final normalized = semantics.normalize(semantics.canonical(pattern));
    final rootPrefix = semantics.rootPrefix(normalized);
    if (rootPrefix.isEmpty) return const [];

    final segments = normalized
        .substring(rootPrefix.length)
        .split(semantics.separator)
        .where((segment) => segment.isNotEmpty);

    var current = <String>[rootPrefix];
    for (final segment in segments) {
      final next = <String>[];
      if (segment.contains('*') || segment.contains('?')) {
        final matcher = _wildcardRegExp(segment);
        for (final base in current) {
          try {
            await for (final entity in Directory(
              semantics.forIo(base),
            ).list(followLinks: false)) {
              if (entity is! Directory) continue;
              if (!matcher.hasMatch(
                semantics.basename(semantics.canonical(entity.path)),
              )) {
                continue;
              }
              next.add(semantics.canonical(entity.path));
              if (next.length >= maxWildcardMatches) break;
            }
          } on FileSystemException {
            continue;
          }
          if (next.length >= maxWildcardMatches) break;
        }
      } else {
        for (final base in current) {
          final candidate = semantics.join(base, segment);
          if (await FileSystemEntity.type(
                semantics.forIo(candidate),
                followLinks: false,
              ) ==
              FileSystemEntityType.directory) {
            next.add(candidate);
          }
        }
      }
      current = next;
      if (current.isEmpty) break;
    }

    return current;
  }

  RegExp _wildcardRegExp(String pattern) {
    final buffer = StringBuffer('^');
    for (final char in pattern.split('')) {
      switch (char) {
        case '*':
          buffer.write('.*');
        case '?':
          buffer.write('.');
        default:
          buffer.write(RegExp.escape(char));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString(), caseSensitive: semantics.caseSensitive);
  }
}

/// Windows catalog resolver. Kept as a named entry for existing callers.
class WindowsRuleResolver extends RuleResolver {
  WindowsRuleResolver({
    super.environment,
    super.maxWildcardMatches,
    super.semantics = const WindowsPathSemantics(),
  }) : super(expandPosixVariables: false);
}

/// Resolves Linux/XDG rule patterns into existing directories.
class PosixRuleResolver extends RuleResolver {
  PosixRuleResolver({super.environment, super.maxWildcardMatches = 512})
    : super(semantics: const PosixPathSemantics(), expandPosixVariables: true);
}
