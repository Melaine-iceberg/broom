import 'dart:convert';
import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/windows_rule_resolver.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _windowsOnly = !Platform.isWindows ? 'Windows only' : false;

const _extensionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  test(
    'rule is review-level, version-aware, and grouped with extension cache',
    () {
      final rule = windowsCleanupRules.singleWhere(
        (rule) => rule.id == 'browser.windows_extension_versions',
      );

      expect(rule.risk, CleanRisk.review);
      expect(rule.keepActiveExtensionVersions, isTrue);
      expect(rule.pathPatterns, hasLength(4));
      expect(ruleCategoryKey(rule), 'browser_extension');
    },
  );

  group('version-aware extension roots', () {
    late Directory base;
    late WindowsRuleResolver resolver;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('broom_ext_versions_');
      resolver = WindowsRuleResolver(environment: {'TESTBASE': base.path});
    });

    tearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });

    CleanerRule rule() => const CleanerRule(
      id: 'browser.windows_extension_versions',
      title: 'test',
      category: 'test',
      description: 'test',
      pathPatterns: [r'%TESTBASE%\User Data\*'],
      risk: CleanRisk.review,
      keepActiveExtensionVersions: true,
    );

    Future<String> createProfile() async {
      final profile = p.windows.join(base.path, 'User Data', 'Default');
      await Directory(profile).create(recursive: true);
      return profile;
    }

    Future<void> createVersion(String profile, String version) async {
      await Directory(
        p.windows.join(profile, 'Extensions', _extensionId, version),
      ).create(recursive: true);
    }

    Future<void> writePreferences(String profile, Object content) async {
      await File(p.windows.join(profile, 'Preferences'))
          .writeAsString(content is String ? content : jsonEncode(content));
    }

    test('returns stale versions and keeps the active version', () async {
      final profile = await createProfile();
      for (final version in ['1.0.0', '2.0.0', '2.1.0_0', '3.0.0']) {
        await createVersion(profile, version);
      }
      await Directory(
        p.windows.join(profile, 'Extensions', _extensionId, '_metadata'),
      ).create(recursive: true);
      await writePreferences(profile, {
        'extensions': {
          'settings': {
            _extensionId: {'path': '2.1.0_0'},
          },
        },
      });

      final roots = await resolver.resolve(rule());

      expect(roots, [
        p.windows.normalize(
          p.windows.join(profile, 'Extensions', _extensionId, '1.0.0'),
        ),
        p.windows.normalize(
          p.windows.join(profile, 'Extensions', _extensionId, '2.0.0'),
        ),
        p.windows.normalize(
          p.windows.join(profile, 'Extensions', _extensionId, '3.0.0'),
        ),
      ]);
    });

    test('fails closed when Preferences is missing', () async {
      final profile = await createProfile();
      await createVersion(profile, '1.0.0');
      await createVersion(profile, '2.0.0');

      expect(await resolver.resolve(rule()), isEmpty);
    });

    test('fails closed when Preferences is not valid JSON', () async {
      final profile = await createProfile();
      await createVersion(profile, '1.0.0');
      await createVersion(profile, '2.0.0');
      await writePreferences(profile, '{"extensions":');

      expect(await resolver.resolve(rule()), isEmpty);
    });

    test('fails closed when the active version directory is missing', () async {
      final profile = await createProfile();
      await createVersion(profile, '1.0.0');
      await writePreferences(profile, {
        'extensions': {
          'settings': {
            _extensionId: {'path': '2.0.0'},
          },
        },
      });

      expect(await resolver.resolve(rule()), isEmpty);
    });

    test('ignores unsafe extension ids and version paths', () async {
      final profile = await createProfile();
      await createVersion(profile, '1.0.0');
      await writePreferences(profile, {
        'extensions': {
          'settings': {
            '../../broom-audit': {'path': '1.0.0'},
            _extensionId: {'path': r'..\..\1.0.0'},
          },
        },
      });

      expect(await resolver.resolve(rule()), isEmpty);
    });
  }, skip: _windowsOnly);
}
