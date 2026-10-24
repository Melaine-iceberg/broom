import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'rule_catalog.dart';
import 'rule_catalog_store.dart';

class RuleUpdateException implements Exception {
  const RuleUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RuleUpdateCandidate {
  const RuleUpdateCandidate({
    required this.catalog,
    required this.manifestVersion,
  });

  final RuleCatalog catalog;
  final String manifestVersion;
}

typedef RuleManifestFetcher = Future<String> Function(Uri uri);

/// Downloads and verifies rule updates.
///
/// A manifest looks like:
/// ```json
/// {
///   "schemaVersion": 2,
///   "version": "2026.10.18",
///   "publishedAt": "2026-10-18T12:00:00Z",
///   "rules": [ ... ],
///   "signature": "<hex HMAC-SHA256 over the other fields>"
/// }
/// ```
/// The key is injected at build time with
/// `--dart-define=BROOM_RULE_SIGNING_KEY=...`. Builds without a key reject all
/// remote updates. HTTPS is mandatory and HTTP redirects are not followed.
class RuleUpdateService {
  RuleUpdateService({
    required this.store,
    required this.signingKey,
    this.fetcher,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const compiledSigningKey = String.fromEnvironment(
    'BROOM_RULE_SIGNING_KEY',
  );

  /// Manifest schema 2 is required whenever a catalog contains version-aware
  /// rules. Older clients reject the whole manifest instead of treating their
  /// profile roots as ordinary scan roots.
  static const manifestSchemaVersion = 2;
  static const minimumManifestSchemaVersion = 1;

  static const maxManifestBytes = 4 * 1024 * 1024;

  final RuleCatalogStore store;
  final String signingKey;
  final RuleManifestFetcher? fetcher;
  final DateTime Function() _clock;

  bool get updatesEnabled => signingKey.isNotEmpty;

  RuleCatalog get activeCatalog => store.current;

  Future<RuleUpdateCandidate?> checkForUpdates(Uri uri) async {
    if (!updatesEnabled) {
      throw const RuleUpdateException('此构建未配置规则签名密钥，在线更新不可用。');
    }
    if (uri.scheme != 'https') {
      throw const RuleUpdateException('规则更新地址必须使用 HTTPS。');
    }
    final body = await (fetcher ?? _fetch)(uri);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const RuleUpdateException('规则更新清单格式无效。');
    }
    final manifestSchemaVersion = decoded['schemaVersion'];
    if (manifestSchemaVersion is! int ||
        manifestSchemaVersion < minimumManifestSchemaVersion ||
        manifestSchemaVersion > RuleUpdateService.manifestSchemaVersion) {
      throw RuleUpdateException('不支持的规则更新清单版本：$manifestSchemaVersion');
    }
    final version = decoded['version'];
    if (version is! String || version.trim().isEmpty) {
      throw const RuleUpdateException('规则更新清单缺少版本号。');
    }
    final publishedAt = DateTime.tryParse('${decoded['publishedAt'] ?? ''}');
    final rawRules = decoded['rules'];
    if (rawRules is! List || rawRules.isEmpty) {
      throw const RuleUpdateException('规则更新清单不包含规则。');
    }
    final algorithm = decoded['algorithm'] ?? 'hmac-sha256';
    if (algorithm != 'hmac-sha256') {
      throw RuleUpdateException('不支持的签名算法：$algorithm');
    }
    final signature = decoded['signature'];
    if (signature is! String) {
      throw const RuleUpdateException('规则更新清单缺少签名。');
    }
    final payload = <String, Object?>{
      'schemaVersion': decoded['schemaVersion'],
      'version': version,
      'publishedAt': decoded['publishedAt'],
      'rules': rawRules,
    };
    final expected = _sign(canonicalJson(payload));
    final actual = _parseHex(signature);
    if (actual == null || !_constantTimeEquals(expected, actual)) {
      throw const RuleUpdateException('规则更新签名校验失败，已拒绝更新。');
    }

    final usesVersionAwareRules = rawRules.any(
      (raw) => raw is Map && raw['keepActiveExtensionVersions'] == true,
    );
    if (usesVersionAwareRules && manifestSchemaVersion < 2) {
      throw const RuleUpdateException('包含版本感知规则的清单必须使用 schemaVersion 2，已拒绝更新。');
    }

    final catalog = RuleCatalogCodec.decodeCatalog({
      'schemaVersion': RuleCatalogCodec.schemaVersion,
      'version': version.trim(),
      'source': 'remote',
      'publishedAt': publishedAt?.toUtc().toIso8601String(),
      'rules': rawRules,
    });
    final baselineIds = {for (final rule in store.builtin.rules) rule.id};
    final incomingIds = {for (final rule in catalog.rules) rule.id};
    final missing = baselineIds.difference(incomingIds);
    if (missing.isNotEmpty) {
      throw RuleUpdateException('规则更新删除了内置规则，已拒绝：${missing.join(', ')}');
    }
    if (catalog.version == store.builtin.version) {
      throw RuleUpdateException('规则更新不能使用保留版本号 ${store.builtin.version}。');
    }
    if (catalog.version == store.current.version &&
        catalog.source == store.current.source) {
      return null;
    }
    if (publishedAt != null && publishedAt.isAfter(_clock())) {
      throw const RuleUpdateException('规则更新清单的发布时间晚于当前时间。');
    }
    return RuleUpdateCandidate(
      catalog: catalog,
      manifestVersion: catalog.version,
    );
  }

  Future<RuleCatalog> apply(RuleUpdateCandidate candidate) async {
    await store.saveActive(candidate.catalog);
    return store.current;
  }

  Future<RuleCatalog?> rollback() => store.rollback();

  Future<RuleCatalog> restoreBuiltin() => store.resetToBuiltin();

  List<int> _sign(String payload) {
    final hmac = Hmac(sha256, utf8.encode(signingKey));
    return hmac.convert(utf8.encode(payload)).bytes;
  }

  List<int>? _parseHex(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(trimmed)) {
      return null;
    }
    return [
      for (var index = 0; index < trimmed.length; index += 2)
        int.parse(trimmed.substring(index, index + 2), radix: 16),
    ];
  }

  bool _constantTimeEquals(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
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
        throw RuleUpdateException('规则更新下载失败：HTTP ${response.statusCode}');
      }
      final bytes = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response) {
        total += chunk.length;
        if (total > maxManifestBytes) {
          throw const RuleUpdateException('规则更新清单超过 4 MiB，已中止。');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    } on TimeoutException {
      throw const RuleUpdateException('规则更新下载超时。');
    } on SocketException catch (error) {
      throw RuleUpdateException('无法连接规则更新服务器：${error.message}');
    } on HandshakeException catch (error) {
      throw RuleUpdateException('无法建立 HTTPS 连接：${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}

/// Stable canonical JSON used for signatures: object keys are sorted
/// recursively and no insignificant whitespace is emitted.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(value, buffer);
  return buffer.toString();
}

void _writeCanonical(Object? value, StringBuffer buffer) {
  if (value == null) {
    buffer.write('null');
  } else if (value is String) {
    buffer.write(jsonEncode(value));
  } else if (value is num || value is bool) {
    buffer.write(jsonEncode(value));
  } else if (value is List) {
    buffer.write('[');
    for (var index = 0; index < value.length; index++) {
      if (index > 0) buffer.write(',');
      _writeCanonical(value[index], buffer);
    }
    buffer.write(']');
  } else if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    buffer.write('{');
    var first = true;
    for (final key in keys) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write(jsonEncode(key));
      buffer.write(':');
      _writeCanonical(value[key], buffer);
    }
    buffer.write('}');
  } else {
    throw ArgumentError.value(value, 'value', '无法序列化为规范 JSON');
  }
}
