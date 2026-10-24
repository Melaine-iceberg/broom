import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'app_update_service.dart';
import 'linux_app_update_service.dart';

/// Package family of the running Linux distribution, used to pick the matching
/// manifest artifact. Unknown means the manifest's preferred artifact is used.
enum LinuxPackageFamily { deb, rpm, unknown }

enum LinuxUpdateInstallMode {
  /// The running AppImage was replaced atomically. A restart applies it.
  appImageReplaced,

  /// The verified package was handed to the system software installer.
  installerOpened,

  /// The verified package stays on disk; the user completes the install.
  manual,
}

class LinuxUpdateInstallOutcome {
  const LinuxUpdateInstallOutcome({
    required this.mode,
    required this.path,
    this.detail,
  });

  final LinuxUpdateInstallMode mode;
  final String path;
  final String? detail;
}

abstract interface class LinuxPackageDownloader {
  Future<void> download(
    Uri uri,
    File destination, {
    required int maxBytes,
    required void Function(int received, int? total) onProgress,
    required bool Function() isActive,
  });
}

/// Opens verified packages and relaunches the new AppImage. Abstracted so the
/// install flow can be tested without processes or desktop sessions.
abstract interface class LinuxUpdateLauncher {
  Future<bool> open(String path);

  Future<bool> makeExecutable(String path);

  Future<void> relaunch(String path);
}

class ProcessLinuxUpdateLauncher implements LinuxUpdateLauncher {
  const ProcessLinuxUpdateLauncher();

  @override
  Future<bool> open(String path) async {
    const attempts = <List<String>>[
      ['xdg-open', 'PATH'],
      ['gio', 'open', 'PATH'],
    ];
    for (final attempt in attempts) {
      final arguments = [
        for (final argument in attempt.skip(1))
          argument == 'PATH' ? path : argument,
      ];
      try {
        final result = await Process.run(attempt.first, arguments);
        if (result.exitCode == 0) return true;
      } on ProcessException {
        // Try the next desktop opener.
      }
    }
    return false;
  }

  @override
  Future<bool> makeExecutable(String path) async {
    try {
      final result = await Process.run('chmod', ['0755', path]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<void> relaunch(String path) async {
    await Process.start(path, const [], mode: ProcessStartMode.detached);
  }
}

/// Streams a package over HTTPS with a hard byte cap.
class HttpLinuxPackageDownloader implements LinuxPackageDownloader {
  const HttpLinuxPackageDownloader({this.maxRedirects = 5});

  final int maxRedirects;

  @override
  Future<void> download(
    Uri uri,
    File destination, {
    required int maxBytes,
    required void Function(int received, int? total) onProgress,
    required bool Function() isActive,
  }) async {
    var current = uri;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      for (var redirects = 0; redirects <= maxRedirects; redirects++) {
        if (current.scheme != 'https') {
          throw const AppUpdateException('安装包地址必须使用 HTTPS。');
        }
        final request = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/octet-stream',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) {
            throw const AppUpdateException('安装包重定向缺少目标地址。');
          }
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw AppUpdateException('安装包下载失败：HTTP ${response.statusCode}');
        }
        final total = response.contentLength > 0
            ? response.contentLength
            : null;
        if (total != null && total > maxBytes) {
          await response.drain<void>();
          throw const AppUpdateException('更新包超过大小上限，已中止。');
        }
        final sink = destination.openWrite();
        var received = 0;
        try {
          await for (final chunk in response) {
            if (!isActive()) {
              throw const AppUpdateException('更新下载已取消。');
            }
            received += chunk.length;
            if (received > maxBytes) {
              throw const AppUpdateException('更新包超过大小上限，已中止。');
            }
            sink.add(chunk);
            onProgress(received, total);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (received == 0) {
          throw const AppUpdateException('安装包为空，已中止。');
        }
        return;
      }
      throw const AppUpdateException('安装包重定向次数过多。');
    } on TimeoutException {
      throw const AppUpdateException('下载安装包超时。');
    } on SocketException catch (error) {
      throw AppUpdateException('无法下载安装包：${error.message}');
    } on HandshakeException catch (error) {
      throw AppUpdateException('无法建立 HTTPS 连接：${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}

/// Downloads a manifest artifact, verifies its SHA-256 and then either replaces
/// the running AppImage or hands the package to the desktop installer.
///
/// Broom never runs downloaded code and never elevates privileges itself:
/// AppImage replacement is a rename in the user's own directory, while deb and
/// RPM packages are opened with `xdg-open` so the desktop software installer
/// owns authentication and package-manager transactions.
class LinuxUpdateInstaller {
  LinuxUpdateInstaller({
    required this.updatesRoot,
    LinuxPackageDownloader? downloader,
    LinuxUpdateLauncher? launcher,
    Map<String, String>? environment,
    String? osRelease,
    this.maxPackageBytes = 512 * 1024 * 1024,
  }) : downloader = downloader ?? const HttpLinuxPackageDownloader(),
       launcher = launcher ?? const ProcessLinuxUpdateLauncher(),
       environment = environment ?? Platform.environment,
       osRelease = osRelease ?? _readOsRelease();

  final String updatesRoot;
  final LinuxPackageDownloader downloader;
  final LinuxUpdateLauncher launcher;
  final Map<String, String> environment;
  final String osRelease;
  final int maxPackageBytes;

  static const _hashPattern = r'^[0-9a-f]{64}$';

  String? get appImagePath {
    final value = environment['APPIMAGE']?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  LinuxPackageFamily get packageFamily => parsePackageFamily(osRelease);

  /// Returns the artifact the running installation can actually apply, or null
  /// when the manifest has no verifiable package for this installation.
  LinuxUpdateArtifact? selectArtifact(LinuxAppUpdateInfo info) {
    final candidates = <LinuxUpdateArtifact>[
      for (final artifact in info.artifacts)
        if (artifact.uri.scheme == 'https' &&
            artifact.sha256 != null &&
            RegExp(_hashPattern).hasMatch(artifact.sha256!))
          artifact,
    ];
    final primaryUri = info.packageUri;
    final primaryHash = info.sha256;
    if (primaryUri != null && primaryHash != null) {
      final fileName = _fileNameFor(primaryUri);
      candidates.add(
        LinuxUpdateArtifact(
          format: LinuxAppUpdateService.formatForFileName(fileName),
          fileName: fileName,
          uri: primaryUri,
          sha256: primaryHash,
        ),
      );
    }

    LinuxUpdateArtifact? firstOf(LinuxUpdateArtifactFormat format) {
      for (final artifact in candidates) {
        if (artifact.format == format) return artifact;
      }
      return null;
    }

    if (appImagePath != null) {
      return firstOf(LinuxUpdateArtifactFormat.appImage);
    }
    switch (packageFamily) {
      case LinuxPackageFamily.deb:
        return firstOf(LinuxUpdateArtifactFormat.deb);
      case LinuxPackageFamily.rpm:
        return firstOf(LinuxUpdateArtifactFormat.rpm);
      case LinuxPackageFamily.unknown:
        if (primaryUri != null) {
          for (final artifact in candidates) {
            if (artifact.uri == primaryUri) return artifact;
          }
        }
        return candidates.isEmpty ? null : candidates.first;
    }
  }

  /// Human-readable reason when [selectArtifact] returns null.
  String? unavailableReason(LinuxAppUpdateInfo info) {
    if (!info.hasUpdate) return '当前已是最新版本。';
    final artifact = selectArtifact(info);
    if (artifact != null) return null;
    if (appImagePath != null) {
      return '更新清单没有提供经过校验的 AppImage 安装包。';
    }
    switch (packageFamily) {
      case LinuxPackageFamily.deb:
        return '更新清单没有提供经过校验的 deb 安装包。';
      case LinuxPackageFamily.rpm:
        return '更新清单没有提供经过校验的 RPM 安装包。';
      case LinuxPackageFamily.unknown:
        return '更新清单没有提供带 SHA-256 校验值的安装包。';
    }
  }

  /// Downloads [artifact] into `updatesRoot` and verifies its digest.
  Future<File> download({
    required LinuxUpdateArtifact artifact,
    required void Function(int received, int? total) onProgress,
    required bool Function() isActive,
  }) async {
    final expected = artifact.sha256;
    if (expected == null) {
      throw const AppUpdateException('更新清单缺少 SHA-256 校验值，无法验证安装包。');
    }
    if (artifact.uri.scheme != 'https') {
      throw const AppUpdateException('安装包地址必须使用 HTTPS。');
    }
    await Directory(updatesRoot).create(recursive: true);
    final destination = File(p.join(updatesRoot, _safeFileName(artifact)));
    final partial = File('${destination.path}.part');
    await _deleteQuietly(partial);
    try {
      await downloader.download(
        artifact.uri,
        partial,
        maxBytes: maxPackageBytes,
        onProgress: onProgress,
        isActive: isActive,
      );
      if (!isActive()) {
        throw const AppUpdateException('更新下载已取消。');
      }
      final actual = await _sha256Of(partial, isActive);
      if (actual != expected) {
        throw const AppUpdateException('更新包校验失败：SHA-256 与更新清单不一致。');
      }
      await _deleteQuietly(destination);
      await partial.rename(destination.path);
      return destination;
    } catch (_) {
      await _deleteQuietly(partial);
      rethrow;
    }
  }

  /// Applies a verified package from [package] for [artifact].
  Future<LinuxUpdateInstallOutcome> install({
    required File package,
    required LinuxUpdateArtifact artifact,
    required bool Function() isActive,
  }) async {
    if (!await package.exists()) {
      throw const AppUpdateException('更新包不存在，请重新下载。');
    }
    if (artifact.format == LinuxUpdateArtifactFormat.appImage) {
      return _installAppImage(package: package, isActive: isActive);
    }
    if (artifact.format == LinuxUpdateArtifactFormat.deb ||
        artifact.format == LinuxUpdateArtifactFormat.rpm) {
      if (await launcher.open(package.path)) {
        return LinuxUpdateInstallOutcome(
          mode: LinuxUpdateInstallMode.installerOpened,
          path: package.path,
        );
      }
      return LinuxUpdateInstallOutcome(
        mode: LinuxUpdateInstallMode.manual,
        path: package.path,
        detail: '无法打开系统安装器，请手动安装已验证的更新包。',
      );
    }
    return LinuxUpdateInstallOutcome(
      mode: LinuxUpdateInstallMode.manual,
      path: package.path,
      detail: '已下载并验证更新包，请按发行版说明手动安装。',
    );
  }

  Future<LinuxUpdateInstallOutcome> _installAppImage({
    required File package,
    required bool Function() isActive,
  }) async {
    final targetPath = appImagePath;
    if (targetPath == null) {
      return LinuxUpdateInstallOutcome(
        mode: LinuxUpdateInstallMode.manual,
        path: package.path,
        detail: '当前不是 AppImage 运行方式，请手动替换安装目录。',
      );
    }
    final target = File(targetPath);
    if (!await target.exists()) {
      return LinuxUpdateInstallOutcome(
        mode: LinuxUpdateInstallMode.manual,
        path: package.path,
        detail: '找不到当前 AppImage 文件，请手动替换。',
      );
    }
    // Use an unpredictable sibling name so a pre-created symlink in a shared
    // directory cannot redirect the copy to another file.
    final suffix = Random.secure()
        .nextInt(1 << 32)
        .toRadixString(16)
        .padLeft(8, '0');
    final temporary = File('$targetPath.broom-update-$suffix');
    try {
      await _deleteQuietly(temporary);
      await package.copy(temporary.path);
      if (!await launcher.makeExecutable(temporary.path)) {
        await _deleteQuietly(temporary);
        return LinuxUpdateInstallOutcome(
          mode: LinuxUpdateInstallMode.manual,
          path: package.path,
          detail: '无法写入当前 AppImage 所在目录，请手动替换。',
        );
      }
      if (!isActive()) {
        await _deleteQuietly(temporary);
        throw const AppUpdateException('更新安装已取消。');
      }
      await temporary.rename(targetPath);
      return LinuxUpdateInstallOutcome(
        mode: LinuxUpdateInstallMode.appImageReplaced,
        path: targetPath,
      );
    } on FileSystemException catch (error) {
      await _deleteQuietly(temporary);
      return LinuxUpdateInstallOutcome(
        mode: LinuxUpdateInstallMode.manual,
        path: package.path,
        detail: '无法替换当前 AppImage：${error.message}',
      );
    }
  }

  Future<void> relaunch(String path) => launcher.relaunch(path);

  Future<bool> openDownloadsFolder() => launcher.open(updatesRoot);

  String _safeFileName(LinuxUpdateArtifact artifact) {
    final base = artifact.fileName.split(RegExp(r'[/\\]')).last;
    final cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'broom-update';
    }
    return cleaned.length > 160 ? cleaned.substring(0, 160) : cleaned;
  }

  static String _fileNameFor(Uri uri) {
    final segments = uri.pathSegments;
    return segments.isEmpty ? 'broom-update' : segments.last;
  }

  static Future<String> _sha256Of(File file, bool Function() isActive) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      if (!isActive()) {
        throw const AppUpdateException('更新校验已取消。');
      }
      input.add(chunk);
    }
    input.close();
    final digest = sink.value;
    if (digest == null) {
      throw const AppUpdateException('无法校验更新包。');
    }
    return digest.toString();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A leftover partial file is harmless and is replaced on the next run.
    }
  }

  static String _readOsRelease() {
    try {
      return File('/etc/os-release').readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  /// Parses `ID` / `ID_LIKE` from os-release. Debian-family systems get deb
  /// packages, RPM-family systems get RPMs; everything else uses the manifest's
  /// preferred artifact.
  static LinuxPackageFamily parsePackageFamily(String osRelease) {
    final values = <String, String>{};
    for (final line in osRelease.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      var value = trimmed.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[trimmed.substring(0, separator).trim().toLowerCase()] = value
          .toLowerCase();
    }
    final identifiers = <String>{
      if (values['id'] case final id?) ...id.split(RegExp(r'\s+')),
      if (values['id_like'] case final idLike?) ...idLike.split(RegExp(r'\s+')),
    }..removeWhere((value) => value.isEmpty);
    const debFamily = {
      'debian',
      'ubuntu',
      'linuxmint',
      'pop',
      'elementary',
      'kali',
      'deepin',
      'devuan',
      'raspbian',
      'zorin',
    };
    const rpmFamily = {
      'fedora',
      'rhel',
      'centos',
      'rocky',
      'almalinux',
      'ol',
      'opensuse',
      'opensuse-leap',
      'opensuse-tumbleweed',
      'suse',
      'sles',
      'mageia',
      'amzn',
    };
    if (identifiers.any(debFamily.contains)) return LinuxPackageFamily.deb;
    if (identifiers.any(rpmFamily.contains)) return LinuxPackageFamily.rpm;
    return LinuxPackageFamily.unknown;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
