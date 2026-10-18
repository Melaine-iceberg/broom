import 'package:broom/core/platform/system_access.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const access = MethodChannelSystemAccess();
  const channel = MethodChannelSystemAccess.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('isElevated decodes the native state', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });

    expect(await access.isElevated(), isTrue);
    expect(received?.method, 'isElevated');
  });

  test('isElevated maps Windows error codes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'isElevated',
        message: 'Windows API call failed.',
        details: 5,
      );
    });

    await expectLater(
      access.isElevated(),
      throwsA(
        isA<SystemAccessException>()
            .having((error) => error.message, 'message', contains('0x00000005'))
            .having((error) => error.code, 'code', 'isElevated'),
      ),
    );
  });

  test('isElevated reports missing native support', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });

    await expectLater(
      access.isElevated(),
      throwsA(
        isA<SystemAccessException>().having(
          (error) => error.message,
          'message',
          contains('不支持'),
        ),
      ),
    );
  });

  test('relaunchElevated maps a cancelled UAC prompt to false', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      throw PlatformException(
        code: 'elevation_cancelled',
        message: 'The user cancelled the UAC prompt.',
      );
    });

    expect(await access.relaunchElevated(), isFalse);
    expect(received?.method, 'relaunchElevated');
  });

  test('relaunchElevated surfaces other native failures', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'elevation_failed',
        message: 'ShellExecuteEx failed.',
        details: 2,
      );
    });

    await expectLater(
      access.relaunchElevated(),
      throwsA(
        isA<SystemAccessException>()
            .having((error) => error.message, 'message', contains('0x00000002'))
            .having((error) => error.code, 'code', 'elevation_failed'),
      ),
    );
  });

  test('locateSystemCacheRoots decodes the native payload', () async {
    const windowsUpdate = r'C:\Windows\SoftwareDistribution\Download';
    const deliveryOptimization =
        r'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache';
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object>{
        'windowsUpdate': windowsUpdate,
        'deliveryOptimization': deliveryOptimization,
      };
    });

    final roots = await access.locateSystemCacheRoots();

    expect(received?.method, 'systemCacheRoots');
    expect(roots.windowsUpdateDownload, windowsUpdate);
    expect(roots.deliveryOptimizationCache, deliveryOptimization);
  });

  test('locateSystemCacheRoots rejects malformed payloads', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object>{'windowsUpdate': 5};
    });

    await expectLater(
      access.locateSystemCacheRoots(),
      throwsA(isA<SystemAccessException>()),
    );

    messenger.setMockMethodCallHandler(channel, (call) async => 'nope');

    await expectLater(
      access.locateSystemCacheRoots(),
      throwsA(isA<SystemAccessException>()),
    );
  });

  test('unsupported access rejects native operations', () async {
    const unsupported = UnsupportedSystemAccess();

    expect(await unsupported.isElevated(), isFalse);
    await expectLater(
      unsupported.locateSystemCacheRoots(),
      throwsA(isA<SystemAccessException>()),
    );
    await expectLater(
      unsupported.relaunchElevated(),
      throwsA(isA<SystemAccessException>()),
    );
  });
}
