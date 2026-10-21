import 'dart:convert';
import 'dart:io';

import 'package:broom/app.dart';
import 'package:broom/core/clean/quarantine_retention_service.dart';
import 'package:broom/core/diagnostics/app_logger.dart';
import 'package:broom/core/models/app_settings.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/quarantine_policy_models.dart';
import 'package:broom/core/platform/app_version.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/rules/rule_catalog_store.dart';
import 'package:broom/core/rules/rule_update_service.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/settings/config_bundle.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/core/settings/quarantine_policy_store.dart';
import 'package:broom/core/settings/settings_store.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/app_update_controller.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/rule_update_controller.dart';
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
  String get rulesVersion => 'builtin';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

class _FakeSystemShell implements SystemShell {
  String? importPath;
  String? exportPath;
  String? lastSuggestedName;

  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

  @override
  Future<String?> pickJsonFile({
    String? initialDirectory,
    String? title,
  }) async => importPath;

  @override
  Future<String?> saveJsonFile({
    required String suggestedName,
    String? initialDirectory,
    String? title,
  }) async {
    lastSuggestedName = suggestedName;
    return exportPath;
  }

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

  Future<QuarantineRetentionService> createRetention() async {
    final retention = QuarantineRetentionService(
      quarantine: FakeQuarantineService(),
      store: QuarantinePolicyStore(
        filePath: p.windows.join(temp.path, 'quarantine_policy.json'),
      ),
    );
    await retention.ensureInitialized();
    return retention;
  }

  Future<(SettingsController, CleanController)> pumpApp(
    WidgetTester tester, {
    RuleUpdateController? ruleUpdates,
    AppUpdateController? appUpdates,
    _FakeSystemShell? shell,
    QuarantineRetentionService? retention,
    AppLogger? logger,
  }) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // These scenarios exercise a returning profile, not the first-run guide.
    await settingsStore.save(AppSettings.defaults);
    final settings = SettingsController(store: settingsStore, logger: logger);
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
        systemShell: shell ?? _FakeSystemShell(),
        quarantineRetention: retention,
        ruleUpdates: ruleUpdates,
        appUpdates: appUpdates,
        logger: logger,
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

    expect(find.text('设置'), findsWidgets);
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

    expect(find.text('Settings'), findsWidgets);
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
    expect(find.text('Tools'), findsWidgets);
    expect(find.text('Duplicate files'), findsWidgets);
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

  testWidgets('toggles scan categories and low priority', (tester) async {
    await pumpApp(tester);

    await tester.ensureVisible(find.text('扫描引擎'));
    expect(find.text('扫描引擎'), findsOneWidget);
    expect(find.text('并行扫描线程'), findsOneWidget);

    final category = find.byKey(const ValueKey('settings-category-other'));
    await tester.ensureVisible(category);
    await tester.tap(category);
    await tester.pumpAndSettle();
    expect(settingsStore.load().disabledCategoryIds, contains('other'));

    final lowPriority = find.byKey(const ValueKey('settings-low-priority'));
    await tester.ensureVisible(lowPriority);
    await tester.tap(lowPriority);
    await tester.pumpAndSettle();
    expect(settingsStore.load().scanLowPriority, isFalse);
  });

  testWidgets('shows the software update section and reports a newer version', (
    tester,
  ) async {
    final appUpdates = AppUpdateController(
      versionSource: const StaticAppVersion('0.4.0+4'),
      fetcher: (uri) async => '<AppInstaller Version="0.5.0.0" />',
    );
    addTearDown(appUpdates.dispose);
    await appUpdates.loadVersion();

    await pumpApp(tester, appUpdates: appUpdates);

    await tester.ensureVisible(find.text('软件更新'));
    expect(find.text('软件更新'), findsOneWidget);
    expect(find.text('当前版本：0.4.0.4'), findsOneWidget);

    final checkButton = find.byKey(const ValueKey('settings-check-app-update'));
    await tester.ensureVisible(checkButton);
    await tester.tap(checkButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('0.5.0.0'), findsWidgets);
    expect(find.text('当前已是最新版本。'), findsNothing);
  });

  testWidgets('shows rule update status for a build without a key', (
    tester,
  ) async {
    final store = RuleCatalogStore(
      directoryPath: p.windows.join(temp.path, 'rules'),
      builtinRules: const [_testRule],
    );
    final ruleSettings = SettingsController(store: settingsStore);
    ruleSettings.load();
    addTearDown(ruleSettings.dispose);
    final ruleUpdates = RuleUpdateController(
      service: RuleUpdateService(store: store, signingKey: ''),
      settings: ruleSettings,
      onCatalogChanged: (_) {},
    );
    addTearDown(ruleUpdates.dispose);

    await pumpApp(tester, ruleUpdates: ruleUpdates);

    await tester.ensureVisible(find.text('规则更新'));
    expect(find.text('规则更新'), findsOneWidget);
    expect(find.textContaining('在线更新已禁用'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '检查更新'))
          .onPressed,
      isNull,
    );
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

  testWidgets('reopens the first-use guide from about', (tester) async {
    await pumpApp(tester);

    final guide = find.byKey(const ValueKey('settings-onboarding'));
    await tester.ensureVisible(guide);
    await tester.tap(guide);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('onboarding-dialog')), findsOneWidget);
    expect(find.text('欢迎使用 Broom'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-skip')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('onboarding-dialog')), findsNothing);
    expect(find.text('设置'), findsWidgets);
  });

  testWidgets('exports configuration without quarantine data', (tester) async {
    final shell = _FakeSystemShell();
    final exportPath = p.windows.join(temp.path, 'exported-config.json');
    shell.exportPath = exportPath;
    final retention = await createRetention();
    final (settings, controller) = await pumpApp(
      tester,
      shell: shell,
      retention: retention,
    );

    await settings.setTheme(AppThemePreference.dark);
    await controller.replaceExclusions([r'C:\Temp\Keep']);
    await retention.replacePolicy(
      const QuarantineRetentionPolicy(
        enabled: false,
        retentionDays: 45,
        maxBytes: 2 * 1024 * 1024,
      ),
    );
    await tester.pumpAndSettle();

    final export = find.byKey(const ValueKey('settings-config-export'));
    await tester.ensureVisible(export);
    await tester.tap(export);
    await tester.pumpAndSettle();

    expect(shell.lastSuggestedName, startsWith('broom-config-'));
    expect(shell.lastSuggestedName, endsWith('.json'));
    expect(File(exportPath).existsSync(), isTrue);
    final raw =
        jsonDecode(File(exportPath).readAsStringSync()) as Map<String, dynamic>;
    expect(raw['kind'], 'broom-config');
    expect(raw.keys, isNot(contains('quarantine')));
    expect((raw['settings'] as Map<String, dynamic>)['theme'], 'dark');
    expect((raw['exclusions'] as Map<String, dynamic>)['paths'], [
      r'C:\Temp\Keep',
    ]);
    expect(
      (raw['quarantinePolicy'] as Map<String, dynamic>)['retentionDays'],
      45,
    );
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('imports configuration but keeps retention off', (tester) async {
    final shell = _FakeSystemShell();
    final importPath = p.windows.join(temp.path, 'import-config.json');
    shell.importPath = importPath;
    final imported = ConfigBundle(
      settings: const AppSettings(
        theme: AppThemePreference.dark,
        language: AppLanguagePreference.en,
        disabledRuleIds: {'test.cache'},
        scanParallelism: 1,
      ),
      exclusions: const [r'C:\Temp\Imported'],
      retention: const QuarantineRetentionPolicy(
        enabled: true,
        retentionDays: 7,
        maxBytes: 1024 * 1024,
      ),
    );
    File(importPath).writeAsStringSync(ConfigBundleCodec.encode(imported));
    final retention = await createRetention();
    final (settings, controller) = await pumpApp(
      tester,
      shell: shell,
      retention: retention,
    );

    final import = find.byKey(const ValueKey('settings-config-import'));
    await tester.ensureVisible(import);
    await tester.tap(import);
    await tester.pumpAndSettle();

    expect(find.text('导入配置？'), findsOneWidget);
    expect(find.textContaining('保留策略已开启'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('settings-config-confirm-import')),
    );
    await tester.pumpAndSettle();

    expect(settings.settings.theme, AppThemePreference.dark);
    expect(settings.settings.language, AppLanguagePreference.en);
    expect(settings.settings.isRuleEnabled('test.cache'), isFalse);
    expect(settingsStore.load().theme, AppThemePreference.dark);
    expect(controller.exclusions.paths, [r'C:\Temp\Imported']);
    expect(retention.policy?.enabled, isFalse);
    expect(retention.policy?.retentionDays, 7);
    final storedPolicy = await QuarantinePolicyStore(
      filePath: p.windows.join(temp.path, 'quarantine_policy.json'),
    ).load();
    expect(storedPolicy.enabled, isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('restores defaults and clears exclusions', (tester) async {
    final retention = await createRetention();
    final (settings, controller) = await pumpApp(tester, retention: retention);

    await settings.setTheme(AppThemePreference.dark);
    await settings.setRuleEnabled('test.cache', false);
    await controller.replaceExclusions([r'C:\Temp\Keep']);
    await retention.replacePolicy(
      const QuarantineRetentionPolicy(
        enabled: false,
        retentionDays: 45,
        maxBytes: 2 * 1024 * 1024,
      ),
    );
    await tester.pumpAndSettle();

    final reset = find.byKey(const ValueKey('settings-config-reset'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(find.text('恢复默认配置？'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('settings-config-confirm-reset')),
    );
    await tester.pumpAndSettle();

    expect(settingsStore.load(), AppSettings.defaults);
    expect(controller.exclusions.paths, isEmpty);
    expect(retention.policy?.enabled, isFalse);
    expect(retention.policy?.retentionDays, 30);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('enables diagnostics and exports a JSON bundle', (tester) async {
    final shell = _FakeSystemShell();
    final exportFile = File(p.windows.join(temp.path, 'diagnostics.json'));
    shell.exportPath = exportFile.path;
    final logFs = MemoryFileSystem();
    final logger = AppLogger(
      directoryPath: p.windows.join(temp.path, 'logs'),
      fileSystem: logFs,
      clock: () => DateTime.utc(2026, 10, 19, 12),
    );
    await pumpApp(tester, shell: shell, logger: logger);

    final toggle = find.byKey(const ValueKey('settings-diagnostics-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(settingsStore.load().diagnosticsEnabled, isTrue);
    expect(logger.level, AppLogLevel.info);

    final export = find.byKey(const ValueKey('settings-diagnostics-export'));
    await tester.ensureVisible(export);
    await tester.tap(export);
    await tester.pumpAndSettle();

    expect(shell.lastSuggestedName, startsWith('broom-diagnostics-'));
    expect(shell.lastSuggestedName, endsWith('.json'));
    expect(exportFile.existsSync(), isTrue);
    final bundle =
        jsonDecode(exportFile.readAsStringSync()) as Map<String, dynamic>;
    expect(bundle['kind'], 'broom.diagnostics');
    expect(bundle['appVersion'], '0.4.0');
    expect(bundle['loggingEnabled'], isTrue);
    expect(bundle['logs'], contains('诊断日志已启用'));
    expect(find.textContaining('诊断信息已导出'), findsOneWidget);
  });
}
