import 'dart:convert';
import 'dart:io';

import 'package:broom/core/models/app_settings.dart';
import 'package:broom/core/settings/settings_store.dart';
import 'package:broom/ui/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_settings_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  SettingsStore createStore() =>
      SettingsStore(filePath: p.windows.join(temp.path, 'settings.json'));

  test('returns defaults when no settings file exists', () {
    final settings = createStore().load();

    expect(settings.theme, AppThemePreference.system);
    expect(settings.language, AppLanguagePreference.zh);
    expect(settings.disabledRuleIds, isEmpty);
  });

  test('migrates v1 settings and writes the v2 envelope on save', () async {
    final file = File(p.windows.join(temp.path, 'settings.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'theme': 'dark',
        'language': 'en',
        'disabledRuleIds': ['dev.npm'],
      }),
    );

    final store = createStore();
    final migrated = store.load();
    expect(migrated.theme, AppThemePreference.dark);
    expect(migrated.language, AppLanguagePreference.en);
    expect(migrated.disabledRuleIds, {'dev.npm'});

    await store.save(migrated);
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(raw['kind'], 'broom.settings');
    expect(raw['schemaVersion'], 2);
  });

  test('restores defaults without restarting onboarding', () async {
    final store = createStore();
    await store.save(
      const AppSettings(
        theme: AppThemePreference.dark,
        language: AppLanguagePreference.en,
        disabledRuleIds: {'dev.npm'},
        disabledCategoryIds: {'dev'},
        scanParallelism: 8,
        scanLowPriority: false,
        useNtfsIndex: true,
        scanItemLimit: 42,
        ruleUpdateUrl: 'https://updates.example.test/manifest.json',
        onboardingCompleted: true,
      ),
    );
    final controller = SettingsController(store: store);
    addTearDown(controller.dispose);
    controller.load();

    expect(await controller.restoreDefaults(), isNull);

    final defaults = store.load();
    expect(defaults.theme, AppThemePreference.system);
    expect(defaults.language, AppLanguagePreference.zh);
    expect(defaults.disabledRuleIds, isEmpty);
    expect(defaults.disabledCategoryIds, isEmpty);
    expect(defaults.scanParallelism, 2);
    expect(defaults.scanLowPriority, isTrue);
    expect(defaults.useNtfsIndex, isFalse);
    expect(defaults.scanItemLimit, isNull);
    expect(defaults.ruleUpdateUrl, isEmpty);
    expect(defaults.onboardingCompleted, isTrue);
  });

  test('imports settings while keeping the current onboarding state', () async {
    final store = createStore();
    await store.save(const AppSettings(onboardingCompleted: false));
    final controller = SettingsController(store: store);
    addTearDown(controller.dispose);
    controller.load();

    expect(
      await controller.importSettings(
        const AppSettings(
          theme: AppThemePreference.dark,
          language: AppLanguagePreference.en,
          disabledRuleIds: {'browser.chrome'},
          scanParallelism: 0,
          onboardingCompleted: false,
        ),
      ),
      isNull,
    );

    final saved = store.load();
    expect(saved.theme, AppThemePreference.dark);
    expect(saved.language, AppLanguagePreference.en);
    expect(saved.disabledRuleIds, {'browser.chrome'});
    expect(saved.scanParallelism, 0);
    expect(saved.onboardingCompleted, isFalse);
  });

  test(
    'restore clears a previous load error after rewriting the file',
    () async {
      final file = File(p.windows.join(temp.path, 'settings.json'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{broken');
      final controller = SettingsController(store: createStore());
      addTearDown(controller.dispose);
      controller.load();
      expect(controller.loadError, isNotNull);

      expect(await controller.restoreDefaults(), isNull);

      expect(controller.loadError, isNull);
      expect(createStore().load(), AppSettings.defaults);
    },
  );

  test('round-trips theme, language and disabled rules', () async {
    final store = createStore();
    await store.save(
      const AppSettings(
        theme: AppThemePreference.dark,
        language: AppLanguagePreference.en,
        disabledRuleIds: {'dev.npm', 'browser.chrome'},
      ),
    );

    final loaded = store.load();

    expect(loaded.theme, AppThemePreference.dark);
    expect(loaded.language, AppLanguagePreference.en);
    expect(loaded.disabledRuleIds, {'dev.npm', 'browser.chrome'});
  });

  test('rejects unknown schema and invalid values', () async {
    final file = File(p.windows.join(temp.path, 'settings.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{"schemaVersion": 99}');

    expect(() => createStore().load(), throwsA(isA<SettingsException>()));

    file.writeAsStringSync(
      '{"schemaVersion": 1, "theme": "blue", "language": "zh"}',
    );

    expect(() => createStore().load(), throwsA(isA<SettingsException>()));
  });

  test('controller falls back to defaults when loading fails', () {
    final file = File(p.windows.join(temp.path, 'settings.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{broken');
    final controller = SettingsController(store: createStore());
    addTearDown(controller.dispose);

    controller.load();

    expect(controller.loadError, isNotNull);
    expect(controller.settings, AppSettings.defaults);
    expect(controller.themeMode, ThemeMode.system);
  });

  test('controller rolls back changes when saving fails', () async {
    final filePath = p.windows.join(temp.path, 'settings.json');
    Directory(filePath).createSync(recursive: true);
    final controller = SettingsController(
      store: SettingsStore(filePath: filePath),
    );
    addTearDown(controller.dispose);
    controller.load();

    final error = await controller.setTheme(AppThemePreference.dark);

    expect(error, isNotNull);
    expect(controller.settings.theme, AppThemePreference.system);
    expect(controller.saveError, isNotNull);
  });

  test('round-trips scan engine settings and categories', () async {
    final store = createStore();
    await store.save(
      const AppSettings(
        disabledCategoryIds: {'browser', 'logs'},
        scanParallelism: 4,
        scanLowPriority: false,
        useNtfsIndex: true,
        scanItemLimit: 250000,
        ruleUpdateUrl: 'https://updates.example.test/manifest.json',
      ),
    );

    final loaded = store.load();
    expect(loaded.disabledCategoryIds, {'browser', 'logs'});
    expect(loaded.isCategoryEnabled('dev'), isTrue);
    expect(loaded.scanParallelism, 4);
    expect(loaded.scanLowPriority, isFalse);
    expect(loaded.useNtfsIndex, isTrue);
    expect(loaded.scanItemLimit, 250000);
    expect(loaded.ruleUpdateUrl, isNotEmpty);
  });

  test('settings default to unlimited results and low-priority scans', () {
    final settings = createStore().load();
    expect(settings.scanItemLimit, isNull);
    expect(settings.scanLowPriority, isTrue);
    expect(settings.useNtfsIndex, isFalse);
    expect(settings.disabledCategoryIds, isEmpty);
    expect(settings.ruleUpdateUrl, isEmpty);
  });

  test('controller updates scan settings and category filters', () async {
    final store = createStore();
    final controller = SettingsController(store: store);
    addTearDown(controller.dispose);
    controller.load();

    expect(await controller.setCategoryEnabled('browser', false), isNull);
    expect(await controller.setScanParallelism(0), isNull);
    expect(await controller.setScanLowPriority(false), isNull);
    expect(await controller.setUseNtfsIndex(true), isNull);
    expect(await controller.setScanItemLimit(1234), isNull);
    expect(await controller.setRuleUpdateUrl('https://example.test/x'), isNull);

    final saved = store.load();
    expect(saved.isCategoryEnabled('browser'), isFalse);
    expect(saved.scanParallelism, 0);
    expect(saved.scanLowPriority, isFalse);
    expect(saved.useNtfsIndex, isTrue);
    expect(saved.scanItemLimit, 1234);
    expect(saved.ruleUpdateUrl, 'https://example.test/x');
    expect(controller.scanSettings.itemLimit, 1234);
    expect(controller.scanSettings.disabledCategoryIds, {'browser'});

    expect(await controller.setScanItemLimit(null), isNull);
    expect(store.load().scanItemLimit, isNull);
    expect(await controller.resetCategoryToggles(), isNull);
    expect(store.load().disabledCategoryIds, isEmpty);
  });

  test('controller persists changes', () async {
    final store = createStore();
    final controller = SettingsController(store: store);
    addTearDown(controller.dispose);
    controller.load();

    expect(await controller.setTheme(AppThemePreference.dark), isNull);
    expect(await controller.setLanguage(AppLanguagePreference.en), isNull);
    expect(await controller.setRuleEnabled('dev.npm', false), isNull);

    final saved = store.load();
    expect(saved.theme, AppThemePreference.dark);
    expect(saved.language, AppLanguagePreference.en);
    expect(saved.isRuleEnabled('dev.npm'), isFalse);

    expect(await controller.resetRuleToggles(), isNull);
    expect(store.load().disabledRuleIds, isEmpty);
  });
}
