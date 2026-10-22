import 'dart:io';

import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/windows_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// Verifies the native `FindFirstFileW` enumerator inside the real runner.
///
/// Everything here depends on the platform channel, so it only runs with
/// `flutter test integration_test/directory_enum_test.dart -d windows`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const fileSystem = IoFileSystem();

  testWidgets('returns names, sizes and timestamps from one enumeration', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('broom_enum_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File(p.join(temp.path, 'a.tmp'));
    await file.writeAsString('hello');
    await Directory(p.join(temp.path, 'nested')).create();

    final entries = await (fileSystem as DetailedDirectoryListing)
        .listDetailed(temp.path)
        .toList();
    final byName = {
      for (final entry in entries) entry.name.toLowerCase(): entry,
    };

    expect(byName.keys, containsAll(<String>['a.tmp', 'nested']));
    expect(byName['a.tmp']!.type, FsEntityType.file);
    expect(byName['a.tmp']!.size, 5);
    expect(byName['nested']!.type, FsEntityType.directory);
    expect(
      byName['a.tmp']!.modified
          .difference(File(file.path).lastModifiedSync())
          .inSeconds
          .abs(),
      lessThan(5),
    );
  });

  testWidgets('reports an empty directory as empty, not as an error', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('broom_enum_empty_');
    addTearDown(() => temp.delete(recursive: true));

    final entries = await (fileSystem as DetailedDirectoryListing)
        .listDetailed(temp.path)
        .toList();
    expect(entries, isEmpty);
  });

  testWidgets('surfaces a missing directory as a FileSystemException', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('broom_enum_missing_');
    final missing = p.join(temp.path, 'absent');
    await temp.delete(recursive: true);

    await expectLater(
      (fileSystem as DetailedDirectoryListing).listDetailed(missing).toList(),
      throwsA(isA<FileSystemException>()),
    );
  });

  testWidgets('enumerates paths longer than MAX_PATH', (tester) async {
    final temp = await Directory.systemTemp.createTemp('broom_enum_long_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    // 3 x 120 characters keeps the full path well past MAX_PATH (260).
    final deep = p.join(
      temp.path,
      List<String>.filled(3, 'd' * 120).join(p.windows.separator),
    );
    await Directory(WindowsPath.extended(deep)).create(recursive: true);
    await File(WindowsPath.extended(p.join(deep, 'deep.tmp')))
        .writeAsString('deep');

    final entries = await (fileSystem as DetailedDirectoryListing)
        .listDetailed(deep)
        .toList();
    expect(entries.map((entry) => entry.name), ['deep.tmp']);
    expect(entries.single.size, 4);
  });
}
