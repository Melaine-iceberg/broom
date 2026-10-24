import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_update_service.dart';

enum LinuxUpdateArtifactFormat { appImage, deb, rpm, tarball, unknown }

/// One downloadable package listed by the release manifest.
class LinuxUpdateArtifact {
  const LinuxUpdateArtifact({
    required this.format,
    required this.fileName,
    required this.uri,
    this.sha256,
  });

  final LinuxUpdateArtifactFormat format;
  final String fileName;
  final Uri uri;

  /// Lower-case SHA-256 from the manifest. Downloads without a hash are
  /// rejected by the installer because they cannot be verified.
  final String? sha256;
}

/// Linux manifest result: the common update fields plus the signed hashes and
/// the per-format artifact list published by `tool/sign_linux_release.sh`.
class LinuxAppUpdateInfo extends AppUpdateInfo {
  const LinuxAppUpdateInfo({
    required super.currentVersion,
    required super.latestVersion,
    required super.feedUri,
    super.packageUri,
    this.sha256,
    this.artifacts = const [],
  });

  final String? sha256;
  final List<LinuxUpdateArtifact> artifacts;
}

/// Reads the Linux release manifest and reports whether a newer version exists.
///
/// The manifest is a small JSON document published over HTTPS:
/// ```json
/// {
///   "schemaVersion": 1,
///   "version": "0.5.0",
///   "publishedAt": "2026-10-24T12:00:00Z",
///   "url": "https://host/broom-0.5.0-linux-x64.AppImage",
///   "sha256": "<64 hex characters>",
///   "artifacts": [
///     {"format": "appimage", "file": "broom-0.5.0-linux-x64.AppImage",
///      "url": "https://host/broom-0.5.0-linux-x64.AppImage", "sha256": "..."}
///   ]
/// }
/// ```
/// The check itself only reads the manifest. Downloading and installing is
/// performed by `LinuxUpdateInstaller`, which verifies every byte against the
/// manifest hash before it is allowed to replace an AppImage or reach the
/// system package installer.
class LinuxAppUpdateService {
  LinuxAppUpdateService({
    required this.currentVersion,
    this.fetcher,
    this.maxFeedBytes = 64 * 1024,
  });

  /// Overridable at build time with
  /// `--dart-define=BROOM_LINUX_UPDATE_FEED=...`.
  static const compiledFeedUrl = String.fromEnvironment(
    'BROOM_LINUX_UPDATE_FEED',
    defaultValue: 'https://melaine-iceberg.github.io/broom/broom-linux.json',
  );

  static const _hashPattern = r'^[0-9a-fA-F]{64}$';

  final AppVersion currentVersion;
  final AppUpdateFetcher? fetcher;
  final int maxFeedBytes;

  Uri get feedUri => Uri.parse(compiledFeedUrl);

  Future<LinuxAppUpdateInfo> check([Uri? feed]) async {
    final uri = feed ?? feedUri;
    if (uri.scheme != 'https') {
      throw const AppUpdateException('更新源必须使用 HTTPS。');
    }
    final body = await (fetcher ?? _fetch)(uri);
    return parseManifest(body, feed: uri, currentVersion: currentVersion);
  }

  /// Parses a manifest without networking so the format can be tested alone.
  static LinuxAppUpdateInfo parseManifest(
    String body, {
    required Uri feed,
    required AppVersion currentVersion,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const AppUpdateException('更新源返回的内容不是有效的更新清单。');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AppUpdateException('更新清单必须是 JSON 对象。');
    }
    if (decoded['schemaVersion'] != 1) {
      throw AppUpdateException('不支持的更新清单版本：${decoded['schemaVersion']}');
    }

    final rawVersion = decoded['version'];
    if (rawVersion is! String || rawVersion.trim().isEmpty) {
      throw const AppUpdateException('更新清单缺少版本号。');
    }
    final AppVersion latest;
    try {
      latest = AppVersion.parse(rawVersion.trim());
    } on FormatException {
      throw const AppUpdateException('更新清单的版本号格式无效。');
    }

    final rawUrl = decoded['url'];
    Uri? packageUri;
    if (rawUrl != null) {
      if (rawUrl is! String || rawUrl.trim().isEmpty) {
        throw const AppUpdateException('更新清单的下载地址无效。');
      }
      packageUri = Uri.tryParse(rawUrl.trim());
      if (packageUri == null || packageUri.scheme != 'https') {
        throw const AppUpdateException('更新清单的下载地址必须使用 HTTPS。');
      }
    }

    final rawHash = decoded['sha256'];
    String? primaryHash;
    if (rawHash != null) {
      if (rawHash is! String ||
          !RegExp(_hashPattern).hasMatch(rawHash.trim())) {
        throw const AppUpdateException('更新清单的 SHA-256 校验值无效。');
      }
      primaryHash = rawHash.trim().toLowerCase();
    }

    final rawArtifacts = decoded['artifacts'];
    if (rawArtifacts != null && rawArtifacts is! List) {
      throw const AppUpdateException('更新清单的产物列表无效。');
    }
    final artifacts = <LinuxUpdateArtifact>[];
    if (rawArtifacts is List) {
      for (final entry in rawArtifacts) {
        if (entry is! Map) continue;
        final rawFileName = entry['file'];
        final rawEntryUrl = entry['url'];
        if (rawFileName is! String || rawFileName.trim().isEmpty) continue;
        if (rawEntryUrl is! String || rawEntryUrl.trim().isEmpty) continue;
        final entryUri = Uri.tryParse(rawEntryUrl.trim());
        if (entryUri == null || entryUri.scheme != 'https') continue;
        final entryHash = entry['sha256'];
        String? artifactHash;
        if (entryHash is String &&
            RegExp(_hashPattern).hasMatch(entryHash.trim())) {
          artifactHash = entryHash.trim().toLowerCase();
        }
        final fileName = rawFileName.trim();
        var format = formatForFileName(fileName);
        final rawFormat = entry['format'];
        if (rawFormat is String) {
          final explicit = formatForFileName(rawFormat);
          if (explicit != LinuxUpdateArtifactFormat.unknown) {
            format = explicit;
          }
        }
        artifacts.add(
          LinuxUpdateArtifact(
            format: format,
            fileName: fileName,
            uri: entryUri,
            sha256: artifactHash,
          ),
        );
      }
    }

    return LinuxAppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latest,
      feedUri: feed,
      packageUri: packageUri,
      sha256: primaryHash,
      artifacts: List.unmodifiable(artifacts),
    );
  }

  /// Maps the manifest `format` value or a file name to a known package kind.
  static LinuxUpdateArtifactFormat formatForFileName(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.endsWith('.appimage') || lower == 'appimage') {
      return LinuxUpdateArtifactFormat.appImage;
    }
    if (lower.endsWith('.deb') || lower == 'deb') {
      return LinuxUpdateArtifactFormat.deb;
    }
    if (lower.endsWith('.rpm') || lower == 'rpm') {
      return LinuxUpdateArtifactFormat.rpm;
    }
    if (lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz') ||
        lower == 'tar.gz' ||
        lower == 'tarball') {
      return LinuxUpdateArtifactFormat.tarball;
    }
    return LinuxUpdateArtifactFormat.unknown;
  }

  Future<String> _fetch(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('更新源下载失败：HTTP ${response.statusCode}');
      }
      final bytes = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response) {
        total += chunk.length;
        if (total > maxFeedBytes) {
          throw const AppUpdateException('更新清单过大，已中止。');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    } on TimeoutException {
      throw const AppUpdateException('更新源连接超时。');
    } on SocketException catch (error) {
      throw AppUpdateException('无法连接更新源：${error.message}');
    } on HandshakeException catch (error) {
      throw AppUpdateException('无法建立 HTTPS 连接：${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}
