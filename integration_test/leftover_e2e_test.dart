import 'dart:io';

import 'package:broom/app.dart';
import 'package:broom/core/clean/file_metadata.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/leftover/leftover_service.dart';
import 'package:broom/core/models/app_settings.dart';
import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/file_lock_probe.dart';
import 'package:broom/core/platform/installed_apps.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'support/integration_fakes.dart';

/// Real-machine end-to-end check for the leftover pipeline.
///
/// The application inventory comes from the native Windows registry channel and
/// the scan, quarantine move and undo run against the real filesystem. The
/// "uninstalled" application is simulated with a temporary data directory, an
/// install marker that does not exist, and a display name that is not present
/// in the registry.
/// Pumps until [condition] holds. The scanner and quarantine run real I/O, so
/// animations settling is not a completion signal on a live device.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$reason');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('detects, cleans and restores a simulated uninstalled app', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('broom_e2e_leftover_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    const appName = 'Broom E2E Removed App';
    final dataDir = Directory(p.join(temp.path, 'AppData', 'E2EApp'))
      ..createSync(recursive: true);
    final firstFile = File(p.join(dataDir.path, 'session.dat'))
      ..writeAsBytesSync(List<int>.filled(4096, 7));
    final secondFile = File(p.join(dataDir.path, 'cache.bin'))
      ..writeAsBytesSync(List<int>.filled(2048, 9));
    final installMarker = p.join(
      temp.path,
      'LocalAppData',
      'E2EApp',
      'app.exe',
    );
    final quarantineRoot = p.join(temp.path, 'quarantine');

    final guard = PathGuard.forWindows(
      environment: Platform.environment,
      additionalProtectedRoots: [quarantineRoot],
    );
    final exclusions = ExclusionStore(
      filePath: p.join(temp.path, 'exclusions.json'),
    );
    await exclusions.ensureLoaded();
    final quarantine = QuarantineService(
      quarantineRoot: quarantineRoot,
      guard: guard,
      metadataAccess: createFileMetadataAccess(),
      exclusions: exclusions,
    );
    final leftover = LeftoverService(
      installedApps: const MethodChannelInstalledApps(),
      guard: guard,
      exclusions: exclusions,
      environment: const {},
      entries: [
        LeftoverCatalogEntry(
          id: 'e2e_removed',
          appName: appName,
          appNameEn: appName,
          description: 'Robotic test data for an app that is not installed.',
          descriptionEn: 'Robotic test data for an app that is not installed.',
          dataPathPatterns: [dataDir.path],
          installMarkerPatterns: [installMarker],
          installDisplayNamePrefixes: [appName],
        ),
      ],
    );

    // No catalog rules: the only scan job is the leftover job, so the test can
    // assert the runtime rule end to end without touching real caches.
    final platform = WindowsCleanerPlatform(rules: const []);
    final settings = SettingsController(initial: AppSettings.defaults);
    addTearDown(settings.dispose);
    final controller = CleanController(
      platform: platform,
      guard: guard,
      quarantine: quarantine,
      exclusions: exclusions,
      leftoverService: leftover,
      isRuleEnabled: settings.isRuleEnabled,
      scanSettings: () => settings.scanSettings,
      scanServiceFactory: ScanService.new,
      lockProbe: createFileLockProbe(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    // Detection must come from the real registry: a simulated app whose name
    // is absent there is reported as a leftover.
    expect(
      controller.leftoverDetectionError,
      isNull,
      reason: '读取真实已安装应用清单失败：${controller.leftoverDetectionError}',
    );
    expect(controller.leftoverDetectedCount, 1);
    expect(controller.scanCategories.last.isLeftover, isTrue);
    expect(controller.scanCategories.last.ruleCount, 1);

    // The production catalog must also run against this machine's real
    // registry and environment. This pass is read-only.
    final productionDetection = await LeftoverService(
      installedApps: const MethodChannelInstalledApps(),
      guard: guard,
      exclusions: exclusions,
    ).detect();
    expect(
      productionDetection.error,
      isNull,
      reason: '生产清单读取失败：${productionDetection.error}',
    );
    expect(
      productionDetection.candidates.every(
        (candidate) =>
            candidate.paths.every((path) => Directory(path).existsSync()),
      ),
      isTrue,
    );

    await tester.pumpWidget(
      BroomApp(
        controller: controller,
        settingsController: settings,
        systemShell: IntegrationShell(),
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
    expect(find.text('1 个残留应用'), findsOneWidget);
    final leftoverToggle = find.byKey(const ValueKey('scan-category-leftover'));
    await tester.ensureVisible(leftoverToggle);
    expect(leftoverToggle, findsOneWidget);

    await tester.ensureVisible(find.text('开始扫描'));
    await tester.tap(find.text('开始扫描'));
    await pumpUntil(
      tester,
      () => controller.phase == CleanPhase.preview,
      reason: '扫描未进入预览',
      timeout: const Duration(seconds: 90),
    );

    expect(controller.phase, CleanPhase.preview);
    expect(controller.results, hasLength(1));
    expect(controller.results.single.rule.id, 'leftover.e2e_removed');
    expect(controller.results.single.items, hasLength(2));
    expect(controller.selectedCount, 0, reason: '卸载残留属于需确认规则');

    // Review rules are opt-in; select them explicitly and clean through the UI.
    controller.selectAllRules();
    await tester.pumpAndSettle();
    expect(controller.selectedCount, 2);

    await tester.tap(find.widgetWithText(FilledButton, '清理 2 项'));
    await tester.pumpAndSettle();
    expect(find.text('移入隔离区？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('acknowledge-review-clean')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '暂存 2 项'));
    await pumpUntil(
      tester,
      () => controller.phase == CleanPhase.done,
      reason: '清理未完成',
    );

    expect(controller.phase, CleanPhase.done);
    expect(find.text('清理完成'), findsOneWidget);
    expect(firstFile.existsSync(), isFalse);
    expect(secondFile.existsSync(), isFalse);

    // Quarantine keeps the original name behind a sequence prefix.
    final movedNames = Directory(quarantineRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => p.windows.basename(file.path))
        .toList();
    expect(
      movedNames.where((name) => name.endsWith('session.dat')),
      hasLength(1),
    );
    expect(
      movedNames.where((name) => name.endsWith('cache.bin')),
      hasLength(1),
    );

    await tester.tap(find.text('撤销本次清理'));
    await pumpUntil(
      tester,
      () => firstFile.existsSync() && secondFile.existsSync(),
      reason: '撤销未恢复文件',
    );

    expect(firstFile.existsSync(), isTrue);
    expect(firstFile.lengthSync(), 4096);
    expect(secondFile.existsSync(), isTrue);
    expect(secondFile.lengthSync(), 2048);
  });
}
