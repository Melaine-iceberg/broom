import 'package:broom/core/models/app_settings.dart';
import 'package:broom/core/models/quarantine_policy_models.dart';
import 'package:broom/core/settings/config_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('config envelope migration', () {
    test('upgrades v1 documents with the expected kind', () {
      final migrated = migrateConfigDocument(
        {'schemaVersion': 1, 'theme': 'dark'},
        kind: settingsDocumentKind,
        label: '设置文件',
      );

      expect(migrated['schemaVersion'], 2);
      expect(migrated['kind'], settingsDocumentKind);
      expect(migrated['theme'], 'dark');
    });

    test('rejects missing, malformed, and newer versions', () {
      expect(
        () => migrateConfigDocument(
          {'theme': 'dark'},
          kind: settingsDocumentKind,
          label: '设置文件',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => migrateConfigDocument(
          {'schemaVersion': '2'},
          kind: settingsDocumentKind,
          label: '设置文件',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => migrateConfigDocument(
          {'schemaVersion': 99},
          kind: settingsDocumentKind,
          label: '设置文件',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('不支持的设置文件版本'),
          ),
        ),
      );
      expect(
        () => migrateConfigDocument(
          {'schemaVersion': 0},
          kind: settingsDocumentKind,
          label: '设置文件',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a v2 document with the wrong kind', () {
      expect(
        () => decodeSettingsDocument({
          'kind': exclusionsDocumentKind,
          'schemaVersion': 2,
          'theme': 'system',
          'language': 'zh',
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('设置文件类型无效'),
          ),
        ),
      );
    });
  });

  group('settings document', () {
    test('round-trips every preference and v1 defaults', () {
      const settings = AppSettings(
        theme: AppThemePreference.dark,
        language: AppLanguagePreference.en,
        disabledRuleIds: {'dev.npm'},
        disabledCategoryIds: {'dev'},
        scanParallelism: 0,
        scanLowPriority: false,
        useNtfsIndex: true,
        scanItemLimit: 125000,
        ruleUpdateUrl: 'https://updates.example.test/manifest.json',
        onboardingCompleted: false,
      );

      expect(
        decodeSettingsDocument(encodeSettingsDocument(settings)),
        settings,
      );

      final legacy = decodeSettingsDocument({
        'schemaVersion': 1,
        'theme': 'light',
        'language': 'en',
      });
      expect(legacy.theme, AppThemePreference.light);
      expect(legacy.language, AppLanguagePreference.en);
      expect(legacy.scanParallelism, 2);
      expect(legacy.scanLowPriority, isTrue);
      expect(legacy.useNtfsIndex, isFalse);
      expect(legacy.scanItemLimit, isNull);
      expect(legacy.onboardingCompleted, isTrue);
    });

    test('rejects invalid values', () {
      expect(
        () => decodeSettingsDocument({
          'schemaVersion': 2,
          'kind': settingsDocumentKind,
          'theme': 'blue',
          'language': 'zh',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decodeSettingsDocument({
          'schemaVersion': 2,
          'kind': settingsDocumentKind,
          'theme': 'system',
          'language': 'zh',
          'scanParallelism': 17,
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('exclusions document', () {
    test(
      'normalizes, sorts, and deduplicates paths without checking existence',
      () {
        final paths = decodeExclusionsDocument({
          'schemaVersion': 1,
          'paths': [r'C:\Temp\Keep\', r'C:\Offline\Cache', r'c:\temp\keep'],
        });

        expect(paths, [r'C:\Offline\Cache', r'C:\Temp\Keep']);
      },
    );

    test('rejects relative paths and volume roots', () {
      for (final path in [r'relative\cache', r'C:\', r'\\server\share']) {
        expect(
          () => decodeExclusionsDocument({
            'schemaVersion': 2,
            'kind': exclusionsDocumentKind,
            'paths': [path],
          }),
          throwsA(isA<FormatException>()),
          reason: path,
        );
      }
    });
  });

  group('retention document', () {
    test('migrates v1 and round-trips a valid policy', () {
      const policy = QuarantineRetentionPolicy(
        enabled: true,
        retentionDays: 14,
        maxBytes: 2 * 1024 * 1024 * 1024,
      );
      final decoded = decodeRetentionDocument(encodeRetentionDocument(policy));
      expect(decoded.enabled, isTrue);
      expect(decoded.retentionDays, 14);
      expect(decoded.maxBytes, 2 * 1024 * 1024 * 1024);

      final migrated = decodeRetentionDocument({
        'schemaVersion': 1,
        'enabled': false,
        'retentionDays': 30,
        'maxBytes': 1024 * 1024,
      });
      expect(migrated.enabled, isFalse);
      expect(migrated.retentionDays, 30);
    });

    test('rejects invalid policies', () {
      expect(
        () => decodeRetentionDocument({
          'schemaVersion': 2,
          'kind': retentionDocumentKind,
          'enabled': true,
          'retentionDays': 0,
          'maxBytes': 1024,
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
