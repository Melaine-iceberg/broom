import 'package:broom/core/platform/linux_system_maintenance.dart';

class FakeLinuxSystemMaintenance implements LinuxSystemMaintenance {
  FakeLinuxSystemMaintenance({
    LinuxSystemAvailability? availability,
    LinuxSystemSelfTestReport? selfTestReport,
    LinuxSystemCleanupReport? cleanupReport,
  }) : availability = availability ?? readyAvailability,
       selfTestReport = selfTestReport ?? readySelfTestReport,
       cleanupReport =
           cleanupReport ?? const LinuxSystemCleanupReport(operations: []);

  static const LinuxSystemCapabilities readyCapabilities =
      LinuxSystemCapabilities(
        helperVersion: 'test',
        operations: [
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.aptCache,
            available: true,
          ),
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.dnfPackages,
            available: true,
          ),
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.pacmanCache,
            available: true,
          ),
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.zypperCache,
            available: true,
          ),
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.flatpakUnused,
            available: true,
          ),
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.snapRevisions,
            available: true,
          ),
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.journal7d,
            available: true,
          ),
        ],
      );

  static const LinuxSystemAvailability readyAvailability =
      LinuxSystemAvailability.available(readyCapabilities);

  static const LinuxSystemSelfTestReport readySelfTestReport =
      LinuxSystemSelfTestReport(
        helperVersion: 'test',
        status: LinuxSystemSelfTestStatus.ok,
        checks: [],
      );

  LinuxSystemAvailability availability;
  LinuxSystemSelfTestReport selfTestReport;
  LinuxSystemCleanupReport cleanupReport;
  Object? probeError;
  Object? selfTestError;
  Object? cleanError;
  int probeCalls = 0;
  int selfTestCalls = 0;
  int cleanCalls = 0;
  Set<LinuxSystemOperation>? lastOperations;

  @override
  Future<LinuxSystemAvailability> probe() async {
    probeCalls++;
    if (probeError case final error?) throw error;
    return availability;
  }

  @override
  Future<LinuxSystemSelfTestReport> selfTest() async {
    selfTestCalls++;
    if (selfTestError case final error?) throw error;
    return selfTestReport;
  }

  @override
  Future<LinuxSystemCleanupReport> clean(
    Set<LinuxSystemOperation> operations,
  ) async {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', '至少选择一个系统清理操作。');
    }
    cleanCalls++;
    lastOperations = Set<LinuxSystemOperation>.unmodifiable(operations);
    if (cleanError case final error?) throw error;
    return cleanupReport;
  }
}
