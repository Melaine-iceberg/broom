import 'package:broom/core/platform/linux_system_maintenance.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/linux_system_maintenance_fakes.dart';

void main() {
  group('FakeLinuxSystemMaintenance', () {
    test('defaults to a ready helper with both operations available', () async {
      final fake = FakeLinuxSystemMaintenance();

      expect(fake.probeCalls, 0);
      expect(fake.selfTestCalls, 0);
      expect(fake.cleanCalls, 0);
      expect(fake.lastOperations, isNull);

      final availability = await fake.probe();
      final capabilities = availability.capabilities!;

      expect(availability.isAvailable, isTrue);
      expect(capabilities.helperVersion, 'test');
      expect(capabilities.operations, hasLength(2));
      expect(
        capabilities.capabilityFor(LinuxSystemOperation.dnfPackages)!.available,
        isTrue,
      );
      expect(
        capabilities.capabilityFor(LinuxSystemOperation.journal7d)!.reason,
        isNull,
      );
      expect(fake.probeCalls, 1);
    });

    test('returns the configured probe and self-test objects', () async {
      const availability = LinuxSystemAvailability.unavailable(
        LinuxSystemUnavailableReason.policyMissing,
        detail: 'policy is not installed',
      );
      const selfTestReport = LinuxSystemSelfTestReport(
        helperVersion: 'test',
        status: LinuxSystemSelfTestStatus.degraded,
        checks: [
          LinuxSystemSelfTestCheck(
            id: 'polkit.policy',
            status: LinuxSystemSelfTestCheckStatus.warn,
            message: 'policy is not installed',
          ),
        ],
      );
      final fake = FakeLinuxSystemMaintenance(
        availability: availability,
        selfTestReport: selfTestReport,
      );

      expect(await fake.probe(), same(availability));
      expect(await fake.selfTest(), same(selfTestReport));
      expect(fake.probeCalls, 1);
      expect(fake.selfTestCalls, 1);
    });

    test(
      'returns the configured cleanup report and records the call',
      () async {
        final report = LinuxSystemCleanupReport(
          operations: [
            const LinuxSystemOperationResult(
              operation: LinuxSystemOperation.dnfPackages,
              status: LinuxSystemOperationStatus.ok,
              message: 'dnf cleaned',
              freedBytes: 1024,
            ),
            const LinuxSystemOperationResult(
              operation: LinuxSystemOperation.journal7d,
              status: LinuxSystemOperationStatus.failed,
              message: 'journal is busy',
              exitCode: 1,
            ),
          ],
        );
        final fake = FakeLinuxSystemMaintenance(cleanupReport: report);

        final result = await fake.clean({
          LinuxSystemOperation.journal7d,
          LinuxSystemOperation.dnfPackages,
        });

        expect(result, same(report));
        expect(result.hasIssues, isTrue);
        expect(fake.cleanCalls, 1);
        expect(fake.lastOperations, {
          LinuxSystemOperation.dnfPackages,
          LinuxSystemOperation.journal7d,
        });
      },
    );

    test('copies the selection so callers cannot mutate the record', () async {
      final selection = {LinuxSystemOperation.dnfPackages};
      final fake = FakeLinuxSystemMaintenance();

      await fake.clean(selection);
      selection.add(LinuxSystemOperation.journal7d);

      expect(fake.lastOperations, {LinuxSystemOperation.dnfPackages});
      expect(
        () => fake.lastOperations!.add(LinuxSystemOperation.journal7d),
        throwsUnsupportedError,
      );
    });

    test('rejects an empty selection before counting an attempt', () async {
      final fake = FakeLinuxSystemMaintenance();

      await expectLater(
        fake.clean(<LinuxSystemOperation>{}),
        throwsArgumentError,
      );

      expect(fake.cleanCalls, 0);
      expect(fake.lastOperations, isNull);
    });

    test('propagates injected errors and still counts the attempts', () async {
      final fake = FakeLinuxSystemMaintenance()
        ..probeError = const LinuxSystemMaintenanceException('probe failed')
        ..selfTestError = const LinuxSystemMaintenanceException(
          'self-test failed',
        )
        ..cleanError = const LinuxSystemMaintenanceException(
          'clean failed',
          code: 'helper_failed',
        );

      await expectLater(
        fake.probe(),
        throwsA(isA<LinuxSystemMaintenanceException>()),
      );
      await expectLater(
        fake.selfTest(),
        throwsA(isA<LinuxSystemMaintenanceException>()),
      );
      await expectLater(
        fake.clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'helper_failed',
          ),
        ),
      );

      expect(fake.probeCalls, 1);
      expect(fake.selfTestCalls, 1);
      expect(fake.cleanCalls, 1);
      expect(fake.lastOperations, {LinuxSystemOperation.dnfPackages});
    });

    test('can simulate a cancelled authorization', () async {
      final fake = FakeLinuxSystemMaintenance()
        ..cleanError = const LinuxSystemMaintenanceException(
          '已取消授权，未做任何更改。',
          code: 'authorization_cancelled',
          cancelled: true,
        );

      await expectLater(
        fake.clean({LinuxSystemOperation.journal7d}),
        throwsA(
          isA<LinuxSystemMaintenanceException>()
              .having((error) => error.cancelled, 'cancelled', isTrue)
              .having((error) => error.code, 'code', 'authorization_cancelled'),
        ),
      );
    });
  });
}
