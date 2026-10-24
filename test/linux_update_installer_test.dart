import 'dart:convert';
import 'dart:io';

import 'package:broom/core/app/app_update_service.dart';
import 'package:broom/core/app/linux_app_update_service.dart';
import 'package:broom/core/app/linux_update_installer.dart';
import 'package:broom/core/platform/app_version.dart';
import 'package:broom/ui/app_update_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _zeroHash =
    '0000000000000000000000000000000000000000000000000000000000000000';

LinuxUpdateArtifact _artifact({
  LinuxUpdateArtifactFormat format = LinuxUpdateArtifactFormat.appImage,
  String? sha256,
  String fileName = 'broom-0.5.0.AppImage',
  String url = 'https://example.com/broom-0.5.0.AppImage',
}) {
  return LinuxUpdateArtifact(
    format: format,
    fileName: fileName,
    uri: Uri.parse(url),
    sha256: sha256,
  );
}

LinuxAppUpdateInfo _info({
  Uri? packageUri,
  String? sha256,
  List<LinuxUpdateArtifact> artifacts = const [],
}) {
  return LinuxAppUpdateInfo(
    currentVersion: AppVersion.parse('0.4.0'),
    latestVersion: AppVersion.parse('0.5.0'),
    feedUri: Uri.parse('https://example.com/broom-linux.json'),
    packageUri: packageUri,
    sha256: sha256,
    artifacts: artifacts,
  );
}

class _FakeDownloader implements LinuxPackageDownloader {
  _FakeDownloader(this.bytes);

  final List<int> bytes;
  Uri? requestedUri;
  int? maxBytes;

  @override
  Future<void> download(
    Uri uri,
    File destination, {
    required int maxBytes,
    required void Function(int received, int? total) onProgress,
    required bool Function() isActive,
  }) async {
    requestedUri = uri;
    this.maxBytes = maxBytes;
    final sink = destination.openWrite();
    sink.add(bytes);
    await sink.close();
    onProgress(bytes.length, bytes.length);
  }
}

class _FakeLauncher implements LinuxUpdateLauncher {
  bool openResult = true;
  bool executableResult = true;
  final List<String> opened = [];
  final List<String> madeExecutable = [];
  final List<String> relaunched = [];

  @override
  Future<bool> makeExecutable(String path) async {
    madeExecutable.add(path);
    return executableResult;
  }

  @override
  Future<bool> open(String path) async {
    opened.add(path);
    return openResult;
  }

  @override
  Future<void> relaunch(String path) async {
    relaunched.add(path);
  }
}

Map<String, Object?> _manifest(List<int> bytes) {
  final hash = sha256.convert(bytes).toString();
  return {
    'schemaVersion': 1,
    'version': '0.5.0',
    'url': 'https://example.com/broom-0.5.0.AppImage',
    'sha256': hash,
    'artifacts': [
      {
        'format': 'appimage',
        'file': 'broom-0.5.0.AppImage',
        'url': 'https://example.com/broom-0.5.0.AppImage',
        'sha256': hash,
      },
      {
        'format': 'deb',
        'file': 'broom_0.5.0_amd64.deb',
        'url': 'https://example.com/broom_0.5.0_amd64.deb',
        'sha256': hash,
      },
    ],
  };
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom-update-test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('LinuxUpdateInstaller download', () {
    test('downloads and verifies a package before exposing it', () async {
      final bytes = utf8.encode('verified update');
      final hash = sha256.convert(bytes).toString();
      final downloader = _FakeDownloader(bytes);
      final installer = LinuxUpdateInstaller(
        updatesRoot: p.join(temp.path, 'updates'),
        downloader: downloader,
        launcher: _FakeLauncher(),
        environment: const {},
        osRelease: '',
      );

      final file = await installer.download(
        artifact: _artifact(
          sha256: hash,
          fileName: 'broom-0.5.0-x86_64.AppImage',
        ),
        onProgress: (_, _) {},
        isActive: () => true,
      );

      expect(await file.readAsBytes(), bytes);
      expect(p.basename(file.path), 'broom-0.5.0-x86_64.AppImage');
      expect(downloader.maxBytes, installer.maxPackageBytes);
      expect(
        Directory(p.join(temp.path, 'updates'))
            .listSync()
            .where((entry) => entry.path.endsWith('.part')),
        isEmpty,
      );
    });

    test('rejects a package whose hash does not match', () async {
      final installer = LinuxUpdateInstaller(
        updatesRoot: p.join(temp.path, 'updates'),
        downloader: _FakeDownloader(utf8.encode('tampered')),
        launcher: _FakeLauncher(),
        environment: const {},
        osRelease: '',
      );

      await expectLater(
        installer.download(
          artifact: _artifact(sha256: _zeroHash),
          onProgress: (_, _) {},
          isActive: () => true,
        ),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(Directory(p.join(temp.path, 'updates')).listSync(), isEmpty);
    });

    test('refuses artifacts without a manifest hash', () async {
      final installer = LinuxUpdateInstaller(
        updatesRoot: p.join(temp.path, 'updates'),
        downloader: _FakeDownloader(utf8.encode('unverified')),
        launcher: _FakeLauncher(),
        environment: const {},
        osRelease: '',
      );

      await expectLater(
        installer.download(
          artifact: _artifact(),
          onProgress: (_, _) {},
          isActive: () => true,
        ),
        throwsA(isA<AppUpdateException>()),
      );
    });
  });

  group('LinuxUpdateInstaller selection', () {
    final artifacts = [
      _artifact(sha256: _zeroHash),
      _artifact(
        format: LinuxUpdateArtifactFormat.deb,
        sha256: _zeroHash,
        fileName: 'broom_0.5.0_amd64.deb',
        url: 'https://example.com/broom_0.5.0_amd64.deb',
      ),
      _artifact(
        format: LinuxUpdateArtifactFormat.rpm,
        sha256: _zeroHash,
        fileName: 'broom-0.5.0.x86_64.rpm',
        url: 'https://example.com/broom-0.5.0.x86_64.rpm',
      ),
    ];

    test('prefers the AppImage artifact when running as an AppImage', () {
      final installer = LinuxUpdateInstaller(
        updatesRoot: temp.path,
        environment: {'APPIMAGE': p.join(temp.path, 'broom.AppImage')},
        osRelease: 'ID=ubuntu',
      );

      final selected = installer.selectArtifact(_info(artifacts: artifacts));

      expect(selected?.format, LinuxUpdateArtifactFormat.appImage);
    });

    test('matches deb and rpm families', () {
      final deb = LinuxUpdateInstaller(
        updatesRoot: temp.path,
        environment: const {},
        osRelease: 'ID=ubuntu\nID_LIKE=debian',
      );
      final rpm = LinuxUpdateInstaller(
        updatesRoot: temp.path,
        environment: const {},
        osRelease: 'ID=fedora',
      );

      final info = _info(artifacts: artifacts);
      expect(deb.selectArtifact(info)?.format, LinuxUpdateArtifactFormat.deb);
      expect(rpm.selectArtifact(info)?.format, LinuxUpdateArtifactFormat.rpm);
    });

    test('falls back to the preferred artifact for unknown distributions', () {
      final installer = LinuxUpdateInstaller(
        updatesRoot: temp.path,
        environment: const {},
        osRelease: 'ID=arch',
      );

      final selected = installer.selectArtifact(
        _info(
          packageUri: Uri.parse('https://example.com/broom-0.5.0.AppImage'),
          sha256: _zeroHash,
        ),
      );

      expect(selected?.format, LinuxUpdateArtifactFormat.appImage);
    });

    test('explains when no verified package matches the install type', () {
      final installer = LinuxUpdateInstaller(
        updatesRoot: temp.path,
        environment: const {},
        osRelease: 'ID=debian',
      );
      final info = _info(artifacts: [artifacts.first]);

      expect(installer.selectArtifact(info), isNull);
      expect(installer.unavailableReason(info), contains('deb'));
    });

    test('parses os-release families', () {
      expect(
        LinuxUpdateInstaller.parsePackageFamily('ID=linuxmint'),
        LinuxPackageFamily.deb,
      );
      expect(
        LinuxUpdateInstaller.parsePackageFamily(
          'ID="rocky"\nID_LIKE="rhel centos"',
        ),
        LinuxPackageFamily.rpm,
      );
      expect(
        LinuxUpdateInstaller.parsePackageFamily('ID=arch'),
        LinuxPackageFamily.unknown,
      );
    });
  });

  group('LinuxUpdateInstaller install', () {
    test('replaces the running AppImage atomically', () async {
      final bytes = utf8.encode('brand new AppImage');
      final hash = sha256.convert(bytes).toString();
      final target = File(p.join(temp.path, 'broom.AppImage'));
      await target.writeAsString('old AppImage');
      final launcher = _FakeLauncher();
      final installer = LinuxUpdateInstaller(
        updatesRoot: p.join(temp.path, 'updates'),
        downloader: _FakeDownloader(bytes),
        launcher: launcher,
        environment: {'APPIMAGE': target.path},
        osRelease: '',
      );
      final artifact = _artifact(sha256: hash);
      final package = await installer.download(
        artifact: artifact,
        onProgress: (_, _) {},
        isActive: () => true,
      );

      final outcome = await installer.install(
        package: package,
        artifact: artifact,
        isActive: () => true,
      );

      expect(outcome.mode, LinuxUpdateInstallMode.appImageReplaced);
      expect(outcome.path, target.path);
      expect(await target.readAsBytes(), bytes);
      expect(
        launcher.madeExecutable.single,
        matches(
          RegExp('^${RegExp.escape(target.path)}\\.broom-update-[0-9a-f]{8}\$'),
        ),
      );
      expect(
        Directory(temp.path)
            .listSync()
            .where((entry) => entry.path.contains('.broom-update-')),
        isEmpty,
      );
    });

    test('keeps the old AppImage when it cannot set permissions', () async {
      final bytes = utf8.encode('new AppImage');
      final target = File(p.join(temp.path, 'broom.AppImage'));
      await target.writeAsString('old AppImage');
      final launcher = _FakeLauncher()..executableResult = false;
      final installer = LinuxUpdateInstaller(
        updatesRoot: p.join(temp.path, 'updates'),
        downloader: _FakeDownloader(bytes),
        launcher: launcher,
        environment: {'APPIMAGE': target.path},
        osRelease: '',
      );
      final artifact = _artifact(sha256: sha256.convert(bytes).toString());
      final package = await installer.download(
        artifact: artifact,
        onProgress: (_, _) {},
        isActive: () => true,
      );

      final outcome = await installer.install(
        package: package,
        artifact: artifact,
        isActive: () => true,
      );

      expect(outcome.mode, LinuxUpdateInstallMode.manual);
      expect(outcome.detail, contains('手动替换'));
      expect(await target.readAsString(), 'old AppImage');
    });

    test('opens verified deb packages with the system installer', () async {
      final bytes = utf8.encode('deb package');
      final launcher = _FakeLauncher();
      final installer = LinuxUpdateInstaller(
        updatesRoot: p.join(temp.path, 'updates'),
        downloader: _FakeDownloader(bytes),
        launcher: launcher,
        environment: const {},
        osRelease: 'ID=debian',
      );
      final artifact = _artifact(
        format: LinuxUpdateArtifactFormat.deb,
        sha256: sha256.convert(bytes).toString(),
        fileName: 'broom_0.5.0_amd64.deb',
        url: 'https://example.com/broom_0.5.0_amd64.deb',
      );
      final package = await installer.download(
        artifact: artifact,
        onProgress: (_, _) {},
        isActive: () => true,
      );

      final outcome = await installer.install(
        package: package,
        artifact: artifact,
        isActive: () => true,
      );

      expect(outcome.mode, LinuxUpdateInstallMode.installerOpened);
      expect(launcher.opened, [package.path]);
    });

    test('falls back to manual install when no opener is available', () async {
      final bytes = utf8.encode('rpm package');
      final launcher = _FakeLauncher()..openResult = false;
      final installer = LinuxUpdateInstaller(
        updatesRoot: p.join(temp.path, 'updates'),
        downloader: _FakeDownloader(bytes),
        launcher: launcher,
        environment: const {},
        osRelease: 'ID=fedora',
      );
      final artifact = _artifact(
        format: LinuxUpdateArtifactFormat.rpm,
        sha256: sha256.convert(bytes).toString(),
        fileName: 'broom-0.5.0.x86_64.rpm',
        url: 'https://example.com/broom-0.5.0.x86_64.rpm',
      );
      final package = await installer.download(
        artifact: artifact,
        onProgress: (_, _) {},
        isActive: () => true,
      );

      final outcome = await installer.install(
        package: package,
        artifact: artifact,
        isActive: () => true,
      );

      expect(outcome.mode, LinuxUpdateInstallMode.manual);
      expect(outcome.detail, contains('手动安装'));
    });
  });

  group('AppUpdateController install flow', () {
    test('installs a verified AppImage and offers a restart', () async {
      final bytes = utf8.encode('controller update');
      final target = File(p.join(temp.path, 'broom.AppImage'));
      await target.writeAsString('old');
      final launcher = _FakeLauncher();
      var exited = false;
      final controller = AppUpdateController(
        versionSource: const StaticAppVersion('0.4.0'),
        distribution: AppUpdateDistribution.linuxPackage,
        fetcher: (uri) async => jsonEncode(_manifest(bytes)),
        installer: LinuxUpdateInstaller(
          updatesRoot: p.join(temp.path, 'updates'),
          downloader: _FakeDownloader(bytes),
          launcher: launcher,
          environment: {'APPIMAGE': target.path},
          osRelease: '',
        ),
        exitApp: () => exited = true,
      );
      addTearDown(controller.dispose);

      await controller.check();

      expect(controller.error, isNull);
      expect(controller.canInstallInApp, isTrue);
      expect(controller.installUnavailableReason, isNull);

      await controller.installUpdate();

      expect(controller.installError, isNull);
      expect(controller.installNotice, contains('重启应用'));
      expect(
        controller.installOutcome?.mode,
        LinuxUpdateInstallMode.appImageReplaced,
      );
      expect(controller.restartAvailable, isTrue);
      expect(await target.readAsBytes(), bytes);

      await controller.restartApp();
      expect(launcher.relaunched, [target.path]);
      expect(exited, isTrue);
    });

    test('surfaces checksum failures without touching the AppImage', () async {
      final target = File(p.join(temp.path, 'broom.AppImage'));
      await target.writeAsString('old');
      final manifest = _manifest(utf8.encode('expected'));
      manifest['artifacts'] = [
        {
          'format': 'appimage',
          'file': 'broom-0.5.0.AppImage',
          'url': 'https://example.com/broom-0.5.0.AppImage',
          'sha256': _zeroHash,
        },
      ];
      final controller = AppUpdateController(
        versionSource: const StaticAppVersion('0.4.0'),
        distribution: AppUpdateDistribution.linuxPackage,
        fetcher: (uri) async => jsonEncode(manifest),
        installer: LinuxUpdateInstaller(
          updatesRoot: p.join(temp.path, 'updates'),
          downloader: _FakeDownloader(utf8.encode('tampered')),
          launcher: _FakeLauncher(),
          environment: {'APPIMAGE': target.path},
          osRelease: '',
        ),
      );
      addTearDown(controller.dispose);

      await controller.check();
      await controller.installUpdate();

      expect(controller.installError, contains('SHA-256'));
      expect(controller.restartAvailable, isFalse);
      expect(await target.readAsString(), 'old');
    });
  });
}
