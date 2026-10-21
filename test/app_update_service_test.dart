import 'package:broom/core/app/app_update_service.dart';
import 'package:broom/core/platform/app_version.dart';
import 'package:broom/ui/app_update_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const _feed = '''<?xml version="1.0" encoding="utf-8"?>
<AppInstaller Uri="https://example.com/broom/broom.appinstaller" Version="0.5.0.0" xmlns="http://schemas.microsoft.com/appx/appinstaller/2021">
  <MainPackage Name="Broom" Version="0.5.0.0" Publisher="CN=Broom" ProcessorArchitecture="x64" Uri="https://example.com/broom/broom_0.5.0.0_x64.msix" />
  <UpdateSettings>
    <OnLaunch HoursBetweenUpdateChecks="0" ShowPrompt="false" UpdateBlocksActivation="false" />
  </UpdateSettings>
</AppInstaller>
''';

void main() {
  group('AppVersion', () {
    test('parses the MSIX four-part form', () {
      final version = AppVersion.parse('0.4.0.4');
      expect(version.toString(), '0.4.0.4');
    });

    test('parses the pubspec build suffix', () {
      expect(AppVersion.parse('0.4.0+4').toString(), '0.4.0.4');
    });

    test('pads missing parts', () {
      expect(AppVersion.parse('1.2').toString(), '1.2.0.0');
      expect(AppVersion.parse('1.2.3').toString(), '1.2.3.0');
    });

    test('compares numerically, not lexicographically', () {
      expect(
        AppVersion.parse('0.4.0.10') > AppVersion.parse('0.4.0.9'),
        isTrue,
      );
      expect(
        AppVersion.parse('0.10.0.0') > AppVersion.parse('0.9.9.9'),
        isTrue,
      );
      expect(
        AppVersion.parse('0.4.0.4') > AppVersion.parse('0.4.0.4'),
        isFalse,
      );
    });

    test('rejects malformed input', () {
      for (final raw in ['', 'v1.0.0.0', '1.2.3.4.5', '1.2.-3.4', '1.2.x.4']) {
        expect(
          () => AppVersion.parse(raw),
          throwsA(isA<FormatException>()),
          reason: raw,
        );
      }
    });
  });

  group('AppUpdateService', () {
    test('reports a newer version and the package URI', () async {
      final service = AppUpdateService(
        currentVersion: AppVersion.parse('0.4.0.4'),
        fetcher: (uri) async {
          expect(uri.scheme, 'https');
          return _feed;
        },
      );
      final info = await service.check(Uri.parse('https://example.com/feed'));
      expect(info.hasUpdate, isTrue);
      expect(info.latestVersion.toString(), '0.5.0.0');
      expect(info.currentVersion.toString(), '0.4.0.4');
      expect(info.packageUri.toString(), endsWith('broom_0.5.0.0_x64.msix'));
    });

    test('reports no update for the same version', () async {
      final service = AppUpdateService(
        currentVersion: AppVersion.parse('0.5.0.0'),
        fetcher: (uri) async => _feed,
      );
      final info = await service.check(Uri.parse('https://example.com/feed'));
      expect(info.hasUpdate, isFalse);
    });

    test('rejects a plain HTTP feed', () async {
      final service = AppUpdateService(
        currentVersion: AppVersion.parse('0.4.0.4'),
        fetcher: (uri) async => _feed,
      );
      expect(
        () => service.check(Uri.parse('http://example.com/feed')),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('HTTPS'),
          ),
        ),
      );
    });

    test('rejects documents without a version', () {
      expect(
        () => AppUpdateService.parseFeed(
          '<AppInstaller Uri="https://example.com/feed"></AppInstaller>',
          feed: Uri.parse('https://example.com/feed'),
          currentVersion: AppVersion.parse('0.4.0.4'),
        ),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('rejects non-feed content', () {
      expect(
        () => AppUpdateService.parseFeed(
          '<html><body>404</body></html>',
          feed: Uri.parse('https://example.com/feed'),
          currentVersion: AppVersion.parse('0.4.0.4'),
        ),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('rejects entity declarations', () {
      const hostile = '''<?xml version="1.0"?>
<!DOCTYPE AppInstaller [<!ENTITY x "y">]>
<AppInstaller Version="0.5.0.0" />''';
      expect(
        () => AppUpdateService.parseFeed(
          hostile,
          feed: Uri.parse('https://example.com/feed'),
          currentVersion: AppVersion.parse('0.4.0.4'),
        ),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('rejects a malformed version string', () {
      expect(
        () => AppUpdateService.parseFeed(
          '<AppInstaller Version="latest" />',
          feed: Uri.parse('https://example.com/feed'),
          currentVersion: AppVersion.parse('0.4.0.4'),
        ),
        throwsA(isA<AppUpdateException>()),
      );
    });
  });

  group('AppUpdateController', () {
    test('reports the newest version as a notice', () async {
      final controller = AppUpdateController(
        versionSource: const StaticAppVersion('0.4.0+4'),
        fetcher: (uri) async => _feed,
      );
      addTearDown(controller.dispose);

      await controller.loadVersion();
      expect(controller.currentVersion, '0.4.0.4');

      await controller.check();
      expect(controller.error, isNull);
      expect(controller.notice, contains('0.5.0.0'));
      expect(controller.info?.hasUpdate, isTrue);
    });

    test('surfaces a readable error when the version is unavailable', () async {
      final controller = AppUpdateController(
        versionSource: const StaticAppVersion(null),
        fetcher: (uri) async => _feed,
      );
      addTearDown(controller.dispose);

      await controller.check();
      expect(controller.error, isNotNull);
      expect(controller.busy, isFalse);
    });

    test('surfaces fetch errors without throwing', () async {
      final controller = AppUpdateController(
        versionSource: const StaticAppVersion('0.4.0.4'),
        fetcher: (uri) async => throw const AppUpdateException('离线'),
      );
      addTearDown(controller.dispose);

      await controller.check();
      expect(controller.error, '离线');
    });
  });
}
