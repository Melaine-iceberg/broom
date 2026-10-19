import 'dart:io';

import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryFileSystem fs;

  setUp(() {
    fs = MemoryFileSystem();
  });

  test('treats paths case-insensitively and lists direct children', () async {
    fs.seedFile(r'C:\Cache\A\one.tmp', contents: 'alpha');
    fs.seedFile(r'C:\Cache\A\two.log', contents: 'bravo');
    fs.seedDirectory(r'C:\Cache\B');

    expect(await fs.type(r'c:\cache\a\ONE.TMP'), FsEntityType.file);
    expect(await fs.type(r'C:\Cache\missing'), FsEntityType.notFound);
    expect(
      await fs.type(r'C:\Cache\A'),
      FsEntityType.directory,
      reason: 'seedFile should create parent directories',
    );

    final children = await fs.list(r'C:\Cache\A').toList();
    expect(children.map((entry) => entry.path.toLowerCase()), [
      r'c:\cache\a\one.tmp',
      r'c:\cache\a\two.log',
    ]);

    final stat = await fs.stat(r'C:\Cache\A\one.tmp');
    expect(stat.type, FsEntityType.file);
    expect(stat.size, 5);
  });

  test('reads, writes and appends without touching a real disk', () async {
    fs.seedFile(r'C:\Logs\app.log', contents: 'first\n');

    await fs.writeString(r'C:\Logs\app.log', 'second\n', append: true);
    expect(await fs.readString(r'C:\Logs\app.log'), 'first\nsecond\n');
    expect(await fs.length(r'C:\Logs\app.log'), 13);

    final writer = await fs.openAppend(r'C:\Logs\app.log');
    expect(await writer.position(), 13);
    await writer.writeString('third\n');
    await writer.flush();
    await writer.close();
    expect(await fs.readString(r'C:\Logs\app.log'), 'first\nsecond\nthird\n');

    final rewritten = await fs.openWrite(r'C:\Logs\app.log');
    await rewritten.writeString('reset');
    await rewritten.close();
    expect(await fs.readString(r'C:\Logs\app.log'), 'reset');
  });

  test(
    'writes journal entries and rolls back to the previous position',
    () async {
      fs.seedFile(r'C:\Journal\entries.jsonl', contents: 'kept\n');
      final writer = await fs.openAppend(r'C:\Journal\entries.jsonl');
      final start = await writer.position();
      await writer.writeString('discarded\n');
      await writer.flush();
      await writer.truncate(start);
      await writer.setPosition(start);
      await writer.close();

      expect(await fs.readLines(r'C:\Journal\entries.jsonl'), ['kept']);
    },
  );

  test('renames a file and an entire directory tree', () async {
    fs.seedFile(r'C:\Root\one.tmp', contents: '1');
    fs.seedFile(r'C:\Root\Nested\two.tmp', contents: '22');

    await fs.rename(r'C:\Root\one.tmp', r'C:\Root\renamed.tmp');
    expect(await fs.readString(r'C:\Root\renamed.tmp'), '1');
    expect(await fs.type(r'C:\Root\one.tmp'), FsEntityType.notFound);

    await fs.rename(r'C:\Root\Nested', r'C:\Root\Moved');
    expect(await fs.readString(r'C:\Root\Moved\two.tmp'), '22');
    expect(await fs.list(r'C:\Root\Moved').length, 1);

    final moved = await fs.openAppend(r'C:\Root\Moved\two.tmp');
    expect(await moved.position(), 2);
    await moved.close();
  });

  test(
    'refuses path traversal, conflicting targets and missing parents',
    () async {
      fs.seedFile(r'C:\Root\kept.tmp', contents: 'x');
      await fs.createDirectory(r'C:\Root\folder');

      await expectLater(
        fs.rename(r'C:\Root\kept.tmp', r'C:\Root\folder'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.rename(r'C:\Root\kept.tmp', r'C:\Missing\kept.tmp'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.writeString(r'C:\Missing\new.tmp', 'x'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.rename(r'C:\Root', r'C:\Root\Nested'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await fs.readString(r'C:\Root\kept.tmp'), 'x');
    },
  );

  test('supports read-only files and recursive deletion', () async {
    fs.seedFile(r'C:\Root\readonly.tmp', contents: 'x', readOnly: true);
    fs.seedFile(r'C:\Root\Nested\child.tmp', contents: 'y');

    expect((await fs.stat(r'C:\Root\readonly.tmp')).mode & 1, 1);
    await expectLater(
      fs.deleteFile(r'C:\Root\readonly.tmp'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      fs.deleteDirectory(r'C:\Root'),
      throwsA(isA<FileSystemException>()),
    );

    await fs.deleteDirectory(r'C:\Root', recursive: true);
    expect(await fs.type(r'C:\Root'), FsEntityType.notFound);
    expect(await fs.type(r'C:\Root\Nested\child.tmp'), FsEntityType.notFound);
  });

  test(
    'runs operation hooks for ordering barriers and failure injection',
    () async {
      final operations = <String>[];
      fs.onOperation = (operation, path) => operations.add('$operation:$path');

      await fs.type(r'C:\Hook\file.tmp');
      await expectLater(
        fs.readString(r'C:\Hook\file.tmp'),
        throwsA(isA<FileSystemException>()),
      );
      expect(operations, [
        r'type:C:\Hook\file.tmp',
        r'readString:C:\Hook\file.tmp',
      ]);
    },
  );
}
