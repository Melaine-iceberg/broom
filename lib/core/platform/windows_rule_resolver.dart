import 'dart:io';

import '../models/cleaner_rule.dart';
import 'path_semantics.dart';

class WindowsRuleResolver {
  WindowsRuleResolver({
    Map<String, String>? environment,
    this.maxWildcardMatches = 512,
    this.semantics = const WindowsPathSemantics(),
  }) : _environment = {
         for (final entry in (environment ?? Platform.environment).entries)
           entry.key.toLowerCase(): entry.value,
       };

  final Map<String, String> _environment;
  final int maxWildcardMatches;
  final PathSemantics semantics;

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
