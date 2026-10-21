import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Four-part Windows package version (`Major.Minor.Build.Revision`).
///
/// `pubspec.yaml` uses `0.4.0+4`, the MSIX identity uses `0.4.0.4`; both are
/// accepted and compared numerically rather than as strings, so `0.4.0.10` is
/// correctly newer than `0.4.0.9`.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.build, this.revision);

  factory AppVersion.parse(String raw) {
    final normalized = raw.trim().replaceAll('+', '.');
    if (normalized.isEmpty) {
      throw const FormatException('empty version');
    }
    final parts = normalized.split('.');
    if (parts.length > 4) {
      throw FormatException('too many version parts: $raw');
    }
    final values = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 65535) {
        throw FormatException('invalid version part: $raw');
      }
      values.add(value);
    }
    while (values.length < 4) {
      values.add(0);
    }
    return AppVersion(values[0], values[1], values[2], values[3]);
  }

  final int major;
  final int minor;
  final int build;
  final int revision;

  @override
  int compareTo(AppVersion other) {
    final results = <int>[
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      build.compareTo(other.build),
      revision.compareTo(other.revision),
    ];
    return results.firstWhere((value) => value != 0, orElse: () => 0);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      major == other.major &&
      minor == other.minor &&
      build == other.build &&
      revision == other.revision;

  @override
  int get hashCode => Object.hash(major, minor, build, revision);

  @override
  String toString() => '$major.$minor.$build.$revision';
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.feedUri,
    this.packageUri,
  });

  final AppVersion currentVersion;
  final AppVersion latestVersion;
  final Uri feedUri;
  final Uri? packageUri;

  bool get hasUpdate => latestVersion > currentVersion;
}

typedef AppUpdateFetcher = Future<String> Function(Uri uri);

/// Reads the App Installer feed published next to the signed packages and
/// reports whether a newer version exists.
///
/// The feed is an XML document produced by `tool/package_windows.ps1`:
/// ```xml
/// <AppInstaller Uri="https://host/broom.appinstaller" Version="0.5.0.0" ...>
///   <MainPackage ... Version="0.5.0.0" ... Uri="https://host/broom_0.5.0.0_x64.msix" />
/// </AppInstaller>
/// ```
/// The check is advisory only: it never installs anything. Windows performs the
/// actual download and update, and validates the MSIX signature while doing so,
/// so a forged feed cannot get an unsigned package onto the machine. That is why
/// no extra signature layer is required here — unlike the rule catalog, which
/// directly decides which files get deleted.
class AppUpdateService {
  AppUpdateService({
    required this.currentVersion,
    this.fetcher,
    this.maxFeedBytes = 64 * 1024,
  });

  /// Default feed location. Overridable at build time with
  /// `--dart-define=BROOM_UPDATE_FEED_URL=...`.
  static const compiledFeedUrl = String.fromEnvironment(
    'BROOM_UPDATE_FEED_URL',
    defaultValue: 'https://melaine-iceberg.github.io/broom/broom.appinstaller',
  );

  static final RegExp _rootVersion = RegExp(
    r'<AppInstaller\b[^>]*?\bVersion\s*=\s*"([^"]+)"',
  );
  static final RegExp _packageUri = RegExp(
    r'<MainPackage\b[^>]*?\bUri\s*=\s*"([^"]+)"',
  );

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
    final info = parseFeed(body, feed: uri, currentVersion: currentVersion);
    return info;
  }

  /// Parses a feed document. Split out so it can be tested without networking.
  static AppUpdateInfo parseFeed(
    String body, {
    required Uri feed,
    required AppVersion currentVersion,
  }) {
    final trimmed = body.trimLeft();
    if (!trimmed.startsWith('<?xml') && !trimmed.startsWith('<AppInstaller')) {
      throw const AppUpdateException('更新源返回的内容不是有效的更新清单。');
    }
    // The feed never legitimately contains a DTD; rejecting it removes the
    // entity-expansion class of parser attacks even for our tiny regex reader.
    if (body.contains('<!DOCTYPE') || body.contains('<!ENTITY')) {
      throw const AppUpdateException('更新清单包含不受支持的文档类型声明。');
    }
    final match = _rootVersion.firstMatch(body);
    if (match == null) {
      throw const AppUpdateException('更新清单缺少版本号。');
    }
    final AppVersion latest;
    try {
      latest = AppVersion.parse(match.group(1)!);
    } on FormatException {
      throw const AppUpdateException('更新清单的版本号格式无效。');
    }
    final packageMatch = _packageUri.firstMatch(body);
    Uri? packageUri;
    if (packageMatch != null) {
      packageUri = Uri.tryParse(packageMatch.group(1)!);
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
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/appinstaller, application/xml;q=0.9, */*;q=0.1',
      );
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
