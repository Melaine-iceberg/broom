import 'package:broom/app.dart';
import 'package:broom/core/platform/linux_system_maintenance.dart';
import 'package:broom/ui/linux_system_cache_controller.dart';
import 'package:broom/ui/linux_system_cache_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/linux_system_maintenance_fakes.dart';

LinuxSystemAvailability _availability({
  bool apt = true,
  bool dnf = true,
  bool pacman = true,
  bool zypper = true,
  bool flatpak = true,
  bool snap = true,
  bool journal = true,
}) {
  return LinuxSystemAvailability.available(
    LinuxSystemCapabilities(
      helperVersion: 'test',
      operations: [
        LinuxSystemOperationCapability(
          operation: LinuxSystemOperation.aptCache,
          available: apt,
          reason: apt ? null : 'tool_missing',
        ),
        LinuxSystemOperationCapability(
          operation: LinuxSystemOperation.dnfPackages,
          available: dnf,
          reason: dnf ? null : 'tool_missing',
        ),
        LinuxSystemOperationCapability(
          operation: LinuxSystemOperation.pacmanCache,
          available: pacman,
          reason: pacman ? null : 'tool_missing',
        ),
        LinuxSystemOperationCapability(
          operation: LinuxSystemOperation.zypperCache,
          available: zypper,
          reason: zypper ? null : 'tool_missing',
        ),
        LinuxSystemOperationCapability(
          operation: LinuxSystemOperation.flatpakUnused,
          available: flatpak,
          reason: flatpak ? null : 'tool_missing',
        ),
        LinuxSystemOperationCapability(
          operation: LinuxSystemOperation.snapRevisions,
          available: snap,
          reason: snap ? null : 'tool_missing',
        ),
        LinuxSystemOperationCapability(
          operation: LinuxSystemOperation.journal7d,
          available: journal,
          reason: journal ? null : 'tool_missing',
        ),
      ],
    ),
  );
}

Future<LinuxSystemCacheController> _pumpPage(
  WidgetTester tester,
  FakeLinuxSystemMaintenance fake,
) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = LinuxSystemCacheController(maintenance: fake);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildBroomTheme(Brightness.light),
      home: LinuxSystemCachePage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _selectAndConfirm(
  WidgetTester tester,
  LinuxSystemOperation operation,
) async {
  await tester.tap(
    find.byKey(ValueKey('linux-system-operation-${operation.id}')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('清理 1 项'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('我明白这些系统缓存将被永久删除，且无法撤销'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('请求授权并清理'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'shows only available operations and selects nothing by default',
    (tester) async {
      await _pumpPage(
        tester,
        FakeLinuxSystemMaintenance(availability: _availability(dnf: false)),
      );

      expect(find.text('APT 包缓存'), findsOneWidget);
      expect(find.text('pacman 包缓存'), findsOneWidget);
      expect(find.text('zypper 包缓存'), findsOneWidget);
      expect(find.text('Flatpak 系统运行时'), findsOneWidget);
      expect(find.text('Snap 旧版本修订'), findsOneWidget);
      expect(find.text('systemd journal（7 天）'), findsOneWidget);
      expect(find.text('DNF 包缓存'), findsNothing);
      expect(find.text('已选择 0 项操作'), findsOneWidget);
      final cleanButton = find.widgetWithText(FilledButton, '清理 0 项');
      expect(tester.widget<FilledButton>(cleanButton).onPressed, isNull);
      expect(find.text('系统助手版本 test'), findsOneWidget);
    },
  );

  testWidgets('requires the acknowledgement before running the helper', (
    tester,
  ) async {
    const report = LinuxSystemCleanupReport(
      operations: [
        LinuxSystemOperationResult(
          operation: LinuxSystemOperation.aptCache,
          status: LinuxSystemOperationStatus.ok,
          message: 'Operation completed.',
          freedBytes: 2048,
        ),
      ],
    );
    final fake = FakeLinuxSystemMaintenance(cleanupReport: report);
    await _pumpPage(tester, fake);

    await tester.tap(
      find.byKey(const ValueKey('linux-system-operation-apt-cache')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理 1 项'));
    await tester.pumpAndSettle();

    expect(find.text('清理系统缓存？'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, '请求授权并清理');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.text('我明白这些系统缓存将被永久删除，且无法撤销'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(fake.cleanCalls, 1);
    expect(fake.lastOperations, {LinuxSystemOperation.aptCache});
    expect(find.text('清理完成'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('共释放约 2.0 KB'), findsOneWidget);
  });

  testWidgets('warns that Flatpak and Snap cleanup cannot be rolled back', (
    tester,
  ) async {
    await _pumpPage(tester, FakeLinuxSystemMaintenance());

    await tester.tap(
      find.byKey(const ValueKey('linux-system-operation-flatpak-unused')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理 1 项'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        '未使用的 Flatpak 运行时与已禁用的 Snap 旧修订会被删除；'
        '当前使用的版本和应用数据不受影响，但被删除的旧版本无法回退。',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('清理系统缓存？'), findsNothing);
  });

  testWidgets('a cancelled authorization keeps the page unchanged', (
    tester,
  ) async {
    final fake = FakeLinuxSystemMaintenance()
      ..cleanError = const LinuxSystemMaintenanceException(
        '已取消授权，未做任何更改。',
        code: 'authorization_cancelled',
        cancelled: true,
      );
    await _pumpPage(tester, fake);

    await _selectAndConfirm(tester, LinuxSystemOperation.journal7d);

    expect(fake.cleanCalls, 1);
    expect(find.text('已取消授权，未做任何更改。'), findsOneWidget);
    expect(find.text('清理 1 项'), findsOneWidget);
    expect(find.text('清理完成'), findsNothing);
  });

  testWidgets('shows an unavailable state when the helper is missing', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      FakeLinuxSystemMaintenance(
        availability: const LinuxSystemAvailability.unavailable(
          LinuxSystemUnavailableReason.helperMissing,
        ),
      ),
    );

    expect(find.text('未安装系统助手'), findsOneWidget);
    expect(find.text('重新检测'), findsOneWidget);
    expect(find.text('APT 包缓存'), findsNothing);
  });
}
