import 'package:flutter/material.dart';

import '../core/models/app_settings.dart';
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
