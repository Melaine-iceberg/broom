import 'dart:io';

import 'package:broom/core/leftover/leftover_service.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/platform/installed_apps.dart';
import 'package:broom/core/safety/path_exclusions.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

LeftoverCatalogEntry _entry({
  List<String> dataPaths = const [r'%APPDATA%\Example'],
  List<String> markers = const [r'%LOCALAPPDATA%\Example\app.exe'],
}) {
  return LeftoverCatalogEntry(
    id: 'example',
    appName: 'Example',
    appNameEn: 'Example',
    description: 'Example 的本地数据。',
    descriptionEn: 'Example local data.',
    dataPathPatterns: dataPaths,
    installMarkerPatterns: markers,
    installDisplayNamePrefixes: const ['Example'],
  );
}

class _FakeInstalledApps implements InstalledApps {
  _FakeInstalledApps(this.inventory);

  InstalledAppInventory inventory;
  int calls = 0;

  @override
  Future<InstalledAppInventory> list() async {
    calls++;
    return inventory;
  }
}

final _windowsOnly = !Platform.isWindows;

void main() {
  late Directory tempRoot;
  late Map<String, String> environment;
  late _FakeInstalledApps installedApps;
  late PathGuard guard;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('broom_leftover_test_');
    final roaming = await Directory(p.join(tempRoot.path, 'Roaming'))
        .create(recursive: true);
    final local = await Directory(p.join(tempRoot.path, 'Local'))
        .create(recursive: true);
    final programFiles = await Directory(p.join(tempRoot.path, 'ProgramFiles'))
        .create(recursive: true);
    environment = {
      'APPDATA': roaming.path,
      'LOCALAPPDATA': local.path,
      'PROGRAMFILES': programFiles.path,
    };
    installedApps = _FakeInstalledApps(
      const InstalledAppInventory(apps: [], complete: true),
    );
    guard = PathGuard(protectedRoots: [programFiles.path]);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  String appDataPath() => p.join(environment['APPDATA']!, 'Example');

  String markerPath() =>
      p.join(environment['LOCALAPPDATA']!, 'Example', 'app.exe');

  LeftoverService service({
    List<LeftoverCatalogEntry>? entries,
    PathGuard? pathGuard,
    PathExclusionSource exclusions = const EmptyPathExclusionSource(),
  }) {
    return LeftoverService(
      installedApps: installedApps,
      guard: pathGuard ?? guard,
      exclusions: exclusions,
      entries: entries ?? [_entry()],
      environment: environment,
    );
  }

  test('detects data when the application is absent', () async {
    await Directory(appDataPath()).create(recursive: true);

    final detection = await service().detect();

    expect(detection.error, isNull);
    expect(detection.candidates, hasLength(1));
    final candidate = detection.candidates.single;
    expect(candidate.entry.id, 'example');
    expect(candidate.paths, [PathGuard.normalize(appDataPath())]);
    expect(candidate.evidence, contains('Example'));
    expect(candidate.evidenceEn, contains('Example'));
  }, skip: _windowsOnly);

  test('skips applications present in the inventory by name prefix', () async {
    await Directory(appDataPath()).create(recursive: true);
    installedApps.inventory = const InstalledAppInventory(
      apps: [InstalledApp(displayName: 'example app 1.0')],
      complete: true,
    );

    expect((await service().detect()).candidates, isEmpty);
  });

  test('skips applications with an existing install marker file', () async {
    await Directory(appDataPath()).create(recursive: true);
    final marker = File(markerPath());
    await marker.parent.create(recursive: true);
    await marker.writeAsString('');

    expect((await service().detect()).candidates, isEmpty);
  });

  test('skips applications with a matching wildcard install marker', () async {
    await Directory(appDataPath()).create(recursive: true);
    await Directory(
      p.join(environment['LOCALAPPDATA']!, 'Example', 'app-1.2.3'),
    ).create(recursive: true);

    final detection = await service(
      entries: [
        _entry(markers: [r'%LOCALAPPDATA%\Example\app-*']),
      ],
    ).detect();

    expect(detection.candidates, isEmpty);
  });

  test('ignores entries without an existing data directory', () async {
    expect((await service().detect()).candidates, isEmpty);
  });

  test('ignores data paths with unavailable environment variables', () async {
    final detection = await service(
      entries: [
        _entry(dataPaths: [r'%MISSING_ROOT%\Example']),
      ],
    ).detect();

    expect(detection.candidates, isEmpty);
    expect(detection.error, isNull);
  });

  test('applies user exclusions to candidate data paths', () async {
    await Directory(appDataPath()).create(recursive: true);
    final detection = await service(exclusions: PathExclusions([appDataPath()]))
        .detect();

    expect(detection.candidates, isEmpty);
  });

  test('applies protected roots to candidate data paths', () async {
    await Directory(appDataPath()).create(recursive: true);
    final protectedGuard = PathGuard(protectedRoots: [appDataPath()]);
    final detection = await service(pathGuard: protectedGuard).detect();

    expect(detection.candidates, isEmpty);
  });

  test('fails closed when the inventory is incomplete', () async {
    await Directory(appDataPath()).create(recursive: true);
    installedApps.inventory = const InstalledAppInventory(
      apps: [],
      complete: false,
      error: 'inventory failed',
    );

    final detection = await service().detect();

    expect(detection.candidates, isEmpty);
    expect(detection.error, contains('inventory failed'));

    installedApps.inventory = const InstalledAppInventory(
      apps: [],
      complete: false,
    );
    final fallback = await service().detect();
    expect(fallback.candidates, isEmpty);
    expect(fallback.error, isNotNull);
  });

  test('builds a review rule from a candidate', () {
    final candidate = LeftoverCandidate(
      entry: _entry(),
      paths: [PathGuard.normalize(appDataPath())],
      evidence: '判断依据',
      evidenceEn: 'Evidence',
    );

    final rule = leftoverRuleFor(candidate);

    expect(rule.id, 'leftover.example');
    expect(rule.risk, CleanRisk.review);
    expect(rule.category, '卸载残留');
    expect(rule.categoryEn, 'Uninstall leftovers');
    expect(rule.title, contains('卸载残留'));
    expect(rule.titleEn, contains('leftovers'));
    expect(rule.pathPatterns, candidate.paths);
    expect(rule.note, '判断依据');
    expect(rule.noteEn, 'Evidence');
    expect(rule.audit, isNull);
    expect(rule.extensions, isNull);
    expect(rule.minAge, Duration.zero);
  });

  test(
    'revalidate keeps absent applications and ignores unknown ids',
    () async {
      final validation = await service().revalidate([
        'leftover.example',
        'leftover.unknown',
      ]);

      expect(validation.error, isNull);
      expect(validation.orphanedRuleIds, {'leftover.example'});
    },
  );

  test('revalidate drops applications installed again', () async {
    installedApps.inventory = const InstalledAppInventory(
      apps: [InstalledApp(displayName: 'Example')],
      complete: true,
    );

    final validation = await service().revalidate(['leftover.example']);

    expect(validation.orphanedRuleIds, isEmpty);
  });

  test('revalidate detects a new install marker', () async {
    final marker = File(markerPath());
    await marker.parent.create(recursive: true);
    await marker.writeAsString('');

    final validation = await service().revalidate(['leftover.example']);

    expect(validation.orphanedRuleIds, isEmpty);
  }, skip: _windowsOnly);

  test('revalidate fails closed when the inventory is incomplete', () async {
    installedApps.inventory = const InstalledAppInventory(
      apps: [],
      complete: false,
      error: 'inventory failed',
    );

    final validation = await service().revalidate(['leftover.example']);

    expect(validation.orphanedRuleIds, isEmpty);
    expect(validation.error, contains('inventory failed'));
  });

  test('revalidate skips the inventory when no ids are requested', () async {
    final validation = await service().revalidate(const <String>[]);

    expect(validation.orphanedRuleIds, isEmpty);
    expect(installedApps.calls, 0);
  });
}
