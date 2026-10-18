import 'dart:convert';
import 'dart:io';

import 'package:broom/core/models/quarantine_policy_models.dart';
import 'package:broom/core/settings/quarantine_policy_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_retention_store_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  QuarantinePolicyStore createStore() => QuarantinePolicyStore(
    filePath: p.windows.join(temp.path, 'config', 'quarantine_policy.json'),
  );

  test('returns defaults when no policy file exists', () async {
    final policy = await createStore().load();

    expect(policy.enabled, isFalse);
    expect(policy.retentionDays, 30);
    expect(policy.maxBytes, 5 * 1024 * 1024 * 1024);
    expect(policy.isValid, isTrue);
  });

  test('persists the policy across reloads', () async {
    final store = createStore();
    const policy = QuarantineRetentionPolicy(
      enabled: true,
      retentionDays: 14,
      maxBytes: 2 * 1024 * 1024 * 1024,
    );

    await store.save(policy);
    final loaded = await createStore().load();

    expect(loaded.enabled, isTrue);
    expect(loaded.retentionDays, 14);
    expect(loaded.maxBytes, 2 * 1024 * 1024 * 1024);

    final raw = jsonDecode(await File(store.filePath).readAsString());
    expect(raw, {
      'schemaVersion': 1,
      'enabled': true,
      'retentionDays': 14,
      'maxBytes': 2 * 1024 * 1024 * 1024,
    });
  });

  test('rejects unsupported schema versions', () async {
    final store = createStore();
    await File(store.filePath).parent.create(recursive: true);
    await File(store.filePath).writeAsString(
      jsonEncode({
        'schemaVersion': 99,
        'enabled': true,
        'retentionDays': 30,
        'maxBytes': 1024 * 1024,
      }),
    );

    await expectLater(
      store.load(),
      throwsA(
        isA<QuarantinePolicyException>().having(
          (error) => error.message,
          'message',
          contains('不支持的保留策略版本'),
        ),
      ),
    );
  });

  test('rejects corrupted or out-of-range policies', () async {
    final store = createStore();
    await File(store.filePath).parent.create(recursive: true);

    Future<void> expectInvalid(String content) async {
      await File(store.filePath).writeAsString(content);
      await expectLater(
        store.load(),
        throwsA(isA<QuarantinePolicyException>()),
      );
    }

    await expectInvalid('{not-json');
    await expectInvalid(
      jsonEncode({
        'schemaVersion': 1,
        'enabled': 'yes',
        'retentionDays': 30,
        'maxBytes': 1024 * 1024,
      }),
    );
    await expectInvalid(
      jsonEncode({
        'schemaVersion': 1,
        'enabled': true,
        'retentionDays': 0,
        'maxBytes': 1024 * 1024,
      }),
    );
    await expectInvalid(
      jsonEncode({
        'schemaVersion': 1,
        'enabled': true,
        'retentionDays': 30,
        'maxBytes': 1024,
      }),
    );
  });

  test('refuses to save an invalid policy', () async {
    final store = createStore();

    await expectLater(
      store.save(
        const QuarantineRetentionPolicy(
          enabled: true,
          retentionDays: 0,
          maxBytes: 1024,
        ),
      ),
      throwsA(isA<QuarantinePolicyException>()),
    );
    expect(await File(store.filePath).exists(), isFalse);
  });
}
