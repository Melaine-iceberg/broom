import 'dart:io';
import 'dart:typed_data';

import 'package:broom/core/platform/directory_enum.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('broom/directory_enum_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('decodes names, sizes, timestamps and entry types', () async {
    final modified = DateTime.utc(2026, 10, 19, 12, 30);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listDirectory');
      expect((call.arguments as Map)['path'], r'C:\cache');
      return <String, Object>{
        'names': <String>['a.tmp', 'sub', 'junction'],
        'sizes': Int64List.fromList([1024, 0, 0]),
        'modified': Int64List.fromList([modified.microsecondsSinceEpoch, 0, 0]),
        // Plain file, directory, reparse point.
        'attributes': Int32List.fromList([0x80, 0x10, 0x400]),
      };
    });

    final entries = await MethodChannelDirectoryEnumerator(channel: channel)
        .list(r'C:\cache');

    expect(entries, isNotNull);
    expect(entries!.map((entry) => entry.name), ['a.tmp', 'sub', 'junction']);
    expect(entries[0].type, FsEntityType.file);
    expect(entries[0].size, 1024);
    expect(entries[0].modified.toUtc(), modified);
    expect(entries[1].type, FsEntityType.directory);
    expect(entries[2].type, FsEntityType.link);
  });

  test('decodes the Linux type column', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object>{
        'names': <String>['file.tmp', 'sub', 'link'],
        'sizes': <int>[12, 0, 0],
        'modified': <int>[1000000, 0, 0],
        // Linux kinds: regular file, directory, symbolic link.
        'types': <int>[0, 1, 2],
      };
    });

    final entries = await MethodChannelDirectoryEnumerator(channel: channel)
        .list('/home/broom/.cache');

    expect(entries, isNotNull);
    expect(entries!.map((entry) => entry.type), [
      FsEntityType.file,
      FsEntityType.directory,
      FsEntityType.link,
    ]);
  });

  test(
    'maps a directory failure to a FileSystemException with the Win32 code',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'win32', message: '拒绝访问。', details: 5);
      });

      await expectLater(
        MethodChannelDirectoryEnumerator(channel: channel).list(r'C:\blocked'),
        throwsA(
          isA<FileSystemException>()
              .having((error) => error.osError?.errorCode, 'errorCode', 5)
              .having((error) => error.path, 'path', r'C:\blocked'),
        ),
      );
    },
  );

  test('returns null when the channel is not implemented', () async {
    final entries = await MethodChannelDirectoryEnumerator(
      channel: const MethodChannel('broom/directory_enum_absent'),
    ).list(r'C:\cache');
    expect(entries, isNull);
  });

  test('probe asks the native side once and caches the answer', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'ping');
      return true;
    });

    final enumerator = MethodChannelDirectoryEnumerator(channel: channel);
    expect(await enumerator.probe(), isTrue);
    expect(await enumerator.probe(), isTrue);
    expect(calls, 1);
    expect(enumerator.isAvailable, isTrue);
  });

  test('probe reports unavailable when the channel is missing', () async {
    final enumerator = MethodChannelDirectoryEnumerator(
      channel: const MethodChannel('broom/directory_enum_absent'),
    );
    expect(await enumerator.probe(), isFalse);
    expect(enumerator.isAvailable, isFalse);
    // A rejected probe disables the fast path for later calls too.
    expect(await enumerator.list(r'C:\cache'), isNull);
  });

  test(
    'rejects a malformed response instead of returning wrong sizes',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object>{
          'names': <String>['a.tmp'],
          'sizes': Int64List(0),
          'modified': Int64List(0),
          'attributes': Int32List(0),
        };
      });

      await expectLater(
        MethodChannelDirectoryEnumerator(channel: channel).list(r'C:\cache'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
