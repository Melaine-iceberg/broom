import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/rules/linux_rules.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _linuxOnly = !Platform.isLinux ? 'Linux only' : false;

void main() {
  group('LinuxCleanerPlatform', () {
    test('uses POSIX semantics and XDG defaults', () {
      final platform = LinuxCleanerPlatform(
        environment: const {'HOME': '/home/broom'},
      );

      expect(platform.pathSemantics, isA<PosixPathSemantics>());
      expect(platform.displayName, 'Linux');
      expect(platform.rulesVersion, 'builtin-linux-3');
      expect(
        platform.quarantineRoot,
        '/home/broom/.local/share/Broom/quarantine',
      );
      expect(platform.environment['XDG_CACHE_HOME'], '/home/broom/.cache');
      expect(platform.environment['XDG_CONFIG_HOME'], '/home/broom/.config');
      expect(platform.environment['XDG_DATA_HOME'], '/home/broom/.local/share');
      expect(platform.protectedRoots, contains('/usr'));
      expect(platform.protectedRoots, contains('/etc'));
      expect(
        platform.rules.map((rule) => rule.id),
        contains('system.linux_thumbnails'),
      );
      expect(
        platform.rules.map((rule) => rule.id),
        contains('browser.linux_firefox'),
      );
    });

    test('honours an explicit XDG_DATA_HOME', () {
      final platform = LinuxCleanerPlatform(
        environment: const {
          'HOME': '/home/broom',
          'XDG_DATA_HOME': '/srv/broom-data',
        },
      );

      expect(platform.quarantineRoot, '/srv/broom-data/Broom/quarantine');
    });

    test('ignores a relative XDG_DATA_HOME', () {
      final platform = LinuxCleanerPlatform(
        environment: const {
          'HOME': '/home/broom',
          'XDG_DATA_HOME': 'relative/data',
        },
      );

      expect(
        platform.quarantineRoot,
        '/home/broom/.local/share/Broom/quarantine',
      );
    });

    test('resolves XDG rule roots from the environment', () async {
      final base = await Directory.systemTemp.createTemp('broom_linux_');
      addTearDown(() => base.delete(recursive: true));

      final cache = Directory(p.posix.join(base.path, 'cache'));
      final thumbnails = Directory(p.posix.join(cache.path, 'thumbnails'));
      await thumbnails.create(recursive: true);

      final platform = LinuxCleanerPlatform(
        environment: {'HOME': base.path, 'XDG_CACHE_HOME': cache.path},
      );
      final rule = linuxSafeRules.firstWhere(
        (candidate) => candidate.id == 'system.linux_thumbnails',
      );

      expect(await platform.resolveRoots(rule), [thumbnails.path]);
    }, skip: _linuxOnly);
  });

  group('PathGuard.forPosix', () {
    test('rejects system directories and accepts user cache paths', () {
      final guard = PathGuard.forPosix(
        additionalProtectedRoots: const [
          '/home/broom/.local/share/Broom/quarantine',
        ],
      );

      expect(guard.isProtected('/etc/passwd'), isTrue);
      expect(guard.isProtected('/usr/lib/libc.so'), isTrue);
      expect(guard.isProtected('/var/log/syslog'), isTrue);
      expect(guard.isProtected('/home/broom/.cache/thumbnails/a.png'), isFalse);
      expect(
        guard.allows(
          path: '/home/broom/.cache/thumbnails/a.png',
          root: '/home/broom/.cache/thumbnails',
        ),
        isTrue,
      );
      expect(
        guard.allows(path: '/home/broom/.cache', root: '/home/broom/.cache'),
        isFalse,
      );
      expect(
        guard.allows(
          path: '/home/broom/.cache/thumbnails-extra/a.png',
          root: '/home/broom/.cache/thumbnails',
        ),
        isFalse,
      );
    });
  });

  group('rule categories', () {
    test('Linux rule ids map to user-facing categories', () {
      final byId = {for (final rule in linuxCleanupRules) rule.id: rule};

      expect(ruleCategoryKey(byId['system.linux_thumbnails']!), 'thumbnails');
      expect(ruleCategoryKey(byId['system.linux_fontconfig']!), 'system');
      expect(ruleCategoryKey(byId['browser.linux_firefox']!), 'browser');
      expect(
        ruleCategoryKey(byId['browser.linux_extension_versions']!),
        'browser_extension',
      );
      expect(ruleCategoryKey(byId['app.linux_vscode']!), 'app');
      expect(ruleCategoryKey(byId['dev.linux_pip']!), 'dev');
      expect(ruleCategoryKey(byId['gpu.linux_mesa_shader']!), 'gpu');
    });
  });
}
