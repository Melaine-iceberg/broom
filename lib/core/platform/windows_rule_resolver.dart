import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/cleaner_rule.dart';

class WindowsRuleResolver {
  WindowsRuleResolver({
    Map<String, String>? environment,
    this.maxWildcardMatches = 512,
  }) : _environment = {
          for (final entry in (environment ?? Platform.environment).entries)
            entry.key.toLowerCase(): entry.value,
        };

  final Map<String, String> _environment;
  final int maxWildcardMatches;

  Future<List<String>> resolve(CleanerRule rule) async {
    final roots = <String>{};
    for (final pattern in rule.pathPatterns) {
      final expanded = _expandEnvironment(pattern);
      if (expanded == null) continue;
      for (final root in await _expandWildcards(expanded)) {
        if (await FileSystemEntity.type(root, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        roots.add(p.windows.normalize(p.windows.absolute(root)));
      }
    }
    final result = roots.toList()..sort();
    return result;
  }

  String? _expandEnvironment(String pattern) {
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
    final normalized = p.windows.normalize(pattern);
    final rootPrefix = p.windows.rootPrefix(normalized);
    if (rootPrefix.isEmpty) return const [];

    final segments = normalized
        .substring(rootPrefix.length)
        .split(p.windows.separator)
        .where((segment) => segment.isNotEmpty);

    var current = <String>[rootPrefix];
    for (final segment in segments) {
      final next = <String>[];
      if (segment.contains('*') || segment.contains('?')) {
        final matcher = _wildcardRegExp(segment);
        for (final base in current) {
          try {
            await for (final entity
                in Directory(base).list(followLinks: false)) {
              if (entity is! Directory) continue;
              if (!matcher.hasMatch(p.windows.basename(entity.path))) continue;
              next.add(entity.path);
              if (next.length >= maxWildcardMatches) break;
            }
          } on FileSystemException {
            continue;
          }
          if (next.length >= maxWildcardMatches) break;
        }
      } else {
        for (final base in current) {
          final candidate = p.windows.join(base, segment);
          if (await FileSystemEntity.type(candidate, followLinks: false) ==
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
    return RegExp(buffer.toString(), caseSensitive: false);
  }
}
