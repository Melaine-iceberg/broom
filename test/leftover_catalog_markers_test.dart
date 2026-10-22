import 'dart:io';

import 'package:broom/core/leftover/leftover_service.dart';
import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/platform/installed_apps.dart';
import 'package:broom/core/rules/leftover_catalog.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeInstalledApps implements InstalledApps {
  _FakeInstalledApps(this.inventory);

  InstalledAppInventory inventory;

  @override
  Future<InstalledAppInventory> list() async => inventory;
}

/// Exercises every curated catalog entry against a synthetic `AppData` tree.
///
/// The catalog is allowed to grow without a live installation, so the safety
/// property that matters most is checked for each entry: an entry that still
/// has any install marker present must never be reported as a leftover.
void main() {
  late Directory tempRoot;
  late Map<String, String> environment;
  late _FakeInstalledApps installedApps;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('broom_catalog_test_');
    final roaming = await Directory(p.join(tempRoot.path, 'Roaming'))
        .create(recursive: true);
    final local = await Directory(p.join(tempRoot.path, 'Local'))
        .create(recursive: true);
    final programFiles = await Directory(
      p.join(tempRoot.path, 'ProgramFiles'),
    ).create(recursive: true);
    environment = {
      'appdata': roaming.path,
      'localappdata': local.path,
      'programfiles': programFiles.path,
    };
    installedApps = _FakeInstalledApps(
      const InstalledAppInventory(apps: [], complete: true),
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  String expand(String pattern) => pattern.replaceAllMapped(
    RegExp(r'%([^%]+)%'),
    (match) => environment[match.group(1)!.toLowerCase()] ?? '',
  );

  LeftoverService service(LeftoverCatalogEntry entry) => LeftoverService(
    installedApps: installedApps,
    guard: PathGuard(protectedRoots: const []),
    entries: [entry],
    environment: environment,
  );

  Future<String> create(String path) async {
    final parent = Directory(p.windows.dirname(path));
    await parent.create(recursive: true);
    if (path.split(RegExp(r'[\\/]')).last.contains('*')) {
      final leaf = path
          .split(RegExp(r'[\\/]'))
          .last
          .replaceAll(RegExp(r'[*?]'), '1');
      final dir = Directory(p.join(p.windows.dirname(path), leaf));
      await dir.create(recursive: true);
      return dir.path;
    }
    final file = File(path);
    await file.create(recursive: true);
    return file.path;
  }

  Future<void> remove(String path) async {
    if (await FileSystemEntity.isDirectory(path)) {
      await Directory(path).delete(recursive: true);
    } else if (await FileSystemEntity.isFile(path)) {
      await File(path).delete();
    }
  }

  for (final entry in LeftoverCatalog.entries) {
    group(entry.id, () {
      test('is detected when only local data remains', () async {
        final dataPaths = [
          for (final pattern in entry.dataPathPatterns) expand(pattern),
        ];
        for (final path in dataPaths) {
          await Directory(path).create(recursive: true);
        }

        final detection = await service(entry).detect();

        expect(detection.error, isNull);
        expect(detection.candidates, hasLength(1));
        expect(detection.candidates.single.entry.id, entry.id);
        expect(detection.candidates.single.paths, [
          PathGuard.normalize(dataPaths.first),
        ]);
      });

      test('any single install marker suppresses detection', () async {
        final dataPath = expand(entry.dataPathPatterns.first);
        await Directory(dataPath).create(recursive: true);

        for (final marker in entry.installMarkerPatterns) {
          final created = await create(expand(marker));
          final detection = await service(entry).detect();
          expect(
            detection.candidates,
            isEmpty,
            reason: '安装标记存在时不得判定为残留：$marker',
          );
          await remove(created);
        }
      });

      test('a registry display name suppresses detection', () async {
        final dataPath = expand(entry.dataPathPatterns.first);
        await Directory(dataPath).create(recursive: true);
        installedApps.inventory = InstalledAppInventory(
          apps: [
            InstalledApp(
              displayName: '${entry.installDisplayNamePrefixes.first} 1.0',
            ),
          ],
          complete: true,
        );

        final detection = await service(entry).detect();

        expect(detection.candidates, isEmpty);
      });

      test('an unreadable inventory suppresses detection', () async {
        final dataPath = expand(entry.dataPathPatterns.first);
        await Directory(dataPath).create(recursive: true);
        installedApps.inventory = const InstalledAppInventory(
          apps: [],
          complete: false,
        );

        final detection = await service(entry).detect();

        expect(detection.candidates, isEmpty);
        expect(detection.error, isNotNull);
      });
    });
  }
}
