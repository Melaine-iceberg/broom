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
    this.onboardingCompleted = true,
    this.diagnosticsEnabled = false,
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

  /// False only for a fresh profile without a settings file. Existing users
  /// are treated as having completed the introduction.
  final bool onboardingCompleted;

  /// Opt-in local diagnostics. Off by default; logs never include file
  /// contents and are written to a rolling file in the Broom data directory.
  final bool diagnosticsEnabled;

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
    bool? onboardingCompleted,
    bool? diagnosticsEnabled,
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
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      diagnosticsEnabled: diagnosticsEnabled ?? this.diagnosticsEnabled,
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
        other.ruleUpdateUrl == ruleUpdateUrl &&
        other.onboardingCompleted == onboardingCompleted &&
        other.diagnosticsEnabled == diagnosticsEnabled;
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
    onboardingCompleted,
    diagnosticsEnabled,
  );
}
