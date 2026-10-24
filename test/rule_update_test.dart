import 'dart:convert';
import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/rules/rule_catalog.dart';
import 'package:broom/core/rules/rule_catalog_store.dart';
import 'package:broom/core/rules/rule_update_service.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _key = 'test-rule-signing-key';

String _manifest({
  required List<Map<String, Object?>> rules,
  required String version,
  String signingKey = _key,
  String publishedAt = '2026-01-01T00:00:00Z',
}) {
  final payload = <String, Object?>{
    'schemaVersion': 2,
    'version': version,
    'publishedAt': publishedAt,
    'rules': rules,
  };
  final signature = Hmac(
    sha256,
    utf8.encode(signingKey),
  ).convert(utf8.encode(canonicalJson(payload))).toString();
  return jsonEncode({...payload, 'signature': signature});
}

List<Map<String, Object?>> _encodedRules(List<CleanerRule> rules) => [
  for (final rule in rules) RuleCatalogCodec.encodeRule(rule),
];

void main() {
  late Directory temp;
  late RuleCatalogStore store;
  late RuleUpdateService service;

  Uri url(String path) => Uri.parse('https://updates.example.test/$path');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_rule_update_');
    store = RuleCatalogStore(directoryPath: p.join(temp.path, 'rules'));
    service = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async => _manifest(
        rules: _encodedRules(windowsCleanupRules),
        version: '2026.10.1',
      ),
      clock: () => DateTime.utc(2026, 10, 18),
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('verifies, applies and rolls back a signed rule catalog', () async {
    final candidate = await service.checkForUpdates(url('manifest.json'));
    expect(candidate, isNotNull);
    expect(candidate!.manifestVersion, '2026.10.1');

    final applied = await service.apply(candidate);
    expect(applied.version, '2026.10.1');
    expect(store.current.rules, hasLength(windowsCleanupRules.length));
    expect(store.hasPrevious, isFalse);

    final secondRules = _encodedRules([
      CleanerRule(
        id: windowsCleanupRules.first.id,
        title: windowsCleanupRules.first.title,
        category: windowsCleanupRules.first.category,
        description: windowsCleanupRules.first.description,
        pathPatterns: windowsCleanupRules.first.pathPatterns,
        minAge: const Duration(hours: 12),
        audit: windowsCleanupRules.first.audit,
      ),
      ...windowsCleanupRules.skip(1),
    ]);
    final secondService = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async =>
          _manifest(rules: secondRules, version: '2026.10.2'),
      clock: () => DateTime.utc(2026, 10, 18),
    );
    final second = await secondService.checkForUpdates(url('next.json'));
    await secondService.apply(second!);
    expect(store.current.version, '2026.10.2');
    expect(store.hasPrevious, isTrue);

    final rolledBack = await service.rollback();
    expect(rolledBack, isNotNull);
    expect(rolledBack!.version, '2026.10.1');
    expect(store.current.version, '2026.10.1');
  });

  test('rejects a tampered manifest', () async {
    final rules = _encodedRules(windowsCleanupRules);
    var manifest = _manifest(rules: rules, version: '2026.10.1');
    manifest = manifest.replaceFirst('windows.user_temp', 'windows.user_temp2');
    final tampered = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async => manifest,
      clock: () => DateTime.utc(2026, 10, 18),
    );

    expect(
      () => tampered.checkForUpdates(url('manifest.json')),
      throwsA(
        isA<RuleUpdateException>().having(
          (error) => error.message,
          'message',
          contains('签名校验失败'),
        ),
      ),
    );
  });

  test('rejects a catalog that removes a built-in rule', () async {
    final removed = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async => _manifest(
        rules: _encodedRules(windowsCleanupRules.skip(1).toList()),
        version: '2026.10.1',
      ),
      clock: () => DateTime.utc(2026, 10, 18),
    );

    expect(
      () => removed.checkForUpdates(url('manifest.json')),
      throwsA(
        isA<RuleUpdateException>().having(
          (error) => error.message,
          'message',
          contains('删除了内置规则'),
        ),
      ),
    );
  });

  test('requires HTTPS and a configured signing key', () async {
    final httpService = RuleUpdateService(
      store: store,
      signingKey: _key,
      fetcher: (uri) async => _manifest(
        rules: _encodedRules(windowsCleanupRules),
        version: '2026.10.1',
      ),
    );
    expect(
      () => httpService.checkForUpdates(
        Uri.parse('http://updates.example.test/manifest.json'),
      ),
      throwsA(isA<RuleUpdateException>()),
    );

    final unsigned = RuleUpdateService(
      store: store,
      signingKey: '',
      fetcher: (uri) async => '{}',
    );
    expect(unsigned.updatesEnabled, isFalse);
    expect(
      () => unsigned.checkForUpdates(url('manifest.json')),
      throwsA(isA<RuleUpdateException>()),
    );
  });

  test('restores built-in rules while keeping the previous version', () async {
    final candidate = await service.checkForUpdates(url('manifest.json'));
    await service.apply(candidate!);

    final builtin = await service.restoreBuiltin();
    expect(builtin.isBuiltin, isTrue);
    expect(store.current.isBuiltin, isTrue);
    expect(store.hasPrevious, isTrue);

    final restored = await service.rollback();
    expect(restored!.version, '2026.10.1');
  });

  test('corrupt active catalogs fall back to built-in rules', () async {
    final directory = Directory(p.join(temp.path, 'rules'));
    await directory.create(recursive: true);
    await File(p.join(directory.path, RuleCatalogStore.activeFileName))
        .writeAsString('{not-json');

    final reloaded = RuleCatalogStore(directoryPath: directory.path);
    reloaded.loadSync();
    expect(reloaded.current.isBuiltin, isTrue);
    expect(reloaded.loadError, isNotNull);
  });
}
