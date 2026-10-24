import 'dart:convert';
import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/windows_rule_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _linuxOnly = !Platform.isLinux ? 'Linux only' : false;

const _extensionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('version-aware extension roots', () {
    late Directory base;
    late PosixRuleResolver resolver;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('broom_ext_versions_');
      resolver = PosixRuleResolver(environment: {'XDG_CONFIG_HOME': base.path});
    });

    tearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });

    CleanerRule rule() => const CleanerRule(
      id: 'browser.linux_extension_versions',
      title: 'test',
      category: 'test',
      description: 'test',
      pathPatterns: [r'$XDG_CONFIG_HOME/google-chrome/*'],
      risk: CleanRisk.review,
      keepActiveExtensionVersions: true,
    );

    Future<String> createProfile() async {
      final profile = p.posix.join(base.path, 'google-chrome', 'Default');
      await Directory(profile).create(recursive: true);
      return profile;
    }

    Future<void> createVersion(String profile, String version) async {
      await Directory(
        p.posix.join(profile, 'Extensions', _extensionId, version),
      ).create(recursive: true);
    }

    Future<void> writePreferences(String profile, Object content) async {
      await File(p.posix.join(profile, 'Preferences'))
          .writeAsString(content is String ? content : jsonEncode(content));
    }

    test('returns stale versions and keeps the active version', () async {
      final profile = await createProfile();
      for (final version in ['1.0.0', '2.0.0', '2.1.0_0', '3.0.0']) {
        await createVersion(profile, version);
      }
      await Directory(
        p.posix.join(profile, 'Extensions', _extensionId, '_metadata'),
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
        p.posix.join(profile, 'Extensions', _extensionId, '1.0.0'),
        p.posix.join(profile, 'Extensions', _extensionId, '2.0.0'),
        p.posix.join(profile, 'Extensions', _extensionId, '3.0.0'),
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
            _extensionId: {'path': '../../1.0.0'},
          },
        },
      });

      expect(await resolver.resolve(rule()), isEmpty);
    });
  }, skip: _linuxOnly);
}
