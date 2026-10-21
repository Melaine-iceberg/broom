import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/platform/installed_apps.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const installedApps = MethodChannelInstalledApps();
  const channel = MethodChannelInstalledApps.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('list decodes the native inventory', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object?>{
        'complete': true,
        'apps': <Object?>[
          <String, Object?>{
            'displayName': 'Slack',
            'publisher': 'Salesforce',
            'installLocation': r'C:\Users\tester\AppData\Local\slack',
            'uninstallKey': r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Slack',
            'scope': 'user',
          },
          <String, Object?>{'displayName': 'Discord', 'scope': 'machine'},
        ],
      };
    });

    final inventory = await installedApps.list();

    expect(received?.method, 'list');
    expect(inventory.complete, isTrue);
    expect(inventory.error, isNull);
    expect(inventory.apps, hasLength(2));
    expect(inventory.apps.first.displayName, 'Slack');
    expect(inventory.apps.first.publisher, 'Salesforce');
    expect(inventory.apps.first.scope, InstalledAppScope.user);
    expect(inventory.apps.first.uninstallKey, contains('Uninstall'));
    expect(inventory.apps.last.displayName, 'Discord');
    expect(inventory.apps.last.publisher, isNull);
    expect(inventory.apps.last.scope, InstalledAppScope.machine);
  });

  test('unknown scopes are retained as unknown', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'complete': true,
        'apps': <Object?>[
          <String, Object?>{'displayName': 'Portable app', 'scope': 'other'},
        ],
      };
    });

    final inventory = await installedApps.list();

    expect(inventory.apps.single.scope, InstalledAppScope.unknown);
  });

  test('incomplete inventories keep the native error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'complete': false,
        'apps': <Object?>[],
        'error': 'Failed to read HKLM (Windows error 5)',
      };
    });

    final inventory = await installedApps.list();

    expect(inventory.complete, isFalse);
    expect(inventory.apps, isEmpty);
    expect(inventory.error, contains('Windows error 5'));
  });

  test('an error flag forces an incomplete inventory', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'complete': true,
        'apps': <Object?>[],
        'error': 'partial inventory',
      };
    });

    expect((await installedApps.list()).complete, isFalse);
  });

  test('malformed payloads are rejected', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => 'nope');
    await expectLater(
      installedApps.list(),
      throwsA(isA<InstalledAppsException>()),
    );

    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{'complete': true, 'apps': 'nope'};
    });
    await expectLater(
      installedApps.list(),
      throwsA(isA<InstalledAppsException>()),
    );

    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'complete': true,
        'apps': <Object?>['nope'],
      };
    });
    await expectLater(
      installedApps.list(),
      throwsA(isA<InstalledAppsException>()),
    );

    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'complete': true,
        'apps': <Object?>[
          <String, Object?>{'displayName': '  '},
        ],
      };
    });
    await expectLater(
      installedApps.list(),
      throwsA(isA<InstalledAppsException>()),
    );
  });

  test('native failures map to InstalledAppsException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'registry_failed',
        message: 'Registry access failed.',
        details: 5,
      );
    });

    await expectLater(
      installedApps.list(),
      throwsA(
        isA<InstalledAppsException>().having(
          (error) => error.message,
          'message',
          allOf(contains('Registry access failed.'), contains('0x00000005')),
        ),
      ),
    );
  });

  test('missing native support maps to InstalledAppsException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });

    await expectLater(
      installedApps.list(),
      throwsA(
        isA<InstalledAppsException>().having(
          (error) => error.message,
          'message',
          contains('不支持'),
        ),
      ),
    );
  });

  test('unsupported platform returns an incomplete inventory', () async {
    const unsupported = UnsupportedInstalledApps();
    final inventory = await unsupported.list();

    expect(inventory.complete, isFalse);
    expect(inventory.apps, isEmpty);
    expect(inventory.error, isNotNull);
  });
}
