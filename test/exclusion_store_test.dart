import 'dart:convert';
import 'dart:io';

import 'package:broom/core/safety/path_exclusions.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_exclusions_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<Directory> createDirectory(String name) async {
    final directory = Directory(p.windows.join(temp.path, name));
    await directory.create(recursive: true);
    return directory;
  }

  ExclusionStore createStore() => ExclusionStore(
    filePath: p.windows.join(temp.path, 'config', 'exclusions.json'),
  );

  test('persists normalized paths across reloads', () async {
    final keep = await createDirectory('keep');
    final store = createStore();
    await store.ensureLoaded();
    expect(store.paths, isEmpty);

    await store.add('${keep.path}${p.windows.separator}');
    expect(store.paths, [PathGuard.normalize(keep.path)]);
    expect(
      store.excludes(p.windows.join(keep.path, 'nested', 'file.tmp')),
      isTrue,
    );

    final reloaded = createStore();
    await reloaded.ensureLoaded();
    expect(reloaded.paths, [PathGuard.normalize(keep.path)]);

    final raw = jsonDecode(
      await File(store.filePath).readAsString(),
    ) as Map<String, dynamic>;
    expect(raw['schemaVersion'], 1);
    expect(raw['paths'], [PathGuard.normalize(keep.path)]);
  });

  test('matches descendants case-insensitively without prefix leaks', () {
    final exclusions = PathExclusions([r'C:\Temp\Cache']);

    expect(exclusions.excludes(r'C:\Temp\Cache'), isTrue);
    expect(exclusions.excludes(r'C:\Temp\Cache\file.tmp'), isTrue);
    expect(exclusions.excludes(r'c:\temp\cache\FILE.TMP'), isTrue);
    expect(exclusions.excludes(r'C:\Temp\Cache2\file.tmp'), isFalse);
    expect(exclusions.excludes(r'C:\Temp'), isFalse);

    expect(exclusions.intersects(r'C:\Temp'), isTrue);
    expect(exclusions.intersects(r'C:\Temp\Cache\sub'), isTrue);
    expect(exclusions.intersects(r'C:\Temp\Cache2'), isFalse);
  });

  test('rejects invalid, duplicate, and overlapping paths', () async {
    final keep = await createDirectory('keep');
    final child = await createDirectory(p.windows.join('keep', 'child'));
    final other = await createDirectory('other');
    final file = File(p.windows.join(temp.path, 'file.txt'));
    await file.writeAsString('x');

    final store = createStore();
    await store.ensureLoaded();

    await expectLater(
      store.add(r'relative\path'),
      throwsA(isA<ExclusionException>()),
    );
    await expectLater(store.add(file.path), throwsA(isA<ExclusionException>()));
    await expectLater(store.add('C:\\'), throwsA(isA<ExclusionException>()));
    await expectLater(
      store.add(p.windows.join(temp.path, 'missing')),
      throwsA(isA<ExclusionException>()),
    );

    await store.add(keep.path);
    await expectLater(store.add(keep.path), throwsA(isA<ExclusionException>()));
    await expectLater(
      store.add(child.path),
      throwsA(isA<ExclusionException>()),
    );
    expect(store.paths, hasLength(1));

    await store.add(other.path);
    expect(store.paths, hasLength(2));

    await store.remove(keep.path);
    expect(store.paths, [PathGuard.normalize(other.path)]);
  });

  test('loads persisted paths even when the folder is gone', () async {
    final store = createStore();
    final missing = p.windows.join(temp.path, 'already-deleted');
    await File(store.filePath).parent.create(recursive: true);
    await File(store.filePath).writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'paths': [missing],
      }),
    );

    await store.ensureLoaded();

    expect(store.paths, [PathGuard.normalize(missing)]);
  });

  test('blocks corrupted configuration and can reset it', () async {
    final store = createStore();
    await File(store.filePath).parent.create(recursive: true);
    await File(store.filePath).writeAsString('{not-json');

    await expectLater(store.ensureLoaded(), throwsA(isA<FormatException>()));
    expect(store.isLoaded, isFalse);
    expect(store.loadError, contains('排除列表'));

    await store.reset();
    expect(store.isLoaded, isTrue);
    expect(store.loadError, isNull);
    expect(store.paths, isEmpty);

    final reloaded = createStore();
    await reloaded.ensureLoaded();
    expect(reloaded.paths, isEmpty);
  });

  test('refuses unknown schema versions', () async {
    final store = createStore();
    await File(store.filePath).parent.create(recursive: true);
    await File(store.filePath)
        .writeAsString(jsonEncode({'schemaVersion': 99, 'paths': <String>[]}));

    await expectLater(store.ensureLoaded(), throwsA(isA<FormatException>()));
    expect(store.loadError, contains('不支持的排除列表版本'));
  });
}
