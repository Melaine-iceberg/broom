import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/models/system_models.dart';
import 'package:broom/core/platform/file_lock_probe.dart';
import 'package:broom/core/platform/system_access.dart';
import 'package:broom/ui/system_cache_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/system_cache_fakes.dart';

class _FakeLockProbe implements FileLockProbe {
  _FakeLockProbe(this.lockedPaths, {this.error});

  final Set<String> lockedPaths;
  final Object? error;
  final List<List<String>> batches = [];

  @override
  Future<List<bool>> probePossiblyLocked(List<String> paths) async {
    batches.add(List.of(paths));
    if (error != null) throw error!;
    return [for (final path in paths) lockedPaths.contains(path)];
  }
}

void main() {
  const updateRoot = r'C:\Windows\SoftwareDistribution\Download';
  const deliveryRoot =
      r'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache';
  const quarantineRoot = r'C:\Users\Alice\AppData\Local\Broom\quarantine';

  late FakeSystemAccess access;
  late FakeSystemCachePlatform platform;
  late FakeScanService scanner;
  late FakeSystemCacheCleaner cleaner;
  late SystemCacheController controller;

  List<JunkItem> sampleItems() => [
    JunkItem(
      ruleId: 'windows.update_cache',
      rootPath: updateRoot,
      path: p.windows.join(updateRoot, 'a.cab'),
      size: 100,
      modified: DateTime(2026, 1, 1),
    ),
    JunkItem(
      ruleId: 'windows.update_cache',
      rootPath: updateRoot,
      path: p.windows.join(updateRoot, 'nested', 'b.cab'),
      size: 50,
      modified: DateTime(2026, 1, 2),
    ),
    JunkItem(
      ruleId: 'windows.delivery_optimization',
      rootPath: deliveryRoot,
      path: p.windows.join(deliveryRoot, 'c.bin'),
      size: 25,
      modified: DateTime(2026, 1, 3),
    ),
  ];

  setUp(() {
    access = FakeSystemAccess();
    platform = FakeSystemCachePlatform(
      resolver: (rule) => switch (rule.location) {
        SystemCacheLocation.windowsUpdate => [updateRoot],
        SystemCacheLocation.deliveryOptimization => [deliveryRoot],
      },
    );
    scanner = FakeScanService(
      result: ScanResult(
        items: sampleItems(),
        scannedFiles: 3,
        directoryErrors: 1,
        truncated: true,
        cancelled: false,
      ),
    );
    cleaner = FakeSystemCacheCleaner(
      report: const SystemCleanReport(
        deletedCount: 3,
        deletedBytes: 175,
        failureCount: 0,
        failures: [],
        cancelled: false,
        serviceIssues: [],
      ),
    );
    controller = SystemCacheController(
      platform: platform,
      access: access,
      cleaner: cleaner,
      quarantineRoot: quarantineRoot,
      scanServiceFactory: () => scanner,
    );
  });

  tearDown(() {
    controller.dispose();
  });

  test('scanning requires elevation and leaves the tool idle', () async {
    access.elevated = false;

    await controller.scan();

    expect(controller.phase, SystemCachePhase.idle);
    expect(controller.notice, contains('管理员权限'));
    expect(access.isElevatedCalls, 1);
    expect(scanner.calls, 0);
  });

  test('scanning resolves roots, excludes quarantine and selects nothing '
      'by default', () async {
    await controller.scan();

    expect(controller.phase, SystemCachePhase.preview);
    expect(controller.results, hasLength(2));
    expect(controller.scanDirectoryErrors, 1);
    expect(controller.scanTruncated, isTrue);
    expect(controller.selectedCount, 0);
    expect(controller.selectedBytes, 0);
    expect(scanner.calls, 1);
    expect(scanner.disposed, isTrue);
    expect(scanner.lastExcludedPaths, [quarantineRoot]);
    expect(scanner.lastJobs?.map((job) => job.ruleId), [
      'windows.update_cache',
      'windows.delivery_optimization',
    ]);
    expect(controller.results.first.totalBytes, 150);
  });

  test('selection follows rule checkboxes and deduplicates services', () async {
    await controller.scan();

    controller.toggleRule('windows.update_cache');
    expect(controller.selectedCount, 2);
    expect(controller.selectedBytes, 150);
    expect(controller.selectedServices.map((service) => service.name), [
      'wuauserv',
      'bits',
    ]);

    controller.selectAllRules();
    expect(controller.selectedCount, 3);
    expect(controller.selectedServices.map((service) => service.name), [
      'wuauserv',
      'bits',
      'dosvc',
    ]);

    controller.clearRuleSelection();
    expect(controller.selectedCount, 0);
  });

  test(
    'cleaning passes the selected roots and restarts with a report',
    () async {
      await controller.scan();
      controller.selectAllRules();

      await controller.cleanSelected();

      expect(cleaner.calls, 1);
      expect(cleaner.items, hasLength(3));
      expect(cleaner.rootsByRule, {
        'windows.update_cache': [updateRoot],
        'windows.delivery_optimization': [deliveryRoot],
      });
      expect(cleaner.serviceNames, ['wuauserv', 'bits', 'dosvc']);
      expect(cleaner.stages, [
        SystemCleanStage.stoppingServices,
        SystemCleanStage.deleting,
        SystemCleanStage.restartingServices,
      ]);
      expect(controller.phase, SystemCachePhase.done);
      expect(controller.lastReport, same(cleaner.report));
      expect(controller.cleanProgress, isNull);
      expect(controller.cleanStage, isNull);
    },
  );

  test('cleaning failures return to the preview with an error', () async {
    await controller.scan();
    controller.toggleRule('windows.update_cache');
    cleaner.error = StateError('service control failed');

    await controller.cleanSelected();

    expect(controller.phase, SystemCachePhase.preview);
    expect(controller.error, contains('清理失败'));
    expect(controller.lastReport, isNull);
  });

  test('empty and cancelled scans return to idle with a notice', () async {
    final emptyController = SystemCacheController(
      platform: FakeSystemCachePlatform(resolver: (_) => const []),
      access: access,
      cleaner: cleaner,
      scanServiceFactory: () => scanner,
    );
    addTearDown(emptyController.dispose);

    await emptyController.scan();
    expect(emptyController.phase, SystemCachePhase.idle);
    expect(emptyController.notice, '没有找到可扫描的系统缓存目录。');

    scanner.result = const ScanResult(
      items: [],
      scannedFiles: 2,
      directoryErrors: 0,
      truncated: false,
      cancelled: true,
    );
    final cancelledController = SystemCacheController(
      platform: FakeSystemCachePlatform(resolver: (_) => [updateRoot]),
      access: access,
      cleaner: cleaner,
      scanServiceFactory: () => scanner,
    );
    addTearDown(cancelledController.dispose);

    await cancelledController.scan();
    expect(cancelledController.phase, SystemCachePhase.idle);
    expect(cancelledController.notice, '扫描已取消。');
  });

  test('scan errors and empty results are reported without cleaning', () async {
    scanner.error = StateError('scan exploded');

    await controller.scan();

    expect(controller.phase, SystemCachePhase.idle);
    expect(controller.error, contains('扫描失败'));

    scanner.error = null;
    scanner.result = const ScanResult(
      items: [],
      scannedFiles: 2,
      directoryErrors: 0,
      truncated: false,
      cancelled: false,
    );

    await controller.scan();

    expect(controller.phase, SystemCachePhase.preview);
    expect(controller.results, isEmpty);
    expect(controller.notice, '没有发现可清理的系统缓存。');
  });

  test('returnToIdle clears results and selections', () async {
    await controller.scan();
    controller.selectAllRules();

    controller.returnToIdle();

    expect(controller.phase, SystemCachePhase.idle);
    expect(controller.results, isEmpty);
    expect(controller.selectedCount, 0);
    expect(controller.notice, isNull);
  });

  test('access errors are surfaced on demand', () async {
    access.isElevatedError = const SystemAccessException('拒绝访问');

    await controller.checkAccess();

    expect(controller.accessChecked, isTrue);
    expect(controller.isElevated, isFalse);
    expect(controller.accessError, contains('拒绝访问'));
  });

  test('marks possibly locked files without changing rule selection', () async {
    final items = sampleItems();
    final probe = _FakeLockProbe({items.first.path});
    final probeController = SystemCacheController(
      platform: platform,
      access: access,
      cleaner: cleaner,
      quarantineRoot: quarantineRoot,
      scanServiceFactory: () => scanner,
      lockProbe: probe,
    );
    addTearDown(probeController.dispose);

    await probeController.scan();
    await pumpEventQueue();

    expect(probeController.phase, SystemCachePhase.preview);
    expect(probeController.lockProbeRunning, isFalse);
    expect(probeController.lockProbeChecked, 3);
    expect(probeController.lockProbeTotal, 3);
    expect(
      probeController.possiblyLockedCountForRule('windows.update_cache'),
      1,
    );
    expect(probeController.selectedCount, 0);
    expect(probeController.selectedPossiblyLockedCount, 0);
    expect(
      probe.batches.single.toSet(),
      items.map((item) => item.path).toSet(),
    );

    probeController.toggleRule('windows.update_cache');
    expect(probeController.selectedCount, 2);
    expect(probeController.selectedPossiblyLockedCount, 1);
    expect(
      probeController.results.first.items
          .firstWhere((item) => item.path == items.first.path)
          .possiblyLocked,
      isTrue,
    );
  });

  test('keeps the preview usable when lock probing is unavailable', () async {
    final probe = _FakeLockProbe(
      const {},
      error: const FileLockProbeException('缺少原生通道'),
    );
    final probeController = SystemCacheController(
      platform: platform,
      access: access,
      cleaner: cleaner,
      quarantineRoot: quarantineRoot,
      scanServiceFactory: () => scanner,
      lockProbe: probe,
    );
    addTearDown(probeController.dispose);

    await probeController.scan();
    await pumpEventQueue();

    expect(probeController.phase, SystemCachePhase.preview);
    expect(probeController.lockProbeRunning, isFalse);
    expect(probeController.results, hasLength(2));
    expect(
      probeController.possiblyLockedCountForRule('windows.update_cache'),
      0,
    );

    probeController.selectAllRules();
    expect(probeController.selectedCount, 3);
    expect(probeController.selectedPossiblyLockedCount, 0);
  });

  test('elevation relaunch reports cancellation without errors', () async {
    access.relaunchResult = false;

    expect(await controller.relaunchElevated(), isFalse);
    expect(controller.notice, '已取消管理员授权，未做任何更改。');
    expect(controller.error, isNull);

    access.relaunchError = const SystemAccessException('UAC 失败');
    expect(await controller.relaunchElevated(), isFalse);
    expect(controller.error, contains('无法以管理员身份重新启动'));
  });
}
