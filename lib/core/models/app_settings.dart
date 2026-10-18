enum AppThemePreference { system, light, dark }

enum AppLanguagePreference { system, zh, en }

class AppSettings {
  const AppSettings({
    this.theme = AppThemePreference.system,
    this.language = AppLanguagePreference.zh,
    this.disabledRuleIds = const <String>{},
  });

  static const defaults = AppSettings();

  final AppThemePreference theme;
  final AppLanguagePreference language;
  final Set<String> disabledRuleIds;

  bool isRuleEnabled(String ruleId) => !disabledRuleIds.contains(ruleId);

  AppSettings copyWith({
    AppThemePreference? theme,
    AppLanguagePreference? language,
    Set<String>? disabledRuleIds,
  }) {
    return AppSettings(
      theme: theme ?? this.theme,
      language: language ?? this.language,
      disabledRuleIds: Set.unmodifiable(
        disabledRuleIds ?? this.disabledRuleIds,
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppSettings &&
        other.theme == theme &&
        other.language == language &&
        other.disabledRuleIds.length == disabledRuleIds.length &&
        other.disabledRuleIds.containsAll(disabledRuleIds);
  }

  @override
  int get hashCode =>
      Object.hash(theme, language, Object.hashAllUnordered(disabledRuleIds));
}
