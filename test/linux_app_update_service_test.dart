import 'dart:convert';

import 'package:broom/core/app/app_update_service.dart';
import 'package:broom/core/app/linux_app_update_service.dart';
import 'package:broom/core/platform/app_version.dart';
import 'package:broom/ui/app_update_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _manifest({
  Object? version = '0.5.0',
  Object? url = 'https://example.com/broom-0.5.0-linux-x64.tar.gz',
  Object? hash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  Object? schemaVersion = 1,
}) {
  return {
    'schemaVersion': schemaVersion,
    'version': version,
    'publishedAt': '2026-10-24T12:00:00Z',
    'url': url,
    'sha256': hash,
  };
}

void main() {
  group('LinuxAppUpdateService', () {
    test('parses a newer release and its download URL', () async {
      final service = LinuxAppUpdateService(
        currentVersion: AppVersion.parse('0.4.0'),
        fetcher: (uri) async {
          expect(uri.scheme, 'https');
          return jsonEncode(_manifest());
        },
      );

      final info = await service.check(
        Uri.parse('https://example.com/broom-linux.json'),
      );

      expect(info.hasUpdate, isTrue);
      expect(info.latestVersion.toString(), '0.5.0.0');
      expect(
        info.packageUri.toString(),
        'https://example.com/broom-0.5.0-linux-x64.tar.gz',
      );
    });

    test('reports no update for the current version', () async {
      final service = LinuxAppUpdateService(
        currentVersion: AppVersion.parse('0.5.0'),
        fetcher: (uri) async => jsonEncode(_manifest()),
      );

      final info = await service.check(
        Uri.parse('https://example.com/broom-linux.json'),
      );
      expect(info.hasUpdate, isFalse);
    });

    test('rejects plain HTTP feeds', () async {
      final service = LinuxAppUpdateService(
        currentVersion: AppVersion.parse('0.4.0'),
        fetcher: (uri) async => jsonEncode(_manifest()),
      );

      expect(
        () => service.check(Uri.parse('http://example.com/broom-linux.json')),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('HTTPS'),
          ),
        ),
      );
    });

    test('rejects malformed manifests', () {
      final feed = Uri.parse('https://example.com/broom-linux.json');
      final current = AppVersion.parse('0.4.0');
      final cases = <String>[
        'not json',
        '[]',
        jsonEncode(_manifest(schemaVersion: 2)),
        jsonEncode(_manifest(version: '')),
        jsonEncode(_manifest(version: 'latest')),
        jsonEncode(_manifest(url: 'http://example.com/broom.tar.gz')),
        jsonEncode(_manifest(hash: 'abc')),
        jsonEncode({..._manifest(), 'artifacts': 'appimage'}),
      ];

      for (final body in cases) {
        expect(
          () => LinuxAppUpdateService.parseManifest(
            body,
            feed: feed,
            currentVersion: current,
          ),
          throwsA(isA<AppUpdateException>()),
          reason: body,
        );
      }
    });

    test('keeps the manifest hash and per-format artifacts', () {
      final base = _manifest();
      final info = LinuxAppUpdateService.parseManifest(
        jsonEncode({
          ...base,
          'artifacts': [
            {
              'format': 'appimage',
              'file': 'broom-0.5.0-linux-x64.AppImage',
              'url': 'https://example.com/broom-0.5.0-linux-x64.AppImage',
              'sha256':
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            },
            {
              'format': 'deb',
              'file': 'broom_0.5.0_amd64.deb',
              'url': 'http://example.com/broom_0.5.0_amd64.deb',
              'sha256':
                  'cccccccccccccccccccccccccccccccc'
                  'cccccccccccccccccccccccccccccccc',
            },
            {
              'format': 'rpm',
              'file': 'broom-0.5.0.x86_64.rpm',
              'url': 'https://example.com/broom-0.5.0.x86_64.rpm',
            },
            {
              'format': 'appimage',
              'file': 'broom-linux-x64',
              'url': 'https://example.com/download/broom-linux-x64',
              'sha256':
                  'dddddddddddddddddddddddddddddddd'
                  'dddddddddddddddddddddddddddddddd',
            },
          ],
        }),
        feed: Uri.parse('https://example.com/broom-linux.json'),
        currentVersion: AppVersion.parse('0.4.0'),
      );

      expect(info.sha256, base['sha256']);
      expect(info.artifacts, hasLength(3));
      expect(info.artifacts.first.format, LinuxUpdateArtifactFormat.appImage);
      expect(info.artifacts.first.fileName, 'broom-0.5.0-linux-x64.AppImage');
      expect(info.artifacts[1].format, LinuxUpdateArtifactFormat.rpm);
      expect(info.artifacts[1].sha256, isNull);
      expect(info.artifacts.last.format, LinuxUpdateArtifactFormat.appImage);
    });

    test('maps package file names to artifact formats', () {
      expect(
        LinuxAppUpdateService.formatForFileName('broom.AppImage'),
        LinuxUpdateArtifactFormat.appImage,
      );
      expect(
        LinuxAppUpdateService.formatForFileName('broom_0.5.0_amd64.deb'),
        LinuxUpdateArtifactFormat.deb,
      );
      expect(
        LinuxAppUpdateService.formatForFileName('broom-0.5.0.x86_64.rpm'),
        LinuxUpdateArtifactFormat.rpm,
      );
      expect(
        LinuxAppUpdateService.formatForFileName('broom-0.5.0-linux-x64.tar.gz'),
        LinuxUpdateArtifactFormat.tarball,
      );
      expect(
        LinuxAppUpdateService.formatForFileName('broom.zip'),
        LinuxUpdateArtifactFormat.unknown,
      );
    });
  });

  group('AppUpdateController Linux distribution', () {
    test('uses the Linux manifest and reports a manual upgrade', () async {
      final controller = AppUpdateController(
        versionSource: const StaticAppVersion('0.4.0'),
        distribution: AppUpdateDistribution.linuxPackage,
        fetcher: (uri) async => jsonEncode(_manifest()),
      );
      addTearDown(controller.dispose);

      await controller.check();

      expect(controller.error, isNull);
      expect(controller.usesWindowsInstaller, isFalse);
      expect(controller.feedUrl, contains('broom-linux.json'));
      expect(controller.notice, contains('发行版包管理器'));
      expect(controller.info?.packageUri, isNotNull);
    });
  });
}
