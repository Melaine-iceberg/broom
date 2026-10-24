import 'dart:convert';

import 'package:broom/core/clean/file_metadata.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = PosixFileMetadataAccess.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final modified = DateTime.utc(2026, 1, 2, 3, 4, 5);
  final accessed = DateTime.utc(2026, 1, 3, 3, 4, 5);
  final stat = FsStat(
    type: FsEntityType.file,
    size: 42,
    modified: modified,
    accessed: accessed,
    mode: 0x1A4, // 0o644
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('does not touch the platform channel for a same-volume move', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      fail('unexpected ${call.method}');
    });

    final metadata = await const PosixFileMetadataAccess().read(
      '/home/broom/cache/a.tmp',
      stat: stat,
      captureAcl: false,
    );

    expect(metadata, isNotNull);
    expect(metadata!.mode, 0x1A4);
    expect(metadata.modified, modified);
    expect(metadata.accessed, accessed);
    expect(metadata.readOnly, isFalse);
    expect(metadata.uid, isNull);
    expect(metadata.gid, isNull);
    expect(metadata.xattrs, isEmpty);
  });

  test('captures ownership, birth time and extended attributes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readPosixMetadata');
      expect((call.arguments as Map)['path'], '/home/broom/cache/a.tmp');
      return <String, Object>{
        'createdMicros': DateTime.utc(2020, 1, 1).microsecondsSinceEpoch,
        'uid': 1000,
        'gid': 1001,
        'xattrs': <String, Object>{
          'user.test': Uint8List.fromList([1, 2, 3]),
          'security.selinux': Uint8List.fromList(utf8.encode('label')),
        },
      };
    });

    final metadata = await const PosixFileMetadataAccess().read(
      '/home/broom/cache/a.tmp',
      stat: stat,
      captureAcl: true,
    );

    expect(metadata, isNotNull);
    expect(metadata!.uid, 1000);
    expect(metadata.gid, 1001);
    expect(metadata.created, DateTime.utc(2020, 1, 1));
    expect(base64Decode(metadata.xattrs['user.test']!), [1, 2, 3]);
    expect(
      utf8.decode(base64Decode(metadata.xattrs['security.selinux']!)),
      'label',
    );
    expect(metadata.extendedUnavailable, isFalse);
  });

  test(
    'keeps the basic values when extended metadata cannot be read',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'stat_failed', message: 'denied');
      });

      final metadata = await const PosixFileMetadataAccess().read(
        '/home/broom/cache/a.tmp',
        stat: stat,
        captureAcl: true,
      );

      expect(metadata, isNotNull);
      expect(metadata!.mode, 0x1A4);
      expect(metadata.modified, modified);
      expect(metadata.extendedUnavailable, isTrue);
    },
  );

  test('applies ownership, mode, xattrs and timestamps', () async {
    Map<Object?, Object?>? arguments;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'applyPosixMetadata');
      arguments = call.arguments as Map<Object?, Object?>;
      return null;
    });

    await const PosixFileMetadataAccess().apply(
      '/home/broom/cache/a.tmp',
      FileMetadata(
        uid: 1000,
        gid: 1001,
        mode: 0x1A4,
        modified: modified,
        accessed: accessed,
        xattrs: {
          'user.test': base64Encode([4, 5, 6]),
        },
      ),
    );

    expect(arguments?['uid'], 1000);
    expect(arguments?['gid'], 1001);
    expect(arguments?['mode'], 0x1A4);
    expect(arguments?['modifiedMicros'], modified.microsecondsSinceEpoch);
    expect(arguments?['accessedMicros'], accessed.microsecondsSinceEpoch);
    final xattrs = arguments?['xattrs'] as Map<Object?, Object?>;
    expect(xattrs['user.test'], [4, 5, 6]);
  });

  test('apply fails closed when the channel is unavailable', () async {
    await expectLater(
      const PosixFileMetadataAccess().apply(
        '/home/broom/cache/a.tmp',
        const FileMetadata(mode: 0x1A4),
      ),
      throwsA(isA<FileMetadataException>()),
    );
  });
}
