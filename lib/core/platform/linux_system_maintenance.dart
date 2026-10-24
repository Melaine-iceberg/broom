import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Operations understood by the privileged Linux system helper.
///
/// The wire ids are the only values that may cross the pkexec boundary; paths,
/// commands and free-form arguments are deliberately unrepresentable.
enum LinuxSystemOperation {
  aptCache('apt-cache'),
  dnfPackages('dnf-packages'),
  journal7d('journal-7d');

  const LinuxSystemOperation(this.id);

  final String id;

  static LinuxSystemOperation? fromId(String id) {
    for (final operation in values) {
      if (operation.id == id) return operation;
    }
    return null;
  }
}

class LinuxSystemOperationCapability {
  const LinuxSystemOperationCapability({
    required this.operation,
    required this.available,
    this.reason,
  });

  final LinuxSystemOperation operation;
  final bool available;
  final String? reason;
}

class LinuxSystemCapabilities {
  const LinuxSystemCapabilities({
    required this.helperVersion,
    required this.operations,
  });

  final String helperVersion;
  final List<LinuxSystemOperationCapability> operations;

  LinuxSystemOperationCapability? capabilityFor(
    LinuxSystemOperation operation,
  ) {
    for (final capability in operations) {
      if (capability.operation == operation) return capability;
    }
    return null;
  }
}

enum LinuxSystemUnavailableReason {
  helperMissing,
  policyMissing,
  pkexecMissing,
  helperFailed,
}

class LinuxSystemAvailability {
  const LinuxSystemAvailability._({
    required this.capabilities,
    required this.reason,
    required this.detail,
  });

  const LinuxSystemAvailability.available(LinuxSystemCapabilities capabilities)
    : this._(capabilities: capabilities, reason: null, detail: null);

  const LinuxSystemAvailability.unavailable(
    LinuxSystemUnavailableReason reason, {
    String? detail,
  }) : this._(capabilities: null, reason: reason, detail: detail);

  final LinuxSystemCapabilities? capabilities;
  final LinuxSystemUnavailableReason? reason;
  final String? detail;

  bool get isAvailable => capabilities != null;
}

enum LinuxSystemSelfTestStatus { ok, degraded, failed }

enum LinuxSystemSelfTestCheckStatus { pass, warn, fail }

class LinuxSystemSelfTestCheck {
  const LinuxSystemSelfTestCheck({
    required this.id,
    required this.status,
    required this.message,
  });

  final String id;
  final LinuxSystemSelfTestCheckStatus status;
  final String message;
}

class LinuxSystemSelfTestReport {
  const LinuxSystemSelfTestReport({
    required this.helperVersion,
    required this.status,
    required this.checks,
  });

  final String helperVersion;
  final LinuxSystemSelfTestStatus status;
  final List<LinuxSystemSelfTestCheck> checks;
}

enum LinuxSystemOperationStatus { ok, failed, busy, skipped, unavailable }

class LinuxSystemOperationResult {
  const LinuxSystemOperationResult({
    required this.operation,
    required this.status,
    required this.message,
    this.exitCode,
    this.freedBytes,
  });

  final LinuxSystemOperation operation;
  final LinuxSystemOperationStatus status;
  final String message;
  final int? exitCode;
  final int? freedBytes;
}

class LinuxSystemCleanupReport {
  const LinuxSystemCleanupReport({required this.operations});

  final List<LinuxSystemOperationResult> operations;

  bool get hasIssues => operations.any(
    (result) => result.status != LinuxSystemOperationStatus.ok,
  );
}

class LinuxSystemMaintenanceException implements Exception {
  const LinuxSystemMaintenanceException(
    this.message, {
    this.code,
    this.cancelled = false,
  });

  final String message;
  final String? code;
  final bool cancelled;

  @override
  String toString() => message;
}

abstract interface class LinuxSystemMaintenance {
  /// Checks the installed helper, the Polkit policy and pkexec without
  /// prompting for authorization. The helper is invoked directly for its
  /// fixed operation list, never through pkexec.
  Future<LinuxSystemAvailability> probe();

  /// Runs the helper's read-only diagnostics directly, without pkexec.
  Future<LinuxSystemSelfTestReport> selfTest();

  /// Authorizes once with pkexec and asks the helper to run [operations].
  ///
  /// Only fixed operation ids are passed across the privilege boundary. An
  /// empty selection is a programming error and performs no work.
  Future<LinuxSystemCleanupReport> clean(Set<LinuxSystemOperation> operations);
}

class LinuxProcessResult {
  const LinuxProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef LinuxProcessRunner = Future<LinuxProcessResult> Function(
  String executable,
  List<String> arguments, {
  required Duration timeout,
});

/// Executes the helper directly. It inherits the desktop session environment
/// on purpose: pkexec needs DISPLAY, XDG_RUNTIME_DIR and the D-Bus address to
/// reach the authentication agent.
class PkexecLinuxSystemMaintenance implements LinuxSystemMaintenance {
  PkexecLinuxSystemMaintenance({
    this.helperPath = defaultHelperPath,
    this.policyPath = defaultPolicyPath,
    this.pkexecPath = defaultPkexecPath,
    LinuxProcessRunner? runner,
  }) : _runner = runner ?? _runLinuxProcess;

  static const String defaultHelperPath =
      '/usr/libexec/broom/broom-system-helper';
  static const String defaultPolicyPath =
      '/usr/share/polkit-1/actions/com.broom.Broom.policy';
  static const String defaultPkexecPath = '/usr/bin/pkexec';

  static const Duration _probeTimeout = Duration(seconds: 15);
  static const Duration _selfTestTimeout = Duration(seconds: 30);
  // The helper owns the per-operation timeouts (APT 10m + DNF 10m + journal
  // 2m). This final guard must stay above their sum so pkexec is not killed
  // while a legitimate helper run is still working.
  static const Duration _cleanTimeout = Duration(minutes: 25);

  final String helperPath;
  final String policyPath;
  final String pkexecPath;
  final LinuxProcessRunner _runner;

  @override
  Future<LinuxSystemAvailability> probe() async {
    final missing = await _missingPrerequisite();
    if (missing != null) {
      return LinuxSystemAvailability.unavailable(missing);
    }

    try {
      final result = await _runner(helperPath, const [
        '--list',
        '--json',
      ], timeout: _probeTimeout);
      if (result.exitCode != 0) {
        return LinuxSystemAvailability.unavailable(
          LinuxSystemUnavailableReason.helperFailed,
          detail: _summarize(result),
        );
      }
      return LinuxSystemAvailability.available(
        _parseCapabilities(result.stdout),
      );
    } on LinuxSystemMaintenanceException catch (error) {
      return LinuxSystemAvailability.unavailable(
        LinuxSystemUnavailableReason.helperFailed,
        detail: error.message,
      );
    } on FormatException catch (error) {
      return LinuxSystemAvailability.unavailable(
        LinuxSystemUnavailableReason.helperFailed,
        detail: error.message,
      );
    }
  }

  @override
  Future<LinuxSystemSelfTestReport> selfTest() async {
    await _requireHelper();
    final result = await _runner(helperPath, const [
      '--self-test',
      '--json',
    ], timeout: _selfTestTimeout);
    try {
      return _parseSelfTest(result.stdout);
    } on FormatException catch (error) {
      throw LinuxSystemMaintenanceException(
        error.message.isEmpty ? _summarize(result) : error.message,
        code: 'invalid_response',
      );
    }
  }

  @override
  Future<LinuxSystemCleanupReport> clean(
    Set<LinuxSystemOperation> operations,
  ) async {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', '至少选择一个系统清理操作。');
    }
    await _requireInstallation();

    final ordered = [
      for (final operation in LinuxSystemOperation.values)
        if (operations.contains(operation)) operation,
    ];
    final result = await _runner(pkexecPath, [
      helperPath,
      '--run',
      ordered.map((operation) => operation.id).join(','),
      '--json',
    ], timeout: _cleanTimeout);

    if (result.exitCode == 126) {
      throw const LinuxSystemMaintenanceException(
        '已取消授权，未做任何更改。',
        code: 'authorization_cancelled',
        cancelled: true,
      );
    }
    if (result.exitCode == 127) {
      throw LinuxSystemMaintenanceException(
        '授权失败：${_summarize(result)}',
        code: 'authorization_failed',
      );
    }
    if (result.exitCode != 0) {
      final helperError = _tryParseHelperError(result.stdout);
      if (helperError != null) {
        throw LinuxSystemMaintenanceException(
          helperError.message,
          code: helperError.code,
        );
      }
      throw LinuxSystemMaintenanceException(
        _summarize(result),
        code: 'helper_failed',
      );
    }

    try {
      return _parseCleanupReport(result.stdout, ordered);
    } on FormatException catch (error) {
      throw LinuxSystemMaintenanceException(
        '系统助手返回了无法识别的结果：${error.message}',
        code: 'invalid_response',
      );
    }
  }

  Future<LinuxSystemUnavailableReason?> _missingPrerequisite() async {
    if (!await File(helperPath).exists()) {
      return LinuxSystemUnavailableReason.helperMissing;
    }
    if (!await File(policyPath).exists()) {
      return LinuxSystemUnavailableReason.policyMissing;
    }
    if (!await File(pkexecPath).exists()) {
      return LinuxSystemUnavailableReason.pkexecMissing;
    }
    return null;
  }

  Future<void> _requireHelper() async {
    if (!await File(helperPath).exists()) {
      throw const LinuxSystemMaintenanceException(
        '未安装系统助手。',
        code: 'helper_missing',
      );
    }
  }

  Future<void> _requireInstallation() async {
    final missing = await _missingPrerequisite();
    switch (missing) {
      case null:
        return;
      case LinuxSystemUnavailableReason.helperMissing:
        throw const LinuxSystemMaintenanceException(
          '未安装系统助手。',
          code: 'helper_missing',
        );
      case LinuxSystemUnavailableReason.policyMissing:
        throw const LinuxSystemMaintenanceException(
          '未安装系统助手的 Polkit policy。',
          code: 'policy_missing',
        );
      case LinuxSystemUnavailableReason.pkexecMissing:
        throw const LinuxSystemMaintenanceException(
          '系统缺少 pkexec，无法请求授权。',
          code: 'pkexec_missing',
        );
      case LinuxSystemUnavailableReason.helperFailed:
        throw const LinuxSystemMaintenanceException(
          '系统助手不可用。',
          code: 'helper_failed',
        );
    }
  }
}

/// Returns the production implementation only when all installation pieces are
/// present. Callers pass `null` to the UI otherwise, which hides the system
/// cache entry for tar.gz builds and incomplete installs. This check is
/// read-only and never invokes pkexec.
LinuxSystemMaintenance? createLinuxSystemMaintenance({
  String helperPath = PkexecLinuxSystemMaintenance.defaultHelperPath,
  String policyPath = PkexecLinuxSystemMaintenance.defaultPolicyPath,
  String pkexecPath = PkexecLinuxSystemMaintenance.defaultPkexecPath,
}) {
  if (!Platform.isLinux) return null;
  if (!File(helperPath).existsSync() ||
      !File(policyPath).existsSync() ||
      !File(pkexecPath).existsSync()) {
    return null;
  }
  return PkexecLinuxSystemMaintenance(
    helperPath: helperPath,
    policyPath: policyPath,
    pkexecPath: pkexecPath,
  );
}

Future<LinuxProcessResult> _runLinuxProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
}) async {
  final Process process;
  try {
    process = await Process.start(executable, arguments);
  } on ProcessException catch (error) {
    throw LinuxSystemMaintenanceException(
      '无法启动系统助手：${error.message}',
      code: 'process_error',
    );
  }

  final stdoutFuture = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final stderrFuture = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    final exitCode = await process.exitCode.timeout(timeout);
    return LinuxProcessResult(
      exitCode: exitCode,
      stdout: await stdoutFuture,
      stderr: await stderrFuture,
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await _drain(stdoutFuture);
    await _drain(stderrFuture);
    throw const LinuxSystemMaintenanceException('系统助手响应超时。', code: 'timeout');
  }
}

Future<void> _drain(Future<String> stream) async {
  try {
    await stream.timeout(const Duration(seconds: 1));
  } catch (_) {
    // The pipe may close abruptly after the process is killed.
  }
}

String _summarize(LinuxProcessResult result) {
  final stderr = result.stderr.trim();
  if (stderr.isEmpty) return '系统助手返回退出码 ${result.exitCode}。';
  if (stderr.length <= 500) return stderr;
  return '${stderr.substring(0, 500)}...';
}

Map<String, dynamic> _decodeObject(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('系统助手返回了无法解析的 JSON。');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('系统助手返回了无法识别的数据。');
  }
  return decoded;
}

void _expectSchemaVersion(Map<String, dynamic> root) {
  final schemaVersion = root['schemaVersion'];
  if (schemaVersion is! int || schemaVersion != 1) {
    throw const FormatException('系统助手返回了不支持的 schemaVersion。');
  }
}

LinuxSystemCapabilities _parseCapabilities(String stdout) {
  final root = _decodeObject(stdout);
  _expectSchemaVersion(root);

  final helperVersion = root['helperVersion'];
  if (helperVersion is! String || helperVersion.trim().isEmpty) {
    throw const FormatException('系统助手未返回版本。');
  }
  final rawOperations = root['operations'];
  if (rawOperations is! List<dynamic>) {
    throw const FormatException('系统助手未返回操作列表。');
  }

  final parsed = <LinuxSystemOperation, LinuxSystemOperationCapability>{};
  for (final raw in rawOperations) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('系统助手返回了无法识别的操作。');
    }
    final id = raw['id'];
    if (id is! String) {
      throw const FormatException('系统助手返回了缺少 id 的操作。');
    }
    final operation = LinuxSystemOperation.fromId(id);
    if (operation == null) continue;
    if (parsed.containsKey(operation)) {
      throw FormatException('系统助手重复返回了 ${operation.id}。');
    }
    final available = raw['available'];
    if (available is! bool) {
      throw FormatException('系统助手未返回 ${operation.id} 的可用状态。');
    }
    final reason = raw['reason'];
    if (reason != null && reason is! String) {
      throw FormatException('系统助手返回了无法识别的 ${operation.id} 原因。');
    }
    parsed[operation] = LinuxSystemOperationCapability(
      operation: operation,
      available: available,
      reason: reason is String ? reason : null,
    );
  }

  final operations = <LinuxSystemOperationCapability>[];
  for (final operation in LinuxSystemOperation.values) {
    final capability = parsed[operation];
    if (capability == null) {
      throw FormatException('系统助手未报告 ${operation.id}。');
    }
    operations.add(capability);
  }

  return LinuxSystemCapabilities(
    helperVersion: helperVersion,
    operations: operations,
  );
}

LinuxSystemSelfTestReport _parseSelfTest(String stdout) {
  final root = _decodeObject(stdout);
  _expectSchemaVersion(root);

  final helperVersion = root['helperVersion'];
  if (helperVersion is! String || helperVersion.trim().isEmpty) {
    throw const FormatException('系统助手未返回版本。');
  }
  final rawStatus = root['status'];
  if (rawStatus is! String) {
    throw const FormatException('系统助手未返回自检状态。');
  }
  final status = switch (rawStatus) {
    'ok' => LinuxSystemSelfTestStatus.ok,
    'degraded' => LinuxSystemSelfTestStatus.degraded,
    'failed' => LinuxSystemSelfTestStatus.failed,
    _ => throw FormatException('系统助手返回了未知自检状态：$rawStatus。'),
  };

  final rawChecks = root['checks'];
  if (rawChecks is! List<dynamic>) {
    throw const FormatException('系统助手未返回自检项目。');
  }
  final checks = <LinuxSystemSelfTestCheck>[];
  for (final raw in rawChecks) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('系统助手返回了无法识别的自检项目。');
    }
    final id = raw['id'];
    final rawCheckStatus = raw['status'];
    final message = raw['message'];
    if (id is! String || rawCheckStatus is! String || message is! String) {
      throw const FormatException('系统助手返回了不完整的自检项目。');
    }
    final checkStatus = switch (rawCheckStatus) {
      'pass' => LinuxSystemSelfTestCheckStatus.pass,
      'warn' => LinuxSystemSelfTestCheckStatus.warn,
      'fail' => LinuxSystemSelfTestCheckStatus.fail,
      _ => throw FormatException('系统助手返回了未知自检结果：$rawCheckStatus。'),
    };
    checks.add(
      LinuxSystemSelfTestCheck(id: id, status: checkStatus, message: message),
    );
  }

  return LinuxSystemSelfTestReport(
    helperVersion: helperVersion,
    status: status,
    checks: checks,
  );
}

LinuxSystemCleanupReport _parseCleanupReport(
  String stdout,
  List<LinuxSystemOperation> requested,
) {
  final root = _decodeObject(stdout);
  _expectSchemaVersion(root);

  final rawOperations = root['operations'];
  if (rawOperations is! List<dynamic>) {
    throw const FormatException('系统助手未返回操作结果。');
  }
  final parsed = <LinuxSystemOperation, LinuxSystemOperationResult>{};
  for (final raw in rawOperations) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('系统助手返回了无法识别的操作结果。');
    }
    final id = raw['id'];
    if (id is! String) {
      throw const FormatException('系统助手返回了缺少 id 的操作结果。');
    }
    final operation = LinuxSystemOperation.fromId(id);
    if (operation == null) {
      throw FormatException('系统助手返回了未知操作：$id。');
    }
    if (parsed.containsKey(operation)) {
      throw FormatException('系统助手重复返回了 ${operation.id} 的结果。');
    }
    final rawStatus = raw['status'];
    if (rawStatus is! String) {
      throw FormatException('系统助手未返回 ${operation.id} 的状态。');
    }
    final status = switch (rawStatus) {
      'ok' => LinuxSystemOperationStatus.ok,
      'failed' => LinuxSystemOperationStatus.failed,
      'busy' => LinuxSystemOperationStatus.busy,
      'skipped' => LinuxSystemOperationStatus.skipped,
      'unavailable' => LinuxSystemOperationStatus.unavailable,
      _ => throw FormatException('系统助手返回了未知操作状态：$rawStatus。'),
    };
    final exitCode = raw['exitCode'];
    if (exitCode != null && exitCode is! int) {
      throw FormatException('系统助手返回了无法识别的 ${operation.id} 退出码。');
    }
    final freedBytes = raw['freedBytes'];
    if (freedBytes != null && (freedBytes is! int || freedBytes < 0)) {
      throw FormatException('系统助手返回了无法识别的 ${operation.id} 释放空间。');
    }
    final message = raw['message'];
    if (message is! String) {
      throw FormatException('系统助手未返回 ${operation.id} 的结果说明。');
    }
    parsed[operation] = LinuxSystemOperationResult(
      operation: operation,
      status: status,
      message: message,
      exitCode: exitCode is int ? exitCode : null,
      freedBytes: freedBytes is int ? freedBytes : null,
    );
  }

  if (parsed.length != requested.length) {
    throw const FormatException('系统助手返回的操作结果与请求不一致。');
  }
  final results = <LinuxSystemOperationResult>[];
  for (final operation in requested) {
    final result = parsed[operation];
    if (result == null) {
      throw FormatException('系统助手缺少 ${operation.id} 的结果。');
    }
    results.add(result);
  }
  return LinuxSystemCleanupReport(operations: results);
}

class _HelperError {
  const _HelperError(this.code, this.message);

  final String code;
  final String message;
}

_HelperError? _tryParseHelperError(String stdout) {
  try {
    final root = _decodeObject(stdout);
    final error = root['error'];
    if (error is! Map<String, dynamic>) return null;
    final code = error['code'];
    final message = error['message'];
    if (code is! String || message is! String) return null;
    return _HelperError(code, message);
  } on FormatException {
    return null;
  }
}
