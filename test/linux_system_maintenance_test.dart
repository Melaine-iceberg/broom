import 'dart:convert';
import 'dart:io';

import 'package:broom/core/platform/linux_system_maintenance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RunnerCall {
  const _RunnerCall(this.executable, this.arguments, this.timeout);

  final String executable;
  final List<String> arguments;
  final Duration timeout;
}

class _FakeRunner {
  _FakeRunner(this.handler);

  final Future<LinuxProcessResult> Function(
    String executable,
    List<String> arguments,
  )
  handler;
  final List<_RunnerCall> calls = [];

  Future<LinuxProcessResult> call(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) {
    calls.add(
      _RunnerCall(executable, List<String>.unmodifiable(arguments), timeout),
    );
    return handler(executable, arguments);
  }
}

String _json(Object? value) => jsonEncode(value);

Map<String, Object?> _capability(
  String id, {
  bool available = true,
  String? reason,
  int timeoutSeconds = 600,
}) {
  return {
    'id': id,
    'available': available,
    'reason': reason,
    'timeoutSeconds': timeoutSeconds,
  };
}

String _capabilitiesJson({
  String version = '0.1.0',
  List<Map<String, Object?>>? operations,
}) {
  return _json({
    'schemaVersion': 1,
    'helperVersion': version,
    'operations':
        operations ??
        [
          _capability('apt-cache'),
          _capability('dnf-packages'),
          _capability('journal-7d', timeoutSeconds: 120),
        ],
  });
}

String _selfTestJson({
  String version = '0.1.0',
  String status = 'ok',
  List<Map<String, Object?>>? checks,
}) {
  return _json({
    'schemaVersion': 1,
    'helperVersion': version,
    'status': status,
    'checks':
        checks ??
        [
          {'id': 'helper.install', 'status': 'pass', 'message': 'ready'},
          {
            'id': 'operation.dnf-packages',
            'status': 'pass',
            'message': 'ready',
          },
        ],
  });
}

Map<String, Object?> _operationResult(
  String id,
  String status, {
  int? exitCode,
  int? freedBytes,
  String message = 'done',
}) {
  return {
    'id': id,
    'status': status,
    'exitCode': exitCode,
    'freedBytes': freedBytes,
    'message': message,
  };
}

String _reportJson(List<Map<String, Object?>> operations) {
  return _json({'schemaVersion': 1, 'operations': operations});
}

String _errorJson(String code, String message, int exitCode) {
  return _json({
    'schemaVersion': 1,
    'error': {'code': code, 'message': message, 'exitCode': exitCode},
  });
}

LinuxProcessResult _result(
  String stdout, {
  int exitCode = 0,
  String stderr = '',
}) {
  return LinuxProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr);
}

void main() {
  late Directory temp;
  late String helperPath;
  late String policyPath;
  late String pkexecPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_system_maintenance_');
    helperPath = p.join(temp.path, 'broom-system-helper');
    policyPath = p.join(temp.path, 'com.broom.Broom.policy');
    pkexecPath = p.join(temp.path, 'pkexec');
    for (final path in [helperPath, policyPath, pkexecPath]) {
      await File(path).writeAsString('test');
    }
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  PkexecLinuxSystemMaintenance clientFor(_FakeRunner runner) {
    return PkexecLinuxSystemMaintenance(
      helperPath: helperPath,
      policyPath: policyPath,
      pkexecPath: pkexecPath,
      runner: runner.call,
    );
  }

  _FakeRunner unusedRunner() {
    return _FakeRunner((executable, arguments) async {
      throw StateError('the process runner must not be called');
    });
  }

  group('models', () {
    test('maps stable wire ids to operations', () {
      expect(LinuxSystemOperation.aptCache.id, 'apt-cache');
      expect(LinuxSystemOperation.dnfPackages.id, 'dnf-packages');
      expect(LinuxSystemOperation.journal7d.id, 'journal-7d');
      expect(
        LinuxSystemOperation.fromId('apt-cache'),
        LinuxSystemOperation.aptCache,
      );
      expect(
        LinuxSystemOperation.fromId('dnf-packages'),
        LinuxSystemOperation.dnfPackages,
      );
      expect(
        LinuxSystemOperation.fromId('journal-7d'),
        LinuxSystemOperation.journal7d,
      );
      expect(LinuxSystemOperation.fromId('apt-get'), isNull);
      expect(LinuxSystemOperation.fromId(''), isNull);
    });

    test('capabilityFor finds only reported operations', () {
      const capabilities = LinuxSystemCapabilities(
        helperVersion: '0.1.0',
        operations: [
          LinuxSystemOperationCapability(
            operation: LinuxSystemOperation.dnfPackages,
            available: false,
            reason: 'tool_missing',
          ),
        ],
      );

      expect(
        capabilities.capabilityFor(LinuxSystemOperation.dnfPackages)!.reason,
        'tool_missing',
      );
      expect(
        capabilities.capabilityFor(LinuxSystemOperation.journal7d),
        isNull,
      );
    });

    test('hasIssues is false only when every operation succeeded', () {
      for (final status in LinuxSystemOperationStatus.values) {
        final report = LinuxSystemCleanupReport(
          operations: [
            LinuxSystemOperationResult(
              operation: LinuxSystemOperation.dnfPackages,
              status: status,
              message: status.name,
            ),
          ],
        );

        expect(
          report.hasIssues,
          status != LinuxSystemOperationStatus.ok,
          reason: 'status ${status.name}',
        );
      }
    });

    test('exception renders its message and defaults to not cancelled', () {
      const exception = LinuxSystemMaintenanceException(
        'helper failed',
        code: 'helper_failed',
      );

      expect(exception.toString(), 'helper failed');
      expect(exception.cancelled, isFalse);
    });
  });

  group('probe', () {
    test('reports a missing helper without starting a process', () async {
      final runner = unusedRunner();
      await File(helperPath).delete();

      final availability = await clientFor(runner).probe();

      expect(availability.isAvailable, isFalse);
      expect(availability.reason, LinuxSystemUnavailableReason.helperMissing);
      expect(runner.calls, isEmpty);
    });

    test('reports a missing policy without starting a process', () async {
      final runner = unusedRunner();
      await File(policyPath).delete();

      final availability = await clientFor(runner).probe();

      expect(availability.reason, LinuxSystemUnavailableReason.policyMissing);
      expect(runner.calls, isEmpty);
    });

    test('reports missing pkexec without starting a process', () async {
      final runner = unusedRunner();
      await File(pkexecPath).delete();

      final availability = await clientFor(runner).probe();

      expect(availability.reason, LinuxSystemUnavailableReason.pkexecMissing);
      expect(runner.calls, isEmpty);
    });

    test('invokes the helper directly and parses capabilities', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(_capabilitiesJson()),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.isAvailable, isTrue);
      final capabilities = availability.capabilities!;
      expect(capabilities.helperVersion, '0.1.0');
      expect(capabilities.operations.map((entry) => entry.operation), [
        LinuxSystemOperation.aptCache,
        LinuxSystemOperation.dnfPackages,
        LinuxSystemOperation.journal7d,
      ]);
      expect(capabilities.operations.first.available, isTrue);
      expect(capabilities.operations.first.reason, isNull);
      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.executable, helperPath);
      expect(runner.calls.single.arguments, const ['--list', '--json']);
      expect(runner.calls.single.timeout, greaterThan(Duration.zero));
    });

    test('keeps unavailable operations and their reason', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _capabilitiesJson(
            operations: [
              _capability('apt-cache'),
              _capability(
                'dnf-packages',
                available: false,
                reason: 'tool_missing',
              ),
              _capability('journal-7d'),
            ],
          ),
        ),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.isAvailable, isTrue);
      final capabilities = availability.capabilities!;
      expect(
        capabilities.capabilityFor(LinuxSystemOperation.dnfPackages)!.available,
        isFalse,
      );
      expect(
        capabilities.capabilityFor(LinuxSystemOperation.dnfPackages)!.reason,
        'tool_missing',
      );
      expect(
        capabilities.capabilityFor(LinuxSystemOperation.aptCache)!.available,
        isTrue,
      );
      expect(
        capabilities.capabilityFor(LinuxSystemOperation.journal7d)!.available,
        isTrue,
      );
    });

    test('ignores unknown operations but requires the known ones', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _capabilitiesJson(
            operations: [
              _capability('apt-cache'),
              _capability('dnf-packages'),
              _capability(
                'pacman-cache',
                available: false,
                reason: 'tool_missing',
              ),
              _capability('journal-7d'),
            ],
          ),
        ),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.isAvailable, isTrue);
      expect(availability.capabilities!.operations, hasLength(3));
      expect(
        availability.capabilities!.capabilityFor(
          LinuxSystemOperation.dnfPackages,
        ),
        isNotNull,
      );
    });

    test('fails when a known operation is missing from the report', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _capabilitiesJson(
            operations: [_capability('apt-cache'), _capability('dnf-packages')],
          ),
        ),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.isAvailable, isFalse);
      expect(availability.reason, LinuxSystemUnavailableReason.helperFailed);
      expect(availability.detail, contains('journal-7d'));
    });

    test('fails on malformed JSON', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result('not json'),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.reason, LinuxSystemUnavailableReason.helperFailed);
      expect(availability.detail, contains('JSON'));
    });

    test('fails on an unsupported schema version', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _json({
            'schemaVersion': 2,
            'helperVersion': '0.1.0',
            'operations': const <Object?>[],
          }),
        ),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.reason, LinuxSystemUnavailableReason.helperFailed);
      expect(availability.detail, contains('schemaVersion'));
    });

    test('reports the helper stderr on a non-zero exit', () async {
      final runner = _FakeRunner(
        (executable, arguments) async =>
            _result('', exitCode: 70, stderr: 'probe failed'),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.reason, LinuxSystemUnavailableReason.helperFailed);
      expect(availability.detail, 'probe failed');
    });

    test('turns runner failures into an unavailable result', () async {
      final runner = _FakeRunner(
        (executable, arguments) async =>
            throw const LinuxSystemMaintenanceException(
              'spawn failed',
              code: 'process_error',
            ),
      );

      final availability = await clientFor(runner).probe();

      expect(availability.reason, LinuxSystemUnavailableReason.helperFailed);
      expect(availability.detail, 'spawn failed');
    });
  });

  group('selfTest', () {
    test('runs the helper directly and parses every check', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _selfTestJson(
            status: 'degraded',
            checks: [
              {'id': 'helper.install', 'status': 'pass', 'message': 'ready'},
              {'id': 'polkit.policy', 'status': 'warn', 'message': 'missing'},
            ],
          ),
        ),
      );

      final report = await clientFor(runner).selfTest();

      expect(report.status, LinuxSystemSelfTestStatus.degraded);
      expect(report.checks, hasLength(2));
      expect(report.checks.first.status, LinuxSystemSelfTestCheckStatus.pass);
      expect(report.checks.last.status, LinuxSystemSelfTestCheckStatus.warn);
      expect(runner.calls.single.executable, helperPath);
      expect(runner.calls.single.arguments, const ['--self-test', '--json']);
    });

    test('does not require the policy or pkexec', () async {
      await File(policyPath).delete();
      await File(pkexecPath).delete();
      final runner = _FakeRunner(
        (executable, arguments) async => _result(_selfTestJson()),
      );

      final report = await clientFor(runner).selfTest();

      expect(report.status, LinuxSystemSelfTestStatus.ok);
      expect(runner.calls.single.executable, helperPath);
      expect(runner.calls.single.arguments, const ['--self-test', '--json']);
    });

    test(
      'parses a failed report even when the helper exits non-zero',
      () async {
        final runner = _FakeRunner(
          (executable, arguments) async => _result(
            _selfTestJson(
              status: 'failed',
              checks: [
                {'id': 'helper.install', 'status': 'fail', 'message': 'unsafe'},
              ],
            ),
            exitCode: 70,
          ),
        );

        final report = await clientFor(runner).selfTest();

        expect(report.status, LinuxSystemSelfTestStatus.failed);
        expect(
          report.checks.single.status,
          LinuxSystemSelfTestCheckStatus.fail,
        );
      },
    );

    test('requires the helper before starting a process', () async {
      final runner = unusedRunner();
      await File(helperPath).delete();

      await expectLater(
        clientFor(runner).selfTest(),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'helper_missing',
          ),
        ),
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects malformed diagnostics', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result('{}'),
      );

      await expectLater(
        clientFor(runner).selfTest(),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });
  });

  group('clean', () {
    test('uses pkexec, fixed order and only operation ids', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _reportJson([
            _operationResult(
              'dnf-packages',
              'ok',
              exitCode: 0,
              freedBytes: 1024,
            ),
            _operationResult('journal-7d', 'ok', exitCode: 0, freedBytes: 2048),
          ]),
        ),
      );

      final report = await clientFor(runner).clean({
        LinuxSystemOperation.journal7d,
        LinuxSystemOperation.dnfPackages,
      });

      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.executable, pkexecPath);
      expect(runner.calls.single.arguments, [
        helperPath,
        '--run',
        'dnf-packages,journal-7d',
        '--json',
      ]);
      expect(report.hasIssues, isFalse);
      expect(report.operations.map((operation) => operation.operation), [
        LinuxSystemOperation.dnfPackages,
        LinuxSystemOperation.journal7d,
      ]);
      expect(report.operations.first.freedBytes, 1024);
    });

    test(
      'sends every selection in canonical apt, dnf, journal order',
      () async {
        final runner = _FakeRunner(
          (executable, arguments) async => _result(
            _reportJson([
              _operationResult('apt-cache', 'ok'),
              _operationResult('dnf-packages', 'ok'),
              _operationResult('journal-7d', 'ok'),
            ]),
          ),
        );

        await clientFor(runner).clean({
          LinuxSystemOperation.journal7d,
          LinuxSystemOperation.aptCache,
          LinuxSystemOperation.dnfPackages,
        });

        expect(runner.calls.single.arguments, [
          helperPath,
          '--run',
          'apt-cache,dnf-packages,journal-7d',
          '--json',
        ]);
      },
    );

    test('sends only the selected operation', () async {
      final runner = _FakeRunner(
        (executable, arguments) async =>
            _result(_reportJson([_operationResult('journal-7d', 'ok')])),
      );

      await clientFor(runner).clean({LinuxSystemOperation.journal7d});

      expect(runner.calls.single.arguments, [
        helperPath,
        '--run',
        'journal-7d',
        '--json',
      ]);
    });

    test('rejects an empty selection before starting a process', () async {
      final runner = unusedRunner();

      await expectLater(
        clientFor(runner).clean(<LinuxSystemOperation>{}),
        throwsArgumentError,
      );
      expect(runner.calls, isEmpty);
    });

    test(
      'requires the complete installation before starting a process',
      () async {
        final cases = <(String, String)>[
          (helperPath, 'helper_missing'),
          (policyPath, 'policy_missing'),
          (pkexecPath, 'pkexec_missing'),
        ];
        for (final (path, code) in cases) {
          for (final existing in [helperPath, policyPath, pkexecPath]) {
            await File(existing).writeAsString('test');
          }
          final runner = unusedRunner();
          await File(path).delete();

          await expectLater(
            clientFor(runner).clean({LinuxSystemOperation.dnfPackages}),
            throwsA(
              isA<LinuxSystemMaintenanceException>().having(
                (error) => error.code,
                'code',
                code,
              ),
            ),
          );
          expect(runner.calls, isEmpty);
        }
      },
    );

    test('maps dismissed authorization to a cancelled exception', () async {
      final runner = _FakeRunner(
        (executable, arguments) async =>
            _result('', exitCode: 126, stderr: 'dismissed'),
      );

      await expectLater(
        clientFor(runner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>()
              .having((error) => error.cancelled, 'cancelled', isTrue)
              .having((error) => error.code, 'code', 'authorization_cancelled'),
        ),
      );
    });

    test('maps failed authorization separately', () async {
      final runner = _FakeRunner(
        (executable, arguments) async =>
            _result('', exitCode: 127, stderr: 'not authorized'),
      );

      await expectLater(
        clientFor(runner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>()
              .having((error) => error.cancelled, 'cancelled', isFalse)
              .having((error) => error.code, 'code', 'authorization_failed'),
        ),
      );
    });

    test('surfaces the helper not_implemented error', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _errorJson('not_implemented', 'not available yet', 69),
          exitCode: 69,
        ),
      );

      await expectLater(
        clientFor(runner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>()
              .having((error) => error.code, 'code', 'not_implemented')
              .having((error) => error.message, 'message', 'not available yet'),
        ),
      );
    });

    test('falls back to stderr for an unparseable failure', () async {
      final runner = _FakeRunner(
        (executable, arguments) async =>
            _result('', exitCode: 1, stderr: 'dnf exploded'),
      );

      await expectLater(
        clientFor(runner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>()
              .having((error) => error.code, 'code', 'helper_failed')
              .having((error) => error.message, 'message', 'dnf exploded'),
        ),
      );
    });

    test('preserves partial operation failures', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result(
          _reportJson([
            _operationResult(
              'dnf-packages',
              'failed',
              exitCode: 1,
              message: 'dnf is locked',
            ),
            _operationResult('journal-7d', 'ok', freedBytes: 512),
          ]),
        ),
      );

      final report = await clientFor(runner).clean({
        LinuxSystemOperation.dnfPackages,
        LinuxSystemOperation.journal7d,
      });

      expect(report.hasIssues, isTrue);
      expect(report.operations.first.status, LinuxSystemOperationStatus.failed);
      expect(report.operations.first.message, 'dnf is locked');
      expect(report.operations.last.status, LinuxSystemOperationStatus.ok);
    });

    test('rejects a report that omits a requested operation', () async {
      final runner = _FakeRunner(
        (executable, arguments) async =>
            _result(_reportJson([_operationResult('dnf-packages', 'ok')])),
      );

      await expectLater(
        clientFor(runner).clean({
          LinuxSystemOperation.dnfPackages,
          LinuxSystemOperation.journal7d,
        }),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('rejects duplicate and unknown result entries', () async {
      final duplicateRunner = _FakeRunner(
        (executable, arguments) async => _result(
          _reportJson([
            _operationResult('dnf-packages', 'ok'),
            _operationResult('dnf-packages', 'ok'),
          ]),
        ),
      );
      await expectLater(
        clientFor(duplicateRunner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );

      final unknownRunner = _FakeRunner(
        (executable, arguments) async => _result(
          _reportJson([
            _operationResult('dnf-packages', 'ok'),
            _operationResult('pacman-cache', 'ok'),
          ]),
        ),
      );
      await expectLater(
        clientFor(unknownRunner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('rejects an unknown status and negative freed bytes', () async {
      final statusRunner = _FakeRunner(
        (executable, arguments) async =>
            _result(_reportJson([_operationResult('dnf-packages', 'mystery')])),
      );
      await expectLater(
        clientFor(statusRunner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );

      final bytesRunner = _FakeRunner(
        (executable, arguments) async => _result(
          _reportJson([_operationResult('dnf-packages', 'ok', freedBytes: -1)]),
        ),
      );
      await expectLater(
        clientFor(bytesRunner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('maps every run status and accepts nullable fields', () async {
      const statuses = {
        'ok': LinuxSystemOperationStatus.ok,
        'failed': LinuxSystemOperationStatus.failed,
        'busy': LinuxSystemOperationStatus.busy,
        'skipped': LinuxSystemOperationStatus.skipped,
        'unavailable': LinuxSystemOperationStatus.unavailable,
      };
      for (final entry in statuses.entries) {
        final runner = _FakeRunner(
          (executable, arguments) async => _result(
            _reportJson([_operationResult('dnf-packages', entry.key)]),
          ),
        );

        final report = await clientFor(runner)
            .clean({LinuxSystemOperation.dnfPackages});

        final result = report.operations.single;
        expect(result.status, entry.value, reason: entry.key);
        expect(result.exitCode, isNull);
        expect(result.freedBytes, isNull);
        expect(result.message, 'done');
      }
    });

    test('rejects malformed success output', () async {
      final runner = _FakeRunner(
        (executable, arguments) async => _result('not json'),
      );

      await expectLater(
        clientFor(runner).clean({LinuxSystemOperation.dnfPackages}),
        throwsA(
          isA<LinuxSystemMaintenanceException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });
  });

  group('createLinuxSystemMaintenance', () {
    test('returns null when a prerequisite is missing', () {
      final client = createLinuxSystemMaintenance(
        helperPath: p.join(temp.path, 'missing-helper'),
        policyPath: p.join(temp.path, 'missing-policy'),
        pkexecPath: p.join(temp.path, 'missing-pkexec'),
      );

      expect(client, isNull);
    });

    test('requires Linux even when all files exist', () {
      final client = createLinuxSystemMaintenance(
        helperPath: helperPath,
        policyPath: policyPath,
        pkexecPath: pkexecPath,
      );

      if (Platform.isLinux) {
        expect(client, isA<PkexecLinuxSystemMaintenance>());
      } else {
        expect(client, isNull);
      }
    });

    test('checks each prerequisite independently', () {
      final clients = [
        createLinuxSystemMaintenance(
          helperPath: p.join(temp.path, 'missing-helper'),
          policyPath: policyPath,
          pkexecPath: pkexecPath,
        ),
        createLinuxSystemMaintenance(
          helperPath: helperPath,
          policyPath: p.join(temp.path, 'missing-policy'),
          pkexecPath: pkexecPath,
        ),
        createLinuxSystemMaintenance(
          helperPath: helperPath,
          policyPath: policyPath,
          pkexecPath: p.join(temp.path, 'missing-pkexec'),
        ),
      ];

      expect(clients, everyElement(isNull));
    }, skip: Platform.isLinux ? false : 'Linux only');
  });
}
