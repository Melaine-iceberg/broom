import 'dart:io';

import 'package:broom/app.dart';
import 'package:broom/core/models/app_settings.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/core/settings/settings_store.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/quarantine_fakes.dart';

class _SettingsPlatform implements CleanerPlatform {
  _SettingsPlatform(this.rules);

  @override
  final List<CleanerRule> rules;

  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

class _FakeSystemShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

  @override
  Future<DiskSpaceSnapshot> queryDiskSpace(String path) async =>
      const DiskSpaceSnapshot(freeBytes: 1, totalBytes: 2);

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 0, totalBytes: 0);

  @override
  Future<void> revealPath(String path) async {}
}

const _testRule = CleanerRule(
  id: 'test.cache',
  title: '测试缓存',
  category: '测试',
  description: '测试规则',
  pathPatterns: [],
);

void main() {
  late Directory temp;
  late SettingsStore settingsStore;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_settings_page_');
    settingsStore = SettingsStore(
      filePath: p.windows.join(temp.path, 'settings.json'),
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<(SettingsController, CleanController)> pumpApp(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsController(store: settingsStore);
    settings.load();
    addTearDown(settings.dispose);
    final exclusions = ExclusionStore(
      filePath: p.windows.join(temp.path, 'exclusions.json'),
    );
    await exclusions.ensureLoaded();
    final controller = CleanController(
      platform: _SettingsPlatform(const [_testRule]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: exclusions,
      isRuleEnabled: settings.isRuleEnabled,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      BroomApp(
        controller: controller,
        settingsController: settings,
        systemShell: _FakeSystemShell(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    return (settings, controller);
  }

  testWidgets('opens settings and applies theme changes immediately', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('清理规则'), findsOneWidget);

    await tester.ensureVisible(find.text('深色'));
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(settingsStore.load().theme, AppThemePreference.dark);
  });

  testWidgets('switches to English and persists the language', (tester) async {
    await pumpApp(tester);

    await tester.ensureVisible(find.text('English'));
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Cleaning rules'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(settingsStore.load().language, AppLanguagePreference.en);
  });

  testWidgets('renders the home page in English after switching language', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.ensureVisible(find.text('English'));
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Scan now'), findsOneWidget);
    expect(find.text('Analyze & review'), findsOneWidget);
    expect(find.text('Duplicate files'), findsOneWidget);
    expect(find.text('开始扫描'), findsNothing);
  });

  testWidgets('disables rules and persists the toggle', (tester) async {
    await pumpApp(tester);

    final toggle = find.byKey(const ValueKey('settings-rule-test.cache'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(settingsStore.load().isRuleEnabled('test.cache'), isFalse);
    expect(find.text('已关闭 1 条规则'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-rules-reset')));
    await tester.pumpAndSettle();

    expect(settingsStore.load().isRuleEnabled('test.cache'), isTrue);
  });

  testWidgets('opens the exclusions manager from settings', (tester) async {
    await pumpApp(tester);

    final tile = find.byKey(const ValueKey('settings-exclusions'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('排除列表'), findsWidgets);
    expect(find.text('尚未添加排除项'), findsOneWidget);
  });
}
