import 'dart:io';

import 'package:broom/app.dart';
import 'package:broom/core/leftover/leftover_service.dart';
import 'package:broom/core/models/app_settings.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/installed_apps.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/core/settings/settings_store.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/quarantine_fakes.dart';

const _baseRule = CleanerRule(
  id: 'test.cache',
  title: '测试缓存',
  category: '测试',
  description: '测试规则',
  pathPatterns: [],
);

const _leftoverEntry = LeftoverCatalogEntry(
  id: 'example',
  appName: 'Example',
  appNameEn: 'Example',
  description: 'Example local data.',
  descriptionEn: 'Example local data.',
  dataPathPatterns: [r'%APPDATA%\Example'],
  installMarkerPatterns: [r'%LOCALAPPDATA%\Example\app.exe'],
  installDisplayNamePrefixes: ['Example'],
);

class _TestPlatform implements CleanerPlatform {
  _TestPlatform({required this.roots});

  final Map<String, List<String>> roots;

  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => const [_baseRule];

  @override
  PathSemantics get pathSemantics => const WindowsPathSemantics();

  @override
  List<String> get protectedRoots => const [];

  @override
  String get rulesVersion => 'builtin';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async =>
      roots[rule.id] ?? const [];
}

class _EmptyInstalledApps implements InstalledApps {
  const _EmptyInstalledApps();

  @override
  Future<InstalledAppInventory> list() async =>
      const InstalledAppInventory(apps: [], complete: true);
}

class _FakeLeftoverService extends LeftoverService {
  _FakeLeftoverService({required this.candidates})
    : super(
        installedApps: const _EmptyInstalledApps(),
        guard: PathGuard(protectedRoots: const []),
        entries: const [],
        environment: const {},
      );

  final List<LeftoverCandidate> candidates;
  int detectCalls = 0;

  @override
  Future<LeftoverDetection> detect() async {
    detectCalls++;
    return LeftoverDetection(candidates: candidates);
  }
}

class _RecordingScanService extends ScanService {
  _RecordingScanService(this.items);

  final List<JunkItem> items;
  List<ScanJob>? jobs;

  @override
  Future<ScanResult> scan({
    required List<ScanJob> jobs,
    required List<String> excludedPaths,
    ScanOptions options = const ScanOptions(),
    NtfsIndex? ntfsIndex,
    void Function(ScanProgress progress)? onProgress,
    void Function(List<JunkItem> items)? onItems,
    void Function(ScanIssue issue)? onIssue,
    bool retainItems = true,
  }) async {
    this.jobs = jobs;
    if (items.isNotEmpty) onItems?.call(items);
    return ScanResult(
      items: retainItems ? items : const [],
      scannedFiles: items.length,
      directoryErrors: 0,
      truncated: false,
      cancelled: false,
    );
  }
}

class _FakeShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

  @override
  Future<String?> pickJsonFile({
    String? initialDirectory,
    String? title,
  }) async => null;

  @override
  Future<String?> saveJsonFile({
    required String suggestedName,
    String? initialDirectory,
    String? title,
  }) async => null;

  @override
  Future<DiskSpaceSnapshot> queryDiskSpace(String path) async =>
      const DiskSpaceSnapshot(freeBytes: 1 << 30, totalBytes: 1 << 32);

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 0, totalBytes: 0);

  @override
  Future<void> revealPath(String path) async {}
}

void main() {
  late Directory temp;
  late Directory cacheDir;
  late Directory leftoverDir;
  late LeftoverCandidate candidate;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_category_ui_');
    cacheDir = await Directory(p.join(temp.path, 'cache'))
        .create(recursive: true);
    leftoverDir = await Directory(p.join(temp.path, 'leftover'))
        .create(recursive: true);
    await File(p.join(cacheDir.path, 'a.tmp')).writeAsString('1234');
    await File(p.join(leftoverDir.path, 'b.dat')).writeAsString('5678');
    candidate = LeftoverCandidate(
      entry: _leftoverEntry,
      paths: [leftoverDir.path],
      evidence: 'evidence',
      evidenceEn: 'evidence',
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ({
    CleanController controller,
    _FakeLeftoverService leftover,
    _RecordingScanService scanner,
  })
  createController({
    Set<String> disabledCategories = const {},
    bool mutable = false,
    SettingsController? settings,
  }) {
    final leftover = _FakeLeftoverService(candidates: [candidate]);
    final scanner = _RecordingScanService([
      JunkItem(
        rootIndex: 0,
        path: p.join(leftoverDir.path, 'b.dat'),
        size: 4,
        modifiedMicros: DateTime(2026, 10, 21).microsecondsSinceEpoch,
      ),
    ]);
    final disabled = Set<String>.of(disabledCategories);
    final controller = CleanController(
      platform: _TestPlatform(
        roots: {
          _baseRule.id: [cacheDir.path],
          _leftoverEntry.ruleId: [leftoverDir.path],
        },
      ),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: ExclusionStore(
        filePath: p.join(temp.path, 'exclusions.json'),
      ),
      leftoverService: leftover,
      scanServiceFactory: () => scanner,
      scanSettings: () => ScanSettings(
        disabledCategoryIds: mutable ? disabled : Set.unmodifiable(disabled),
      ),
      isRuleEnabled: settings?.isRuleEnabled,
    );
    addTearDown(controller.dispose);
    return (controller: controller, leftover: leftover, scanner: scanner);
  }

  test('groups rules by category and always keeps the leftover category', () {
    const leftoverRule = CleanerRule(
      id: 'leftover.example',
      title: 'Example 卸载残留',
      category: '卸载残留',
      description: 'desc',
      pathPatterns: [],
      risk: CleanRisk.review,
    );

    final withoutLeftover = groupRuleCategories([_baseRule]);
    expect(withoutLeftover.map((group) => group.key), ['other', 'leftover']);
    expect(withoutLeftover.last.isEmpty, isTrue);
    expect(withoutLeftover.last.label, '卸载残留');

    final withLeftover = groupRuleCategories([_baseRule, leftoverRule]);
    expect(withLeftover.where((group) => group.isLeftover), hasLength(1));
    expect(withLeftover.last.ruleCount, 1);
  });

  test('a disabled leftover category skips detection and scanning', () async {
    final setup = createController(disabledCategories: {leftoverCategoryKey});

    await setup.controller.initialize();

    expect(setup.leftover.detectCalls, 0);
    expect(setup.controller.leftoverCategoryEnabled, isFalse);
    expect(setup.controller.leftoverDetectedCount, 0);
    expect(setup.controller.rules.map((rule) => rule.id), [_baseRule.id]);

    await setup.controller.scan();

    expect(setup.scanner.jobs, hasLength(1));
    expect(setup.scanner.jobs!.single.ruleId, _baseRule.id);
  });

  test(
    're-enabling the leftover category runs detection immediately',
    () async {
      final setup = createController(mutable: true);
      await setup.controller.initialize();
      expect(setup.leftover.detectCalls, 1);
      expect(setup.controller.leftoverDetectedCount, 1);

      // Simulate the settings controller disabling the category.
      setup.controller.scanSettings = () =>
          const ScanSettings(disabledCategoryIds: {leftoverCategoryKey});
      await setup.controller.refreshLeftoverRules();
      expect(setup.controller.leftoverDetectedCount, 0);
      expect(setup.controller.rules.map((rule) => rule.id), [_baseRule.id]);

      setup.controller.scanSettings = () => const ScanSettings();
      await setup.controller.refreshLeftoverRules();
      expect(setup.controller.leftoverDetectedCount, 1);
      expect(
        setup.controller.rules.map((rule) => rule.id),
        contains(_leftoverEntry.ruleId),
      );
    },
  );

  testWidgets('settings exposes and persists the leftover category toggle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = SettingsStore(filePath: p.join(temp.path, 'settings.json'));
    await store.save(AppSettings.defaults);
    final settings = SettingsController(store: store);
    settings.load();
    addTearDown(settings.dispose);
    final setup = createController();
    setup.controller.scanSettings = () => settings.scanSettings;
    await setup.controller.initialize();
    expect(setup.controller.leftoverDetectedCount, 1);

    await tester.pumpWidget(
      BroomApp(
        controller: setup.controller,
        settingsController: settings,
        systemShell: _FakeShell(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey('settings-category-leftover'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(tile, findsOneWidget);
    expect(find.text('1 个残留应用'), findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(store.load().disabledCategoryIds, contains(leftoverCategoryKey));
    expect(find.text('本次跳过'), findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(store.load().disabledCategoryIds, isEmpty);
    expect(setup.controller.leftoverDetectedCount, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('scan scope lists the leftover category with its count', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = SettingsStore(filePath: p.join(temp.path, 'settings.json'));
    await store.save(AppSettings.defaults);
    final settings = SettingsController(store: store);
    settings.load();
    addTearDown(settings.dispose);
    final setup = createController();
    await setup.controller.initialize();

    await tester.pumpWidget(
      BroomApp(
        controller: setup.controller,
        settingsController: settings,
        systemShell: _FakeShell(),
      ),
    );
    await tester.pumpAndSettle();

    final hero = find.byKey(const ValueKey('scan-hero'));
    expect(
      find.descendant(of: hero, matching: find.text('卸载残留')),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const ValueKey('scope-toggle')));
    await tester.tap(find.byKey(const ValueKey('scope-toggle')));
    await tester.pumpAndSettle();

    final checkbox = find.byKey(const ValueKey('scan-category-leftover'));
    await tester.ensureVisible(checkbox);
    expect(checkbox, findsOneWidget);
    expect(find.text('1 个残留应用'), findsOneWidget);

    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    expect(store.load().disabledCategoryIds, contains(leftoverCategoryKey));
    expect(setup.controller.leftoverDetectedCount, 0);

    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    expect(store.load().disabledCategoryIds, isEmpty);
    expect(setup.controller.leftoverDetectedCount, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
