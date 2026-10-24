import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_update_service.dart';

/// Reads the Linux release manifest and reports whether a newer version exists.
///
/// The manifest is a small JSON document published over HTTPS:
/// ```json
/// {
///   "schemaVersion": 1,
///   "version": "0.5.0",
///   "publishedAt": "2026-10-24T12:00:00Z",
///   "url": "https://host/broom-0.5.0-linux-x64.tar.gz",
///   "sha256": "<64 hex characters>"
/// }
/// ```
/// Like the Windows App Installer feed, this check is advisory only. Broom
/// never downloads or runs an installer; RPM users upgrade through their
/// package manager and tar.gz users replace the extracted bundle.
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

  Future<AppUpdateInfo> check([Uri? feed]) async {
    final uri = feed ?? feedUri;
    if (uri.scheme != 'https') {
      throw const AppUpdateException('更新源必须使用 HTTPS。');
    }
    final body = await (fetcher ?? _fetch)(uri);
    return parseManifest(body, feed: uri, currentVersion: currentVersion);
  }

  /// Parses a manifest without networking so the format can be tested alone.
  static AppUpdateInfo parseManifest(
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
    if (rawHash != null) {
      if (rawHash is! String ||
          !RegExp(_hashPattern).hasMatch(rawHash.trim())) {
        throw const AppUpdateException('更新清单的 SHA-256 校验值无效。');
      }
    }

    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latest,
      feedUri: feed,
      packageUri: packageUri,
    );
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
