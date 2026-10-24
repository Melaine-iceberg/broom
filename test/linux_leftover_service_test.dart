import 'dart:io';

import 'package:broom/core/leftover/leftover_service.dart';
import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/platform/installed_apps.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_exclusions.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeInstalledApps implements InstalledApps {
  _FakeInstalledApps(this.inventory);

  InstalledAppInventory inventory;

  @override
  Future<InstalledAppInventory> list() async => inventory;
}

LeftoverCatalogEntry _entry() {
  return const LeftoverCatalogEntry(
    id: 'linux-example',
    appName: 'Example',
    appNameEn: 'Example',
    description: '示例',
    descriptionEn: 'Example',
    dataPathPatterns: [r'$XDG_CONFIG_HOME/Example'],
    installMarkerPatterns: [r'$HOME/.local/share/flatpak/app/org.example.App'],
    installDisplayNamePrefixes: ['Example'],
    installPackageIds: ['example'],
  );
}

final _linuxOnly = !Platform.isLinux;

void main() {
  late Directory temp;
  late Map<String, String> environment;
  late _FakeInstalledApps installedApps;
  late PathGuard guard;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_linux_leftover_');
    environment = {
      'HOME': temp.path,
      'XDG_CONFIG_HOME': p.join(temp.path, '.config'),
      'XDG_CACHE_HOME': p.join(temp.path, '.cache'),
      'XDG_DATA_HOME': p.join(temp.path, '.local', 'share'),
    };
    installedApps = _FakeInstalledApps(
      const InstalledAppInventory(apps: [], complete: true),
    );
    guard = PathGuard.forPosix();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  LeftoverService service({
    List<LeftoverCatalogEntry>? entries,
    PathExclusionSource exclusions = const EmptyPathExclusionSource(),
  }) {
    return LeftoverService(
      installedApps: installedApps,
      guard: guard,
      exclusions: exclusions,
      entries: entries ?? [_entry()],
      environment: environment,
      semantics: const PosixPathSemantics(),
    );
  }

  String dataPath() => p.join(environment['XDG_CONFIG_HOME']!, 'Example');

  String markerPath() => p.join(
    environment['HOME']!,
    '.local',
    'share',
    'flatpak',
    'app',
    'org.example.App',
  );

  test('detects XDG data when the package is absent', () async {
    await Directory(dataPath()).create(recursive: true);

    final detection = await service().detect();

    expect(detection.error, isNull);
    expect(detection.candidates, hasLength(1));
    expect(detection.candidates.single.paths, [dataPath()]);
  }, skip: _linuxOnly);

  test('skips data when the package inventory contains the app id', () async {
    await Directory(dataPath()).create(recursive: true);
    installedApps.inventory = const InstalledAppInventory(
      apps: [
        InstalledApp(displayName: 'example', uninstallKey: 'dpkg:example'),
      ],
      complete: true,
    );

    expect((await service().detect()).candidates, isEmpty);
  }, skip: _linuxOnly);

  test('skips data when a flatpak marker exists', () async {
    await Directory(dataPath()).create(recursive: true);
    await Directory(markerPath()).create(recursive: true);

    expect((await service().detect()).candidates, isEmpty);
  }, skip: _linuxOnly);

  test('applies exclusions to XDG data paths', () async {
    await Directory(dataPath()).create(recursive: true);

    final detection = await service(exclusions: PathExclusions([dataPath()]))
        .detect();

    expect(detection.candidates, isEmpty);
  }, skip: _linuxOnly);

  test('fails closed when the package inventory is incomplete', () async {
    await Directory(dataPath()).create(recursive: true);
    installedApps.inventory = const InstalledAppInventory(
      apps: [],
      complete: false,
      error: 'rpm failed',
    );

    final detection = await service().detect();

    expect(detection.candidates, isEmpty);
    expect(detection.error, contains('rpm failed'));
  }, skip: _linuxOnly);

  test('revalidate drops apps that are installed again', () async {
    await Directory(dataPath()).create(recursive: true);
    expect(
      (await service().revalidate(['leftover.linux-example'])).orphanedRuleIds,
      {'leftover.linux-example'},
    );

    installedApps.inventory = const InstalledAppInventory(
      apps: [
        InstalledApp(displayName: 'example', uninstallKey: 'snap:example'),
      ],
      complete: true,
    );
    expect(
      (await service().revalidate(['leftover.linux-example'])).orphanedRuleIds,
      isEmpty,
    );
  }, skip: _linuxOnly);
}
