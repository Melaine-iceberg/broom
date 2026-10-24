import 'package:broom/core/platform/linux_system_maintenance.dart';
import 'package:broom/ui/linux_system_cache_controller.dart';
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

LinuxSystemCacheController _controller(FakeLinuxSystemMaintenance fake) {
  final controller = LinuxSystemCacheController(maintenance: fake);
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  test('probe exposes only available operations', () async {
    final fake = FakeLinuxSystemMaintenance(
      availability: _availability(apt: false),
    );
    final controller = _controller(fake);

    await controller.probe();

    expect(controller.probed, isTrue);
    expect(controller.isAvailable, isTrue);
    expect(controller.availableOperations.map((entry) => entry.operation), [
      LinuxSystemOperation.dnfPackages,
      LinuxSystemOperation.pacmanCache,
      LinuxSystemOperation.zypperCache,
      LinuxSystemOperation.flatpakUnused,
      LinuxSystemOperation.snapRevisions,
      LinuxSystemOperation.journal7d,
    ]);
    expect(controller.unavailableReason, isNull);
    expect(controller.selectedCount, 0);
  });

  test('unavailable operations cannot be selected', () async {
    final fake = FakeLinuxSystemMaintenance(
      availability: _availability(dnf: false),
    );
    final controller = _controller(fake);
    await controller.probe();

    controller.toggleOperation(LinuxSystemOperation.dnfPackages);
    controller.toggleOperation(LinuxSystemOperation.aptCache);

    expect(controller.isSelected(LinuxSystemOperation.dnfPackages), isFalse);
    expect(controller.isSelected(LinuxSystemOperation.aptCache), isTrue);
    expect(controller.selectedOperations, [LinuxSystemOperation.aptCache]);
  });

  test('cleans the selection in canonical order and reports results', () async {
    const report = LinuxSystemCleanupReport(
      operations: [
        LinuxSystemOperationResult(
          operation: LinuxSystemOperation.aptCache,
          status: LinuxSystemOperationStatus.ok,
          message: 'done',
          freedBytes: 2048,
        ),
        LinuxSystemOperationResult(
          operation: LinuxSystemOperation.journal7d,
          status: LinuxSystemOperationStatus.busy,
          message: 'busy',
        ),
      ],
    );
    final fake = FakeLinuxSystemMaintenance(cleanupReport: report);
    final controller = _controller(fake);
    await controller.probe();

    controller.toggleOperation(LinuxSystemOperation.journal7d);
    controller.toggleOperation(LinuxSystemOperation.aptCache);
    await controller.cleanSelected();

    expect(fake.cleanCalls, 1);
    expect(fake.lastOperations, {
      LinuxSystemOperation.aptCache,
      LinuxSystemOperation.journal7d,
    });
    expect(controller.phase, LinuxSystemCachePhase.done);
    expect(controller.lastReport, same(report));
    expect(controller.selectedCount, 2);
  });

  test(
    'a cancelled authorization keeps the selection and reports no change',
    () async {
      final fake = FakeLinuxSystemMaintenance()
        ..cleanError = const LinuxSystemMaintenanceException(
          '已取消授权，未做任何更改。',
          code: 'authorization_cancelled',
          cancelled: true,
        );
      final controller = _controller(fake);
      await controller.probe();
      controller.toggleOperation(LinuxSystemOperation.journal7d);

      await controller.cleanSelected();

      expect(controller.phase, LinuxSystemCachePhase.idle);
      expect(controller.lastReport, isNull);
      expect(controller.error, isNull);
      expect(controller.notice, '已取消授权，未做任何更改。');
      expect(controller.isSelected(LinuxSystemOperation.journal7d), isTrue);
    },
  );

  test('a helper that disappeared makes the page unavailable', () async {
    final fake = FakeLinuxSystemMaintenance()
      ..cleanError = const LinuxSystemMaintenanceException(
        '未安装系统助手。',
        code: 'helper_missing',
      );
    final controller = _controller(fake);
    await controller.probe();
    controller.toggleOperation(LinuxSystemOperation.aptCache);

    await controller.cleanSelected();

    expect(controller.phase, LinuxSystemCachePhase.idle);
    expect(controller.isAvailable, isFalse);
    expect(
      controller.unavailableReason,
      LinuxSystemUnavailableReason.helperMissing,
    );
    expect(controller.error, '未安装系统助手。');
    expect(controller.selectedCount, 0);
  });

  test('probe failures surface as an unavailable helper', () async {
    final fake = FakeLinuxSystemMaintenance()
      ..probeError = const LinuxSystemMaintenanceException('spawn failed');
    final controller = _controller(fake);

    await controller.probe();

    expect(controller.probed, isTrue);
    expect(controller.isAvailable, isFalse);
    expect(
      controller.unavailableReason,
      LinuxSystemUnavailableReason.helperFailed,
    );
    expect(controller.unavailableDetail, contains('spawn failed'));
  });

  test('re-probing drops selections that became unavailable', () async {
    final fake = FakeLinuxSystemMaintenance();
    final controller = _controller(fake);
    await controller.probe();
    controller.toggleOperation(LinuxSystemOperation.aptCache);
    controller.toggleOperation(LinuxSystemOperation.journal7d);

    fake.availability = _availability(apt: false);
    await controller.probe();

    expect(controller.selectedOperations, [LinuxSystemOperation.journal7d]);
  });
}
