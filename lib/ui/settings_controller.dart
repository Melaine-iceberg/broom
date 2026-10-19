import 'package:flutter/material.dart';

import '../core/models/app_settings.dart';
import '../core/models/scan_models.dart';
import '../core/settings/settings_store.dart';

class SettingsController extends ChangeNotifier {
  SettingsController({this.store, AppSettings initial = AppSettings.defaults})
    : _settings = initial;

  final SettingsStore? store;

  AppSettings _settings;
  String? _loadError;
  String? _saveError;
  bool _loaded = false;
  bool _disposed = false;

  AppSettings get settings => _settings;

  String? get loadError => _loadError;

  String? get saveError => _saveError;

  bool get loaded => _loaded;

  bool get onboardingCompleted => _settings.onboardingCompleted;

  ThemeMode get themeMode => switch (_settings.theme) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };

  Locale? get locale => switch (_settings.language) {
    AppLanguagePreference.system => null,
    AppLanguagePreference.zh => const Locale('zh'),
    AppLanguagePreference.en => const Locale('en'),
  };

  bool get isLanguageSystem =>
      _settings.language == AppLanguagePreference.system;

  bool isRuleEnabled(String ruleId) => _settings.isRuleEnabled(ruleId);

  bool isCategoryEnabled(String categoryId) =>
      _settings.isCategoryEnabled(categoryId);

  ScanSettings get scanSettings => ScanSettings(
    disabledCategoryIds: _settings.disabledCategoryIds,
    parallelism: _settings.scanParallelism,
    lowPriority: _settings.scanLowPriority,
    useNtfsIndex: _settings.useNtfsIndex,
    itemLimit: _settings.scanItemLimit,
  );

  void load() {
    final store = this.store;
    if (store == null) {
      _loaded = true;
      _notify();
      return;
    }
    try {
      _settings = store.load();
      _loadError = null;
    } on SettingsException catch (error) {
      _settings = AppSettings.defaults;
      _loadError = error.message;
    }
    _loaded = true;
    _notify();
  }

  Future<String?> setTheme(AppThemePreference theme) {
    if (_settings.theme == theme) return Future.value();
    return _persist(_settings.copyWith(theme: theme));
  }

  Future<String?> setLanguage(AppLanguagePreference language) {
    if (_settings.language == language) return Future.value();
    return _persist(_settings.copyWith(language: language));
  }

  Future<String?> setRuleEnabled(String ruleId, bool enabled) {
    final disabled = Set<String>.of(_settings.disabledRuleIds);
    if (enabled) {
      disabled.remove(ruleId);
    } else {
      disabled.add(ruleId);
    }
    if (disabled.length == _settings.disabledRuleIds.length &&
        disabled.containsAll(_settings.disabledRuleIds)) {
      return Future.value();
    }
    return _persist(_settings.copyWith(disabledRuleIds: disabled));
  }

  Future<String?> resetRuleToggles() {
    if (_settings.disabledRuleIds.isEmpty) return Future.value();
    return _persist(_settings.copyWith(disabledRuleIds: const <String>{}));
  }

  Future<String?> setCategoryEnabled(String categoryId, bool enabled) {
    final disabled = Set<String>.of(_settings.disabledCategoryIds);
    if (enabled) {
      disabled.remove(categoryId);
    } else {
      disabled.add(categoryId);
    }
    if (disabled.length == _settings.disabledCategoryIds.length &&
        disabled.containsAll(_settings.disabledCategoryIds)) {
      return Future.value();
    }
    return _persist(_settings.copyWith(disabledCategoryIds: disabled));
  }

  Future<String?> resetCategoryToggles() {
    if (_settings.disabledCategoryIds.isEmpty) return Future.value();
    return _persist(_settings.copyWith(disabledCategoryIds: const <String>{}));
  }

  Future<String?> setScanParallelism(int value) {
    if (value < 0 || value > 16) return Future.value('扫描线程数无效');
    if (_settings.scanParallelism == value) return Future.value();
    return _persist(_settings.copyWith(scanParallelism: value));
  }

  Future<String?> setScanLowPriority(bool enabled) {
    if (_settings.scanLowPriority == enabled) return Future.value();
    return _persist(_settings.copyWith(scanLowPriority: enabled));
  }

  Future<String?> setUseNtfsIndex(bool enabled) {
    if (_settings.useNtfsIndex == enabled) return Future.value();
    return _persist(_settings.copyWith(useNtfsIndex: enabled));
  }

  Future<String?> setScanItemLimit(int? limit) {
    if (limit != null && limit < 1) return Future.value('扫描结果上限必须大于 0');
    if (_settings.scanItemLimit == limit) return Future.value();
    return _persist(
      limit == null
          ? _settings.copyWith(clearScanItemLimit: true)
          : _settings.copyWith(scanItemLimit: limit),
    );
  }

  Future<String?> setRuleUpdateUrl(String url) {
    final trimmed = url.trim();
    if (_settings.ruleUpdateUrl == trimmed) return Future.value();
    return _persist(_settings.copyWith(ruleUpdateUrl: trimmed));
  }

  Future<String?> completeOnboarding() {
    if (_settings.onboardingCompleted) return Future.value();
    return _persist(_settings.copyWith(onboardingCompleted: true));
  }

  /// Restores every preference to its default while keeping the current
  /// onboarding state, so a returning user does not see the guide again.
  Future<String?> restoreDefaults() async {
    final next = AppSettings.defaults.copyWith(
      onboardingCompleted: _settings.onboardingCompleted,
    );
    return _replaceAndClearErrors(next);
  }

  /// Applies an imported configuration. The onboarding flag is kept from the
  /// current session because importing a profile is not a first launch.
  Future<String?> importSettings(AppSettings imported) {
    return _replaceAndClearErrors(
      imported.copyWith(onboardingCompleted: _settings.onboardingCompleted),
    );
  }

  Future<String?> _replaceAndClearErrors(AppSettings next) async {
    final error = await _persist(next);
    if (error != null) return error;
    _loadError = null;
    _notify();
    return null;
  }

  void clearErrors() {
    if (_loadError == null && _saveError == null) return;
    _loadError = null;
    _saveError = null;
    _notify();
  }

  Future<String?> _persist(AppSettings next) async {
    final previous = _settings;
    _settings = next;
    _saveError = null;
    _notify();
    final store = this.store;
    if (store == null) return null;
    try {
      await store.save(next);
      return null;
    } on SettingsException catch (error) {
      _settings = previous;
      _saveError = error.message;
      _notify();
      return error.message;
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
