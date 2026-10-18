import 'package:broom/core/shell/system_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shell = MethodChannelSystemShell();
  const channel = MethodChannelSystemShell.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('queryRecycleBin decodes the native snapshot', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object>{'itemCount': 12, 'totalBytes': 34567};
    });

    final snapshot = await shell.queryRecycleBin();

    expect(received?.method, 'queryRecycleBin');
    expect(snapshot.itemCount, 12);
    expect(snapshot.totalBytes, 34567);
    expect(snapshot.isEmpty, isFalse);
  });

  test('queryRecycleBin surfaces Windows error codes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'queryRecycleBin',
        message: 'Windows shell error',
        details: 5,
      );
    });

    await expectLater(
      shell.queryRecycleBin(),
      throwsA(
        isA<SystemShellException>()
            .having((error) => error.message, 'message', contains('0x00000005'))
            .having((error) => error.code, 'code', 'queryRecycleBin'),
      ),
    );
  });

  test('queryRecycleBin rejects malformed payloads', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object>{'itemCount': 'many', 'totalBytes': 1};
    });

    await expectLater(
      shell.queryRecycleBin(),
      throwsA(isA<SystemShellException>()),
    );
  });

  test('emptyRecycleBin invokes the native method', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'emptyRecycleBin');
      calls++;
      return null;
    });

    await shell.emptyRecycleBin();

    expect(calls, 1);
  });

  test(
    'pickFolder forwards the initial directory and maps cancellation',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return '';
      });

      final cancelled = await shell.pickFolder(
        initialDirectory: r'C:\Users\Alice\Downloads',
      );

      expect(cancelled, isNull);
      expect(calls.single.method, 'pickFolder');
      expect(calls.single.arguments, <String, Object>{
        'initialDirectory': r'C:\Users\Alice\Downloads',
      });

      messenger.setMockMethodCallHandler(channel, (call) async {
        return r'C:\Users\Alice\Pictures';
      });
      expect(await shell.pickFolder(), r'C:\Users\Alice\Pictures');
    },
  );

  test('revealPath forwards the path', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await shell.revealPath(r'C:\Users\Alice\file.bin');

    expect(received?.method, 'revealPath');
    expect(received?.arguments, <String, Object>{
      'path': r'C:\Users\Alice\file.bin',
    });
  });

  test('unsupported shell rejects every operation', () async {
    const unsupported = UnsupportedSystemShell();

    await expectLater(
      unsupported.queryRecycleBin(),
      throwsA(isA<SystemShellException>()),
    );
    await expectLater(
      unsupported.emptyRecycleBin(),
      throwsA(isA<SystemShellException>()),
    );
    await expectLater(
      unsupported.pickFolder(),
      throwsA(isA<SystemShellException>()),
    );
    await expectLater(
      unsupported.revealPath(r'C:\x'),
      throwsA(isA<SystemShellException>()),
    );
  });
}
