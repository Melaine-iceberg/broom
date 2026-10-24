import 'dart:convert';
import 'dart:io';

import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/rules/linux_rules.dart';
import 'package:broom/core/rules/rule_catalog.dart';
import 'package:broom/core/rules/rule_catalog_store.dart';
import 'package:broom/core/rules/rule_update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _key = 'linux-rule-signing-key';

String _manifest({required String version, int schemaVersion = 2}) {
  final payload = <String, Object?>{
    'schemaVersion': schemaVersion,
    'version': version,
    'publishedAt': '2026-10-24T00:00:00Z',
    'rules': [
      for (final rule in linuxCleanupRules) RuleCatalogCodec.encodeRule(rule),
    ],
  };
  final signature = Hmac(
    sha256,
    utf8.encode(_key),
  ).convert(utf8.encode(canonicalJson(payload))).toString();
  return jsonEncode({...payload, 'signature': signature});
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_linux_rules_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('Linux platform accepts an applied catalog', () {
    final platform = LinuxCleanerPlatform(
      environment: const {'HOME': '/home/test'},
      rules: linuxCleanupRules,
    );

    expect(platform.rulesVersion, 'builtin-linux-3');
    expect(platform.rules, hasLength(linuxCleanupRules.length));

    platform.applyRuleCatalog(linuxCleanupRules, '2026.10.24');

    expect(platform.rulesVersion, '2026.10.24');
    expect(platform.rules, hasLength(linuxCleanupRules.length));
  });

  test('store keeps the Linux built-in version without an active catalog', () {
    final store = RuleCatalogStore(
      directoryPath: p.join(temp.path, 'rules'),
      builtinRules: linuxCleanupRules,
      builtinVersion: 'builtin-linux-3',
      semantics: PathSemanticsFactory.forCurrentPlatform(),
    );

    final catalog = store.loadSync();
    expect(catalog.version, 'builtin-linux-3');
    expect(catalog.isBuiltin, isTrue);
  });

  test('signed Linux catalogs apply and reload on disk', () async {
    final directory = p.join(temp.path, 'rules');
    final store = RuleCatalogStore(
      directoryPath: directory,
      builtinRules: linuxCleanupRules,
      builtinVersion: 'builtin-linux-3',
      semantics: PathSemanticsFactory.forCurrentPlatform(),
    );
    final service = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async => _manifest(version: '2026.10.24'),
      clock: () => DateTime.utc(2026, 10, 24),
    );

    final candidate = await service.checkForUpdates(
      Uri.parse('https://updates.example.test/linux.json'),
    );
    expect(candidate, isNotNull);
    expect(candidate!.catalog.rules, hasLength(linuxCleanupRules.length));

    await service.apply(candidate);
    expect(store.current.version, '2026.10.24');
    expect(store.current.isBuiltin, isFalse);

    final reloaded = RuleCatalogStore(
      directoryPath: directory,
      builtinRules: linuxCleanupRules,
      builtinVersion: 'builtin-linux-3',
      semantics: PathSemanticsFactory.forCurrentPlatform(),
    ).loadSync();
    expect(reloaded.version, '2026.10.24');
    expect(
      reloaded.rules.map((rule) => rule.id),
      containsAll(linuxCleanupRules.map((rule) => rule.id)),
    );
  });

  test('rejects unsupported manifest schema versions', () async {
    final store = RuleCatalogStore(
      directoryPath: p.join(temp.path, 'rules'),
      builtinRules: linuxCleanupRules,
      builtinVersion: 'builtin-linux-3',
      semantics: PathSemanticsFactory.forCurrentPlatform(),
    );
    final service = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async =>
          _manifest(version: '2026.10.24', schemaVersion: 3),
      clock: () => DateTime.utc(2026, 10, 24),
    );

    expect(
      () => service.checkForUpdates(
        Uri.parse('https://updates.example.test/linux.json'),
      ),
      throwsA(isA<RuleUpdateException>()),
    );
  });

  test('version-aware rules require manifest schema 2', () async {
    final store = RuleCatalogStore(
      directoryPath: p.join(temp.path, 'rules'),
      builtinRules: linuxCleanupRules,
      builtinVersion: 'builtin-linux-3',
      semantics: PathSemanticsFactory.forCurrentPlatform(),
    );
    final service = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async =>
          _manifest(version: '2026.10.24', schemaVersion: 1),
      clock: () => DateTime.utc(2026, 10, 24),
    );

    expect(
      () => service.checkForUpdates(
        Uri.parse('https://updates.example.test/linux.json'),
      ),
      throwsA(
        isA<RuleUpdateException>().having(
          (error) => error.message,
          'message',
          contains('schemaVersion 2'),
        ),
      ),
    );
  });

  test('Linux catalog rejects a manifest that drops a built-in rule', () async {
    final store = RuleCatalogStore(
      directoryPath: p.join(temp.path, 'rules'),
      builtinRules: linuxCleanupRules,
      builtinVersion: 'builtin-linux-3',
      semantics: PathSemanticsFactory.forCurrentPlatform(),
    );
    final payload = <String, Object?>{
      'schemaVersion': 2,
      'version': '2026.10.24',
      'publishedAt': '2026-10-24T00:00:00Z',
      'rules': [
        for (final rule in linuxCleanupRules.skip(1))
          RuleCatalogCodec.encodeRule(rule),
      ],
    };
    final signature = Hmac(
      sha256,
      utf8.encode(_key),
    ).convert(utf8.encode(canonicalJson(payload))).toString();
    final service = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async => jsonEncode({...payload, 'signature': signature}),
      clock: () => DateTime.utc(2026, 10, 24),
    );

    expect(
      () => service.checkForUpdates(
        Uri.parse('https://updates.example.test/linux.json'),
      ),
      throwsA(isA<RuleUpdateException>()),
    );
  });

  test('version-aware rule and audit fixtures survive a catalog roundtrip', () {
    final original = linuxCleanupRules.firstWhere(
      (rule) => rule.id == 'browser.linux_extension_versions',
    );
    final decoded = RuleCatalogCodec.decodeRule(
      RuleCatalogCodec.encodeRule(original),
    );

    expect(decoded.keepActiveExtensionVersions, isTrue);
    expect(decoded.pathPatterns, original.pathPatterns);
    expect(
      decoded.audit!.samples.any((sample) => sample.content != null),
      isTrue,
    );
  });

  test('Linux rules keep their audit metadata in a remote catalog', () {
    final catalog = RuleCatalog(
      version: '2026.10.24',
      source: 'remote',
      rules: linuxCleanupRules,
    );
    expect(catalog.isBuiltin, isFalse);
    expect(catalog.rules.every((rule) => rule.audit != null), isTrue);
    expect(
      catalog.rules.map((rule) => rule.id).toSet(),
      hasLength(linuxCleanupRules.length),
    );
  });
}
