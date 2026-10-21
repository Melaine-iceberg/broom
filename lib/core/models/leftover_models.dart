enum InstalledAppScope { user, machine, unknown }

/// One application registration read from the Windows uninstall keys.
class InstalledApp {
  const InstalledApp({
    required this.displayName,
    this.publisher,
    this.installLocation,
    this.uninstallKey,
    this.scope = InstalledAppScope.unknown,
  });

  final String displayName;
  final String? publisher;
  final String? installLocation;
  final String? uninstallKey;
  final InstalledAppScope scope;
}

/// Snapshot of the installed-application inventory.
///
/// Detection must fail closed when [complete] is false: a missing registry
/// view can make an installed application look orphaned.
class InstalledAppInventory {
  const InstalledAppInventory({
    required this.apps,
    required this.complete,
    this.error,
  });

  final List<InstalledApp> apps;
  final bool complete;
  final String? error;
}

/// Stable prefix for runtime rules generated from the leftover catalog.
const leftoverRuleIdPrefix = 'leftover.';

/// A curated application whose user data may remain after uninstall.
///
/// Data paths are explicit; generic directory guessing is intentionally not
/// supported. A candidate is only produced when a data path exists and every
/// install marker is absent.
class LeftoverCatalogEntry {
  const LeftoverCatalogEntry({
    required this.id,
    required this.appName,
    required this.appNameEn,
    required this.description,
    required this.descriptionEn,
    required this.dataPathPatterns,
    required this.installMarkerPatterns,
    required this.installDisplayNamePrefixes,
  });

  /// Stable id without [leftoverRuleIdPrefix].
  final String id;
  final String appName;
  final String appNameEn;
  final String description;
  final String descriptionEn;
  final List<String> dataPathPatterns;
  final List<String> installMarkerPatterns;
  final List<String> installDisplayNamePrefixes;

  String get ruleId => '$leftoverRuleIdPrefix$id';
}

/// A catalog match that passed the installed-state check.
class LeftoverCandidate {
  const LeftoverCandidate({
    required this.entry,
    required this.paths,
    required this.evidence,
    required this.evidenceEn,
  });

  final LeftoverCatalogEntry entry;
  final List<String> paths;
  final String evidence;
  final String evidenceEn;
}
