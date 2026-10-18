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
