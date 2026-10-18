import 'dart:io';

import 'package:broom/core/clean/system_services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSc {
  _FakeSc(Map<String, int> states) : states = Map.of(states);

  final Map<String, int> states;
  final List<List<String>> invocations = [];
  final Set<String> failingStops = {};
  final Set<String> failingStarts = {};
  bool settlePendingStops = true;

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    expect(executable, 'sc.exe');
    invocations.add(arguments);
    final command = arguments.first;
    final name = arguments.length > 1 ? arguments[1] : '';

    switch (command) {
      case 'query':
        final state = states[name];
        if (state == null) {
          return ProcessResult(1, 1060, '', '[SC] OpenService FAILED 1060:');
        }
        if (state == 3 && settlePendingStops) {
          states[name] = 1;
        }
        return ProcessResult(
          0,
          0,
          'SERVICE_NAME: $name\n'
              '        TYPE : 20  WIN32_SHARE_PROCESS\n'
              '        STATE              : $state  STATE_$state\n',
          '',
        );
      case 'stop':
        if (failingStops.contains(name)) {
          return ProcessResult(1, 5, '', 'Access is denied.');
        }
        if (!states.containsKey(name)) {
          return ProcessResult(1, 1060, '', '');
        }
        states[name] = 1;
        return ProcessResult(0, 0, '', '');
      case 'start':
        if (failingStarts.contains(name)) {
          return ProcessResult(1, 1058, '', 'The service cannot be started.');
        }
        if (!states.containsKey(name)) {
          return ProcessResult(1, 1060, '', '');
        }
        if (states[name] == 4) {
          return ProcessResult(1, 1056, '', 'Service already running.');
        }
        states[name] = 4;
        return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(1, 1, '', 'Unsupported command.');
  }

  Iterable<List<String>> calls(String command) =>
      invocations.where((arguments) => arguments.first == command);
}

void main() {
  test('stops running services once and restarts the stopped ones', () async {
    final sc = _FakeSc({'wuauserv': 4, 'bits': 4});
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    final stopped = await manager.stopServices([
      'wuauserv',
      'bits',
      'wuauserv',
    ]);

    expect(stopped, {'wuauserv', 'bits'});
    expect(sc.calls('stop'), hasLength(2));
    expect(sc.states.values, everyElement(1));

    final issues = await manager.startServices(stopped);

    expect(issues, isEmpty);
    expect(sc.states.values, everyElement(4));
    expect(sc.calls('start'), hasLength(2));
  });

  test('skips services that are already stopped or absent', () async {
    final sc = _FakeSc({'wuauserv': 1});
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    final stopped = await manager.stopServices(['wuauserv', 'bits']);

    expect(stopped, isEmpty);
    expect(sc.calls('stop'), isEmpty);
  });

  test('treats a pending stop that settles as stopped', () async {
    final sc = _FakeSc({'wuauserv': 3});
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    final stopped = await manager.stopServices(['wuauserv']);

    expect(stopped, {'wuauserv'});
    expect(sc.calls('stop'), isEmpty);
    expect(sc.states['wuauserv'], 1);
  });

  test('rolls back already stopped services when a later stop fails', () async {
    final sc = _FakeSc({'wuauserv': 4, 'bits': 4})..failingStops.add('bits');
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    await expectLater(
      manager.stopServices(['wuauserv', 'bits']),
      throwsA(
        isA<ServiceControlException>()
            .having((error) => error.serviceName, 'serviceName', 'bits')
            .having((error) => error.message, 'message', contains('没有访问权限')),
      ),
    );

    expect(sc.states['wuauserv'], 4);
    expect(
      sc.calls('start').where((arguments) => arguments[1] == 'wuauserv'),
      hasLength(1),
    );
  });

  test('reports stopped services that cannot be restored', () async {
    final sc = _FakeSc({'wuauserv': 4, 'bits': 4})
      ..failingStops.add('bits')
      ..failingStarts.add('wuauserv');
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    await expectLater(
      manager.stopServices(['wuauserv', 'bits']),
      throwsA(
        isA<ServiceControlException>().having(
          (error) => error.message,
          'message',
          contains('已停止的服务无法恢复'),
        ),
      ),
    );
  });

  test('times out when a service stays in stop pending', () async {
    final sc = _FakeSc({'wuauserv': 3})..settlePendingStops = false;
    final manager = WindowsServiceManager(
      runner: sc.run,
      stopTimeout: const Duration(milliseconds: 60),
      pollInterval: const Duration(milliseconds: 1),
    );

    await expectLater(
      manager.stopServices(['wuauserv']),
      throwsA(
        isA<ServiceControlException>().having(
          (error) => error.message,
          'message',
          contains('限定时间'),
        ),
      ),
    );
  });

  test('returns issues for services that cannot be started', () async {
    final sc = _FakeSc({'wuauserv': 1})..failingStarts.add('wuauserv');
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    final issues = await manager.startServices(['wuauserv']);

    expect(issues.single, contains('服务已被禁用'));
  });

  test('ignores already running services when starting', () async {
    final sc = _FakeSc({'wuauserv': 4});
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    expect(await manager.startServices(['wuauserv']), isEmpty);
  });

  test('rejects unsafe service names', () async {
    final sc = _FakeSc({'wuauserv': 4});
    final manager = WindowsServiceManager(
      runner: sc.run,
      pollInterval: Duration.zero,
    );

    await expectLater(
      manager.stopServices(['wuauserv & calc.exe']),
      throwsArgumentError,
    );
    expect(sc.invocations, isEmpty);
  });
}
