import 'dart:convert';
import 'dart:io';

import 'package:broom/core/models/app_settings.dart';
import 'package:broom/core/models/quarantine_policy_models.dart';
import 'package:broom/core/settings/config_bundle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_config_bundle_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  const bundle = ConfigBundle(
    settings: AppSettings(
      theme: AppThemePreference.dark,
      language: AppLanguagePreference.en,
      disabledRuleIds: {'dev.npm'},
      disabledCategoryIds: {'dev'},
      scanParallelism: 4,
      scanLowPriority: false,
      useNtfsIndex: true,
      scanItemLimit: 250000,
      ruleUpdateUrl: 'https://updates.example.test/manifest.json',
    ),
    exclusions: [r'C:\Temp\Keep', r'D:\Cache'],
    retention: QuarantineRetentionPolicy(
      enabled: true,
      retentionDays: 21,
      maxBytes: 3 * 1024 * 1024 * 1024,
    ),
  );

  test('round-trips a bundle through the file service', () async {
    final path = p.windows.join(temp.path, 'broom-config.json');
    const service = ConfigTransferService();

    await service.exportTo(filePath: path, bundle: bundle);
    final imported = await service.importFrom(path);

    expect(imported.settings, bundle.settings);
    expect(imported.exclusions, bundle.exclusions);
    expect(imported.retention.enabled, isTrue);
    expect(imported.retention.retentionDays, 21);
    expect(imported.exportedAt, isNotNull);

    final raw =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    expect(raw['kind'], 'broom-config');
    expect(raw['schemaVersion'], 1);
    expect(
      raw.keys,
      containsAll(['settings', 'exclusions', 'quarantinePolicy']),
    );
    expect(raw.keys, isNot(contains('quarantine')));
    expect(raw.keys, isNot(contains('history')));
    final settings = raw['settings'] as Map<String, dynamic>;
    expect(settings['kind'], 'broom.settings');
    expect(settings['schemaVersion'], 2);
    final exclusions = raw['exclusions'] as Map<String, dynamic>;
    expect(exclusions['kind'], 'broom.exclusions');
    expect(exclusions['schemaVersion'], 2);
    final retention = raw['quarantinePolicy'] as Map<String, dynamic>;
    expect(retention['kind'], 'broom.quarantine-policy');
    expect(retention['schemaVersion'], 2);
  });

  test('accepts v1 nested documents and exposes migrated values', () {
    final source = jsonEncode({
      'kind': 'broom-config',
      'schemaVersion': 1,
      'settings': {'schemaVersion': 1, 'theme': 'light', 'language': 'zh'},
      'exclusions': {
        'schemaVersion': 1,
        'paths': [r'C:\Temp\Keep'],
      },
      'quarantinePolicy': {
        'schemaVersion': 1,
        'enabled': false,
        'retentionDays': 30,
        'maxBytes': 1024 * 1024,
      },
    });

    final decoded = ConfigBundleCodec.decode(source);
    expect(decoded.settings.theme, AppThemePreference.light);
    expect(decoded.exclusions, [r'C:\Temp\Keep']);
    expect(decoded.retention.enabled, isFalse);
  });

  test('rejects foreign, invalid, and newer bundles', () {
    expect(
      () => ConfigBundleCodec.decode('{}'),
      throwsA(isA<ConfigBundleException>()),
    );
    expect(
      () => ConfigBundleCodec.decode('{broken'),
      throwsA(isA<ConfigBundleException>()),
    );
    expect(
      () => ConfigBundleCodec.decode(
        jsonEncode({'kind': 'other-app', 'schemaVersion': 1}),
      ),
      throwsA(
        isA<ConfigBundleException>().having(
          (error) => error.message,
          'message',
          contains('不是 Broom 配置文件'),
        ),
      ),
    );

    final future =
        jsonDecode(ConfigBundleCodec.encode(bundle)) as Map<String, dynamic>;
    future['schemaVersion'] = 99;
    expect(
      () => ConfigBundleCodec.decode(jsonEncode(future)),
      throwsA(
        isA<ConfigBundleException>().having(
          (error) => error.message,
          'message',
          contains('高于当前支持版本'),
        ),
      ),
    );

    final missingSection =
        jsonDecode(ConfigBundleCodec.encode(bundle)) as Map<String, dynamic>;
    missingSection.remove('quarantinePolicy');
    expect(
      () => ConfigBundleCodec.decode(jsonEncode(missingSection)),
      throwsA(isA<ConfigBundleException>()),
    );

    final newerDocument =
        jsonDecode(ConfigBundleCodec.encode(bundle)) as Map<String, dynamic>;
    (newerDocument['settings'] as Map<String, dynamic>)['schemaVersion'] = 99;
    expect(
      () => ConfigBundleCodec.decode(jsonEncode(newerDocument)),
      throwsA(
        isA<ConfigBundleException>().having(
          (error) => error.message,
          'message',
          contains('不支持的设置文件版本'),
        ),
      ),
    );

    final invalidPath =
        jsonDecode(ConfigBundleCodec.encode(bundle)) as Map<String, dynamic>;
    (invalidPath['exclusions'] as Map<String, dynamic>)['paths'] = [
      r'relative\cache',
    ];
    expect(
      () => ConfigBundleCodec.decode(jsonEncode(invalidPath)),
      throwsA(isA<ConfigBundleException>()),
    );
  });

  test('refuses oversized or missing import files', () async {
    const service = ConfigTransferService();
    final missing = p.windows.join(temp.path, 'missing.json');
    await expectLater(
      service.importFrom(missing),
      throwsA(isA<ConfigTransferException>()),
    );

    final oversized = File(p.windows.join(temp.path, 'oversized.json'));
    oversized.writeAsStringSync(
      'x' * (ConfigTransferService.maxImportBytes + 1),
    );
    await expectLater(
      service.importFrom(oversized.path),
      throwsA(
        isA<ConfigTransferException>().having(
          (error) => error.message,
          'message',
          contains('1 MiB'),
        ),
      ),
    );
  });

  test('overwrites an existing export atomically', () async {
    const service = ConfigTransferService();
    final path = p.windows.join(temp.path, 'broom-config.json');

    await service.exportTo(filePath: path, bundle: bundle);
    await service.exportTo(
      filePath: path,
      bundle: ConfigBundle(
        settings: AppSettings.defaults,
        exclusions: const [],
        retention: QuarantineRetentionPolicy.defaults,
      ),
    );

    final imported = await service.importFrom(path);
    expect(imported.settings, AppSettings.defaults);
    expect(imported.exclusions, isEmpty);
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('refuses to export a bundle larger than the import limit', () async {
    const service = ConfigTransferService();
    final path = p.windows.join(temp.path, 'too-large.json');
    final oversized = ConfigBundle(
      settings: AppSettings.defaults,
      exclusions: List.generate(
        20000,
        (index) => 'C:\\Temp\\excluded-folder-$index-padding-padding',
      ),
      retention: QuarantineRetentionPolicy.defaults,
    );

    await expectLater(
      service.exportTo(filePath: path, bundle: oversized),
      throwsA(
        isA<ConfigTransferException>().having(
          (error) => error.message,
          'message',
          contains('1 MiB'),
        ),
      ),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('refuses a relative export path', () async {
    const service = ConfigTransferService();
    await expectLater(
      service.exportTo(filePath: 'broom-config.json', bundle: bundle),
      throwsA(isA<ConfigTransferException>()),
    );
  });
}
