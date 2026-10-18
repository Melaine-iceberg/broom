enum AppThemePreference { system, light, dark }

enum AppLanguagePreference { system, zh, en }

class AppSettings {
  const AppSettings({
    this.theme = AppThemePreference.system,
    this.language = AppLanguagePreference.zh,
    this.disabledRuleIds = const <String>{},
    this.disabledCategoryIds = const <String>{},
    this.scanParallelism = 2,
    this.scanLowPriority = true,
    this.useNtfsIndex = false,
    this.scanItemLimit,
    this.ruleUpdateUrl = '',
  });

  static const defaults = AppSettings();

  final AppThemePreference theme;
  final AppLanguagePreference language;
  final Set<String> disabledRuleIds;

  /// Stable rule category keys, not localized labels. Disabled categories are
  /// skipped before scan jobs are built.
  final Set<String> disabledCategoryIds;

  /// 0 means "automatic" (one worker per available processor, capped at 4).
  final int scanParallelism;
  final bool scanLowPriority;

  /// Opt-in NTFS USN index. Requires an elevated process; the engine silently
  /// falls back to directory traversal when unavailable.
  final bool useNtfsIndex;

  /// Null means no result-count cap. A positive value is an explicit user
  /// safety limit.
  final int? scanItemLimit;
  final String ruleUpdateUrl;

  bool isRuleEnabled(String ruleId) => !disabledRuleIds.contains(ruleId);

  bool isCategoryEnabled(String categoryId) =>
      !disabledCategoryIds.contains(categoryId);

  AppSettings copyWith({
    AppThemePreference? theme,
    AppLanguagePreference? language,
    Set<String>? disabledRuleIds,
    Set<String>? disabledCategoryIds,
    int? scanParallelism,
    bool? scanLowPriority,
    bool? useNtfsIndex,
    int? scanItemLimit,
    bool clearScanItemLimit = false,
    String? ruleUpdateUrl,
  }) {
    return AppSettings(
      theme: theme ?? this.theme,
      language: language ?? this.language,
      disabledRuleIds: Set.unmodifiable(
        disabledRuleIds ?? this.disabledRuleIds,
      ),
      disabledCategoryIds: Set.unmodifiable(
        disabledCategoryIds ?? this.disabledCategoryIds,
      ),
      scanParallelism: scanParallelism ?? this.scanParallelism,
      scanLowPriority: scanLowPriority ?? this.scanLowPriority,
      useNtfsIndex: useNtfsIndex ?? this.useNtfsIndex,
      scanItemLimit: clearScanItemLimit
          ? null
          : (scanItemLimit ?? this.scanItemLimit),
      ruleUpdateUrl: ruleUpdateUrl ?? this.ruleUpdateUrl,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppSettings &&
        other.theme == theme &&
        other.language == language &&
        other.disabledRuleIds.length == disabledRuleIds.length &&
        other.disabledRuleIds.containsAll(disabledRuleIds) &&
        other.disabledCategoryIds.length == disabledCategoryIds.length &&
        other.disabledCategoryIds.containsAll(disabledCategoryIds) &&
        other.scanParallelism == scanParallelism &&
        other.scanLowPriority == scanLowPriority &&
        other.useNtfsIndex == useNtfsIndex &&
        other.scanItemLimit == scanItemLimit &&
        other.ruleUpdateUrl == ruleUpdateUrl;
  }

  @override
  int get hashCode => Object.hash(
    theme,
    language,
    Object.hashAllUnordered(disabledRuleIds),
    Object.hashAllUnordered(disabledCategoryIds),
    scanParallelism,
    scanLowPriority,
    useNtfsIndex,
    scanItemLimit,
    ruleUpdateUrl,
  );
}
