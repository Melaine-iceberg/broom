import 'dart:io';

import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/platform/linux_installed_apps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeLinuxProcesses {
  final calls = <String>[];
  final outputs = <String, ProcessResult>{};

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add('$executable ${arguments.join(' ')}');
    return outputs[executable] ??
        ProcessResult(1, 0, '', 'missing fake output');
  }
}

void main() {
  late Directory temp;
  late Map<String, String> environment;
  late _FakeLinuxProcesses processes;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_linux_apps_');
    final dataHome = p.join(temp.path, 'data');
    final systemData = p.join(temp.path, 'system');
    environment = {
      'HOME': temp.path,
      'XDG_DATA_HOME': dataHome,
      'XDG_DATA_DIRS': systemData,
    };
    processes = _FakeLinuxProcesses();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  LinuxInstalledApps service(Set<String> available) {
    return LinuxInstalledApps(
      environment: environment,
      runner: processes.run,
      availableExecutables: available,
    );
  }

  test('parses dpkg, flatpak and snap package inventories', () async {
    processes.outputs['/usr/bin/dpkg-query'] = ProcessResult(
      1,
      0,
      'ii \tSlack\t4.0.0\n'
          'ii \tlibgtk-3-0\t3.24\n'
          'rc \tremoved-package\t1.0\n',
      '',
    );
    processes.outputs['/usr/bin/flatpak'] = ProcessResult(
      1,
      0,
      'com.spotify.Client\tSpotify\tflathub\n',
      '',
    );
    processes.outputs['/usr/bin/snap'] = ProcessResult(
      1,
      0,
      'Name Version Rev Tracking Publisher Notes\n'
          'code 1.0 1 latest vscode - \n',
      '',
    );

    final inventory = await service({
      '/usr/bin/dpkg-query',
      '/usr/bin/flatpak',
      '/usr/bin/snap',
    }).list();

    expect(inventory.complete, isTrue);
    final keys = inventory.apps.map((app) => app.uninstallKey).toSet();
    expect(keys, containsAll(['dpkg:Slack', 'dpkg:libgtk-3-0']));
    expect(keys, isNot(contains('dpkg:removed-package')));
    expect(keys, contains('flatpak:com.spotify.Client'));
    expect(keys, contains('snap:code'));
  });

  test('parses desktop entries and marks user scope', () async {
    final applications = Directory(
      p.join(environment['XDG_DATA_HOME']!, 'applications'),
    );
    await applications.create(recursive: true);
    await File(p.join(applications.path, 'code.desktop')).writeAsString(
      '[Desktop Entry]\n'
      'Name=Visual Studio Code\n'
      'Exec=code\n'
      'X-Flatpak=com.visualstudio.code\n',
    );

    final inventory = await service(const {}).list();

    expect(inventory.complete, isTrue);
    final app = inventory.apps.single;
    expect(app.displayName, 'Visual Studio Code');
    expect(app.uninstallKey, 'flatpak:com.visualstudio.code');
    expect(app.scope, InstalledAppScope.user);
  });

  test('fails closed when an available package manager fails', () async {
    processes.outputs['/usr/bin/dpkg-query'] = ProcessResult(
      1,
      1,
      '',
      'database is locked',
    );

    final inventory = await service({'/usr/bin/dpkg-query'}).list();

    expect(inventory.complete, isFalse);
    expect(inventory.error, contains('dpkg-query'));
    expect(inventory.error, contains('database is locked'));
  });

  test('ignores package managers that are not installed', () async {
    final inventory = await service(const {}).list();

    expect(inventory.complete, isTrue);
    expect(inventory.apps, isEmpty);
    expect(processes.calls, isEmpty);
  });

  test('rejects unparseable package output', () async {
    processes.outputs['/usr/bin/dpkg-query'] = ProcessResult(
      1,
      0,
      'broken\n',
      '',
    );

    final inventory = await service({'/usr/bin/dpkg-query'}).list();

    expect(inventory.complete, isFalse);
    expect(inventory.error, contains('dpkg-query'));
  });
}
