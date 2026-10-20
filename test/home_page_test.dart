import 'dart:async';
import 'dart:io';

import 'package:broom/app.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/core/settings/settings_store.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/settings_controller.dart';
import 'package:broom/ui/system_cache_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/file_metadata_fakes.dart';
import 'support/quarantine_fakes.dart';
import 'support/system_cache_fakes.dart';

class _FakeSystemShell implements SystemShell {
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
  String get rulesVersion => 'builtin';

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
  String get rulesVersion => 'builtin';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => roots;
}

class _FixedScanService extends ScanService {
  _FixedScanService(this.items);

  final List<JunkItem> items;

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

class _ReportingQuarantineService extends FakeQuarantineService {
  _ReportingQuarantineService(this.report);

  final CleanReport report;

  @override
  Future<CleanReport> clean(
    List<JunkItem> items, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async => report;
}

class _ProgressQuarantineService extends FakeQuarantineService {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<QuarantineSessionInfo>> listSessions() async {
    return [
      QuarantineSessionInfo(
        id: FakeQuarantineService.sessionId,
        createdAt: DateTime(2026, 10, 18, 12),
        status: QuarantineStatus.ready,
        entryCount: 2,
        totalBytes: 64,
        pendingCount: 2,
        pendingBytes: 64,
        plannedCount: 2,
      ),
    ];
  }

  @override
  Future<CleanReport> clean(
    List<JunkItem> items, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    onProgress?.call(
      CleanProgress(
        moved: 1,
        processed: 1,
        total: items.length,
        movedBytes: items.first.size,
        currentPath: items.first.path,
      ),
    );
    if (!started.isCompleted) started.complete();
    await release.future;
    return CleanReport(
      sessionId: FakeQuarantineService.sessionId,
      movedCount: items.length,
      movedBytes: items.fold(0, (total, item) => total + item.size),
      failureCount: 0,
      failures: const [],
      cancelled: false,
    );
  }

  @override
  Future<UndoReport> undo(
    String sessionId, {
    Set<String>? storedNames,
    UndoConflictPolicy conflictPolicy = UndoConflictPolicy.skip,
    Map<String, UndoConflictPolicy> conflictPolicies = const {},
  }) async {
    return const UndoReport(
      restoredCount: 2,
      restoredBytes: 64,
      conflictCount: 0,
      keptBothCount: 0,
      overwrittenCount: 0,
      missingCount: 0,
      failureCount: 0,
      integrityFailureCount: 0,
      failures: [],
      sessionRemoved: true,
    );
  }
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
        metadataAccess: FakeFileMetadataAccess(),
      ),
      exclusions: _exclusionsStore(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BroomApp(controller: controller));

    expect(find.text('Broom'), findsOneWidget);
    expect(find.byKey(const ValueKey('window-minimize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-maximize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-close')), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
    expect(find.text('扫描范围'), findsWidgets);
    expect(find.text('工具'), findsWidgets);
    expect(find.byKey(const ValueKey('tool-recycle-bin')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-duplicate-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-large-files')), findsOneWidget);
    expect(find.text('按文件内容查找重复项'), findsOneWidget);

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
        metadataAccess: FakeFileMetadataAccess(),
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
    expect(find.text('需确认'), findsWidgets);
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
        metadataAccess: FakeFileMetadataAccess(),
      ),
      exclusions: _exclusionsStore(),
    );
    addTearDown(controller.dispose);
    final systemController = SystemCacheController(
      platform: FakeSystemCachePlatform(resolver: (_) => const []),
      access: FakeSystemAccess(elevated: false),
      cleaner: FakeSystemCacheCleaner(),
      scanServiceFactory: FakeScanService.new,
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
    expect(
      find.descendant(of: card, matching: find.text('管理')),
      findsOneWidget,
    );

    await tester.ensureVisible(card);
    await tester.tap(find.descendant(of: card, matching: find.text('管理')));
    await tester.pumpAndSettle();

    expect(find.text('隔离区'), findsWidgets);
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

    expect(find.text('隔离区'), findsWidgets);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 次清理未正常结束'), findsOneWidget);
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

    await tester.tap(find.byKey(const ValueKey('scope-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('部分排除'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-exclusions')));
    await tester.pumpAndSettle();

    expect(find.text('排除项'), findsOneWidget);
    expect(find.text(kept.path), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('reports skipped files separately from failures', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const root = r'C:\broom_widget_test\cache';
    final item = JunkItem(
      ruleId: 'test.cache',
      rootPath: root,
      path: p.windows.join(root, 'locked.tmp'),
      size: 42,
      modified: DateTime(2026, 10, 18),
    );
    const rule = CleanerRule(
      id: 'test.cache',
      title: '测试缓存',
      category: '测试',
      description: '测试用缓存规则',
      pathPatterns: [],
    );
    final controller = CleanController(
      platform: _FixedRootsPlatform(rule: rule, roots: [root]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: _ReportingQuarantineService(
        CleanReport(
          sessionId: null,
          movedCount: 0,
          movedBytes: 0,
          skippedCount: 1,
          skips: [CleanFailure(path: item.path, reason: '文件正被其他程序占用')],
          failureCount: 1,
          failures: [CleanFailure(path: item.path, reason: '没有访问权限')],
          cancelled: false,
        ),
      ),
      exclusions: _exclusionsStore(),
      scanServiceFactory: () => _FixedScanService([item]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    expect(controller.phase, CleanPhase.preview);
    await controller.cleanSelected();
    await tester.pumpAndSettle();

    expect(controller.phase, CleanPhase.done);
    expect(find.textContaining('没有文件移入隔离区'), findsOneWidget);
    expect(find.text('1 个文件已跳过'), findsOneWidget);
    expect(find.textContaining('这些文件可能正被其他程序占用'), findsOneWidget);
    expect(find.textContaining('文件正被其他程序占用'), findsOneWidget);
    expect(find.text('1 个文件清理失败。'), findsOneWidget);
    expect(find.textContaining('没有访问权限'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('keeps review rules unselected and requires extra confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const root = r'C:\broom_widget_test\review-cache';
    final item = JunkItem(
      ruleId: 'test.review',
      rootPath: root,
      path: p.windows.join(root, 'offline-cache.bin'),
      size: 128,
      modified: DateTime(2026, 10, 18),
    );
    const rule = CleanerRule(
      id: 'test.review',
      title: '测试 Review 缓存',
      category: '测试',
      description: '需要额外确认的测试规则',
      risk: CleanRisk.review,
      pathPatterns: [],
    );
    final controller = CleanController(
      platform: _FixedRootsPlatform(rule: rule, roots: [root]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: _exclusionsStore(),
      scanServiceFactory: () => _FixedScanService([item]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    expect(controller.phase, CleanPhase.preview);
    expect(controller.selectedCount, 0);
    expect(find.textContaining('扫描结果包含 1 条需确认规则'), findsOneWidget);
    expect(find.text('需确认'), findsWidgets);

    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(controller.selectedCount, 1);

    await tester.tap(find.widgetWithText(FilledButton, '清理 1 项'));
    await tester.pumpAndSettle();

    expect(find.text('移入隔离区？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('acknowledge-review-clean')),
      findsOneWidget,
    );
    final confirm = find.widgetWithText(FilledButton, '暂存 1 项');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('acknowledge-review-clean')));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('reports removed empty cache directories', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const root = r'C:\broom_widget_test\cache';
    final item = JunkItem(
      ruleId: 'test.cache',
      rootPath: root,
      path: p.windows.join(root, 'nested', 'cache.tmp'),
      size: 42,
      modified: DateTime(2026, 10, 18),
    );
    const rule = CleanerRule(
      id: 'test.cache',
      title: '测试缓存',
      category: '测试',
      description: '测试用缓存规则',
      pathPatterns: [],
    );
    final controller = CleanController(
      platform: _FixedRootsPlatform(rule: rule, roots: [root]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: _ReportingQuarantineService(
        CleanReport(
          sessionId: null,
          movedCount: 1,
          movedBytes: 42,
          failureCount: 0,
          failures: const [],
          cancelled: false,
          removedDirectoryCount: 2,
        ),
      ),
      exclusions: _exclusionsStore(),
      scanServiceFactory: () => _FixedScanService([item]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();
    await controller.cleanSelected();
    await tester.pumpAndSettle();

    expect(controller.phase, CleanPhase.done);
    expect(find.text('已清理 2 个空缓存目录。'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('supports keyboard scan/back and shows a scan summary', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const root = r'C:\broom_widget_test\cache';
    final item = JunkItem(
      ruleId: 'test.cache',
      rootPath: root,
      path: p.windows.join(root, 'cache.tmp'),
      size: 4096,
      modified: DateTime(2026, 10, 18),
    );
    const rule = CleanerRule(
      id: 'test.cache',
      title: '测试缓存',
      category: '测试',
      description: '测试用缓存规则',
      pathPatterns: [],
    );
    final controller = CleanController(
      platform: _FixedRootsPlatform(rule: rule, roots: [root]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: _exclusionsStore(),
      scanServiceFactory: () => _FixedScanService([item]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('开始扫描（F5）'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();

    expect(controller.phase, CleanPhase.preview);
    expect(find.text('可清理总量'), findsOneWidget);
    expect(find.text('分类体积占比'), findsOneWidget);
    expect(find.text('已跳过 0 个无法读取的路径'), findsOneWidget);
    expect(find.textContaining('已检查 1 个文件'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('preview-search')),
      '不存在的规则',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的规则'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('preview-search')), '');
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(controller.phase, CleanPhase.idle);
    expect(find.text('开始扫描'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('shows the first-use guide and persists completion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('broom_onboarding_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final settingsStore = SettingsStore(
      filePath: p.windows.join(temp.path, 'settings.json'),
    );
    final settings = SettingsController(store: settingsStore);
    addTearDown(settings.dispose);
    settings.load();
    expect(settings.onboardingCompleted, isFalse);

    final controller = CleanController(
      platform: _FakePlatform(),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: _exclusionsStore(),
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

    expect(find.byKey(const ValueKey('onboarding-dialog')), findsOneWidget);
    expect(find.text('欢迎使用 Broom'), findsOneWidget);
    expect(find.text('先扫描，再决定'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('隔离区不是永久删除'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('安全边界'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-done')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('onboarding-dialog')), findsNothing);
    expect(settings.onboardingCompleted, isTrue);
    expect(settingsStore.load().onboardingCompleted, isTrue);
    expect(find.text('开始扫描'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('shows clean progress and undo success', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const root = r'C:\broom_widget_test\cache';
    final items = [
      JunkItem(
        ruleId: 'test.cache',
        rootPath: root,
        path: p.windows.join(root, 'first.tmp'),
        size: 32,
        modified: DateTime(2026, 10, 18),
      ),
      JunkItem(
        ruleId: 'test.cache',
        rootPath: root,
        path: p.windows.join(root, 'second.tmp'),
        size: 32,
        modified: DateTime(2026, 10, 18),
      ),
    ];
    const rule = CleanerRule(
      id: 'test.cache',
      title: '测试缓存',
      category: '测试',
      description: '测试用缓存规则',
      pathPatterns: [],
    );
    final quarantine = _ProgressQuarantineService();
    final controller = CleanController(
      platform: _FixedRootsPlatform(rule: rule, roots: [root]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: quarantine,
      exclusions: _exclusionsStore(),
      scanServiceFactory: () => _FixedScanService(items),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    expect(find.text('已选择 2 项'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清理 2 项'));
    await tester.pumpAndSettle();
    expect(find.text('移入隔离区？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '暂存 2 项'));
    await tester.pump();
    await quarantine.started.future;
    await tester.pump();

    expect(find.text('正在移入隔离区'), findsOneWidget);
    expect(find.text('1 / 2 项'), findsOneWidget);
    expect(find.text('first.tmp'), findsOneWidget);
    expect(find.textContaining('已移动 1 项'), findsOneWidget);

    quarantine.release.complete();
    await tester.pumpAndSettle();

    expect(find.text('清理完成'), findsOneWidget);
    expect(find.text('撤销本次清理'), findsOneWidget);
    expect(find.text('2 个文件'), findsOneWidget);

    await tester.tap(find.text('撤销本次清理'));
    await tester.pumpAndSettle();

    expect(find.text('撤销完成'), findsOneWidget);
    expect(find.textContaining('已恢复 2 个文件'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
