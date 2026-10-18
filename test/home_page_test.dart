import 'dart:io';
import 'dart:ui';

import 'package:broom/app.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/system_cache_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/quarantine_fakes.dart';
import 'support/system_cache_fakes.dart';

class _FakeSystemShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

  @override
  Future<DiskSpaceSnapshot> queryDiskSpace(String path) async =>
      const DiskSpaceSnapshot(freeBytes: 1000000, totalBytes: 2000000);

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 7, totalBytes: 7340032);

  @override
  Future<void> revealPath(String path) async {}
}

class _FakePlatform implements CleanerPlatform {
  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => windowsSafeRules;

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

class _FixedRootsPlatform implements CleanerPlatform {
  _FixedRootsPlatform({required this.rule, required this.roots});

  final CleanerRule rule;
  final List<String> roots;

  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => [rule];

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => roots;
}

ExclusionStore _exclusionsStore() => ExclusionStore(
  filePath: p.windows.join(r'C:\broom_widget_test', 'exclusions.json'),
);

void main() {
  testWidgets('renders the idle screen and handles an empty scan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guard = PathGuard(protectedRoots: const []);
    final controller = CleanController(
      platform: _FakePlatform(),
      guard: guard,
      quarantine: QuarantineService(
        quarantineRoot: p.windows.join(r'C:\broom_widget_test', 'quarantine'),
        guard: guard,
      ),
      exclusions: _exclusionsStore(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BroomApp(controller: controller));

    expect(find.text('Broom'), findsOneWidget);
    expect(find.text('Windows 安全清理'), findsOneWidget);
    expect(find.byKey(const ValueKey('window-minimize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-maximize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-close')), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
    expect(find.text('本次扫描范围'), findsOneWidget);
    expect(find.text('分析与审阅'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-recycle-bin')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-duplicate-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-large-files')), findsOneWidget);
    expect(find.text('REVIEW · 需确认'), findsOneWidget);
    expect(find.text('INFO · 只读'), findsNWidgets(2));

    await tester.tap(find.text('开始扫描'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('没有找到可扫描的缓存目录。'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('opens the recycle bin review tool', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guard = PathGuard(protectedRoots: const []);
    final controller = CleanController(
      platform: _FakePlatform(),
      guard: guard,
      quarantine: QuarantineService(
        quarantineRoot: p.windows.join(r'C:\broom_widget_test', 'quarantine'),
        guard: guard,
      ),
      exclusions: _exclusionsStore(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('tool-recycle-bin')));
    await tester.tap(find.byKey(const ValueKey('tool-recycle-bin')));
    await tester.pumpAndSettle();

    expect(find.text('回收站中有 7 个项目'), findsOneWidget);
    expect(find.text('REVIEW · 需确认'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('auto-opens and exposes the admin system cache tool', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guard = PathGuard(protectedRoots: const []);
    final controller = CleanController(
      platform: _FakePlatform(),
      guard: guard,
      quarantine: QuarantineService(
        quarantineRoot: p.windows.join(r'C:\broom_widget_test', 'quarantine'),
        guard: guard,
      ),
      exclusions: _exclusionsStore(),
    );
    addTearDown(controller.dispose);
    final systemController = SystemCacheController(
      platform: FakeSystemCachePlatform(resolver: (_) => const []),
      access: FakeSystemAccess(elevated: false),
      cleaner: FakeSystemCacheCleaner(),
      scanServiceFactory: () => FakeScanService(),
    );
    addTearDown(systemController.dispose);

    await tester.pumpWidget(
      BroomApp(
        controller: controller,
        systemCacheController: systemController,
        startInSystemCache: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('需要管理员权限'), findsOneWidget);
    expect(find.text('系统级缓存'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    final tool = find.byKey(const ValueKey('tool-system-cache'));
    expect(tool, findsOneWidget);

    await tester.ensureVisible(tool);
    await tester.tap(tool);
    await tester.pumpAndSettle();

    expect(find.text('需要管理员权限'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('opens the quarantine manager from the home card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guard = PathGuard(protectedRoots: const []);
    final controller = CleanController(
      platform: _FakePlatform(),
      guard: guard,
      quarantine: FakeQuarantineService([fakeQuarantineEntry('first.txt')]),
      exclusions: _exclusionsStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('quarantine-card'));
    expect(card, findsOneWidget);
    expect(find.textContaining('隔离区暂存了'), findsOneWidget);

    await tester.ensureVisible(card);
    await tester.tap(find.descendant(of: card, matching: find.text('管理')));
    await tester.pumpAndSettle();

    expect(find.text('隔离区'), findsOneWidget);
    expect(find.text('查看文件'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.text('Broom'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('prompts about unfinished sessions on startup', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guard = PathGuard(protectedRoots: const []);
    final service = FakeQuarantineService([
      fakeQuarantineEntry('pending.txt'),
      fakeQuarantineEntry('restored.txt', sequence: 2, restored: true),
    ]);
    final controller = CleanController(
      platform: _FakePlatform(),
      guard: guard,
      quarantine: service,
      exclusions: _exclusionsStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    expect(find.text('发现 1 个未完成的清理会话'), findsOneWidget);

    await tester.tap(find.text('查看隔离区'));
    await tester.pumpAndSettle();

    expect(find.text('隔离区'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.textContaining('其中 1 次未正常结束'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('marks rules that are partially excluded', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('broom_home_exclusions_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final root = Directory(p.windows.join(temp.path, 'cache'));
    final kept = Directory(p.windows.join(root.path, 'keep'));
    kept.createSync(recursive: true);

    final exclusions = ExclusionStore(
      filePath: p.windows.join(temp.path, 'exclusions.json'),
    );
    await exclusions.ensureLoaded();
    await exclusions.add(kept.path);

    final rule = CleanerRule(
      id: 'test.cache',
      title: '测试缓存',
      category: '测试',
      description: '测试用缓存规则',
      pathPatterns: const [],
    );
    final controller = CleanController(
      platform: _FixedRootsPlatform(rule: rule, roots: [root.path]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: exclusions,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    expect(find.text('排除列表 · 1'), findsOneWidget);
    expect(find.text('部分排除'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-exclusions')));
    await tester.pumpAndSettle();

    expect(find.text('排除项'), findsOneWidget);
    expect(find.text(kept.path), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
