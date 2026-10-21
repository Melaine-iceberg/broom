import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/cleaner_rule.dart';
import '../models/leftover_models.dart';
import '../platform/installed_apps.dart';
import '../rules/leftover_catalog.dart';
import '../safety/path_exclusions.dart';
import '../safety/path_guard.dart';

const _incompleteInventoryMessage = '无法完整读取已安装应用清单，已跳过卸载残留检测。';

class LeftoverDetection {
  const LeftoverDetection({this.candidates = const [], this.error});

  final List<LeftoverCandidate> candidates;
  final String? error;
}

class LeftoverValidation {
  const LeftoverValidation({this.orphanedRuleIds = const {}, this.error});

  final Set<String> orphanedRuleIds;
  final String? error;
}

/// Detects curated application data that remains without a matching install.
class LeftoverService {
  LeftoverService({
    required this.installedApps,
    required this.guard,
    this.exclusions = const EmptyPathExclusionSource(),
    List<LeftoverCatalogEntry>? entries,
    Map<String, String>? environment,
  }) : entries = List.unmodifiable(entries ?? LeftoverCatalog.entries),
       _environment = {
         for (final entry in (environment ?? Platform.environment).entries)
           entry.key.toLowerCase(): entry.value,
       };

  final InstalledApps installedApps;
  final PathGuard guard;
  final PathExclusionSource exclusions;
  final List<LeftoverCatalogEntry> entries;
  final Map<String, String> _environment;

  Future<LeftoverDetection> detect() async {
    final inventory = await _loadInventory();
    if (!inventory.complete) {
      return LeftoverDetection(
        error: inventory.error ?? _incompleteInventoryMessage,
      );
    }

    final candidates = <LeftoverCandidate>[];
    for (final entry in entries) {
      if (_matchesInstalledName(entry, inventory)) continue;
      final paths = await _resolveDataPaths(entry);
      if (paths.isEmpty) continue;
      if (await _hasInstallMarker(entry)) continue;
      candidates.add(
        LeftoverCandidate(
          entry: entry,
          paths: List.unmodifiable(paths),
          evidence: '未找到 ${entry.appName} 的卸载记录或安装目录，但检测到本地数据。',
          evidenceEn:
              'No ${entry.appNameEn} uninstall entry or install marker was '
              'found, but local data remains.',
        ),
      );
    }
    return LeftoverDetection(candidates: List.unmodifiable(candidates));
  }

  /// Returns the subset of [ruleIds] whose applications are still absent.
  ///
  /// An incomplete inventory returns an error and no validated rules, so the
  /// caller must not clean leftover items in that case.
  Future<LeftoverValidation> revalidate(Iterable<String> ruleIds) async {
    final requested = ruleIds.toSet();
    if (requested.isEmpty) return const LeftoverValidation();

    final inventory = await _loadInventory();
    if (!inventory.complete) {
      return LeftoverValidation(
        error: inventory.error ?? _incompleteInventoryMessage,
      );
    }

    final orphaned = <String>{};
    for (final entry in entries) {
      if (!requested.contains(entry.ruleId)) continue;
      if (_matchesInstalledName(entry, inventory)) continue;
      if (await _hasInstallMarker(entry)) continue;
      orphaned.add(entry.ruleId);
    }
    return LeftoverValidation(orphanedRuleIds: Set.unmodifiable(orphaned));
  }

  Future<InstalledAppInventory> _loadInventory() async {
    try {
      return await installedApps.list();
    } catch (error) {
      return InstalledAppInventory(
        apps: const [],
        complete: false,
        error: error.toString(),
      );
    }
  }

  bool _matchesInstalledName(
    LeftoverCatalogEntry entry,
    InstalledAppInventory inventory,
  ) {
    for (final app in inventory.apps) {
      final name = app.displayName.trim().toLowerCase();
      if (name.isEmpty) continue;
      for (final prefix in entry.installDisplayNamePrefixes) {
        final normalized = prefix.trim().toLowerCase();
        if (normalized.isNotEmpty && name.startsWith(normalized)) return true;
      }
    }
    return false;
  }

  Future<bool> _hasInstallMarker(LeftoverCatalogEntry entry) async {
    for (final pattern in entry.installMarkerPatterns) {
      try {
        final exists = await _markerExists(pattern);
        if (exists != false) return true;
      } on FileSystemException {
        // An unreadable marker cannot rule out an installation.
        return true;
      }
    }
    return false;
  }

  /// Returns null when the marker uses an unavailable environment variable.
  Future<bool?> _markerExists(String pattern) async {
    final expanded = _expandEnvironment(pattern);
    if (expanded == null) return null;
    final normalized = PathGuard.normalize(expanded);

    final hasWildcard = normalized.contains('*') || normalized.contains('?');
    if (!hasWildcard) {
      final type = await FileSystemEntity.type(normalized, followLinks: false);
      return type != FileSystemEntityType.notFound;
    }

    final separator = _lastSeparator(normalized);
    if (separator <= 0 || separator == normalized.length - 1) return null;
    final parent = normalized.substring(0, separator);
    final leaf = normalized.substring(separator + 1);
    final parentType = await FileSystemEntity.type(parent, followLinks: false);
    if (parentType != FileSystemEntityType.directory &&
        parentType != FileSystemEntityType.link) {
      return false;
    }

    final matcher = _wildcardRegExp(leaf);
    await for (final entity in Directory(parent).list(followLinks: false)) {
      if (matcher.hasMatch(p.windows.basename(entity.path))) return true;
    }
    return false;
  }

  Future<List<String>> _resolveDataPaths(LeftoverCatalogEntry entry) async {
    final paths = <String>{};
    for (final pattern in entry.dataPathPatterns) {
      final expanded = _expandEnvironment(pattern);
      if (expanded == null) continue;
      final normalized = PathGuard.normalize(expanded);
      if (guard.isProtected(normalized) || exclusions.excludes(normalized)) {
        continue;
      }
      try {
        final type = await FileSystemEntity.type(
          normalized,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          paths.add(normalized);
        }
      } on FileSystemException {
        continue;
      }
    }
    final result = paths.toList()..sort();
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

  int _lastSeparator(String path) {
    final backslash = path.lastIndexOf('\\');
    final slash = path.lastIndexOf('/');
    return backslash > slash ? backslash : slash;
  }

  RegExp _wildcardRegExp(String pattern) {
    final buffer = StringBuffer('^');
    for (final character in pattern.split('')) {
      switch (character) {
        case '*':
          buffer.write('.*');
        case '?':
          buffer.write('.');
        default:
          buffer.write(RegExp.escape(character));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString(), caseSensitive: false);
  }
}

CleanerRule leftoverRuleFor(LeftoverCandidate candidate) {
  final entry = candidate.entry;
  return CleanerRule(
    id: entry.ruleId,
    title: '${entry.appName} 卸载残留',
    titleEn: '${entry.appNameEn} leftovers',
    category: '卸载残留',
    categoryEn: 'Uninstall leftovers',
    description: entry.description,
    descriptionEn: entry.descriptionEn,
    pathPatterns: List.unmodifiable(candidate.paths),
    risk: CleanRisk.review,
    note: candidate.evidence,
    noteEn: candidate.evidenceEn,
  );
}
