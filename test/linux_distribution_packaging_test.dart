import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Debian packaging', () {
    final control = File('packaging/deb/control.in');
    final script = File('tool/package_deb.sh');
    final postinst = File('packaging/deb/postinst');
    final prerm = File('packaging/deb/prerm');
    final copyright = File('packaging/deb/copyright');

    test('control file declares the runtime dependencies and package layout',
        () {
      expect(control.existsSync(), isTrue);
      final contents = control.readAsStringSync();

      expect(contents, contains('Package: broom'));
      expect(contents, contains('Version: @VERSION@-1'));
      expect(contents, contains('Architecture: amd64'));
      expect(contents, contains('Section: utils'));
      expect(contents, contains('libgtk-3-0 | libgtk-3-0t64'));
      expect(contents, contains('libglib2.0-0 | libglib2.0-0t64'));
      expect(contents, contains('pkexec | policykit-1'));
      expect(contents, contains('polkitd | policykit-1'));
      expect(contents, contains('systemd'));
      expect(contents, contains('libc6 (>= 2.34)'));
      expect(contents, contains('libstdc++6 (>= 11)'));
      expect(contents, contains('Installed-Size: @INSTALLED_SIZE@'));
      expect(contents, contains(r'$XDG_DATA_HOME/Broom'));
    });

    test('maintainer scripts refresh the icon and desktop caches', () {
      for (final file in [postinst, prerm]) {
        expect(file.existsSync(), isTrue);
        final contents = file.readAsStringSync();
        expect(contents, contains('gtk-update-icon-cache'));
        expect(contents, contains('update-desktop-database'));
        expect(contents, isNot(contains('pkexec')));
        expect(contents, isNot(contains('apt-get')));
      }
    });

    test('copyright file records the MIT license', () {
      expect(copyright.existsSync(), isTrue);
      final contents = copyright.readAsStringSync();
      expect(contents, contains('Format:'));
      expect(contents, contains('Upstream-Name: broom'));
      expect(contents, contains('License: MIT'));
    });

    test('build script builds the helper and never installs or runs cleanup',
        () {
      expect(script.existsSync(), isTrue);
      final contents = script.readAsStringSync();

      expect(contents, contains('cmake -S linux/system_helper'));
      expect(contents, contains('-DCMAKE_INSTALL_LIBEXECDIR=libexec'));
      expect(contents, contains('/usr/libexec/broom/broom-system-helper'));
      expect(contents, contains('usr/share/polkit-1/actions/'));
      expect(contents, contains('usr/share/applications/'));
      expect(contents, contains('usr/share/icons/hicolor/'));
      expect(contents, contains('usr/share/doc/broom/copyright'));
      expect(contents, contains('dpkg-deb --root-owner-group --build'));
      expect(contents, contains('sha256sum'));
      expect(contents, contains('--skip-flutter-build'));
      expect(contents, contains('BROOM_GPG_KEY'));
      expect(contents, contains('--detach-sign'));
      expect(contents, contains('stat -f -c %T'));
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*(dpkg|apt|apt-get)\s+-i\b', multiLine: true))),
      );
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*dpkg\s+--install\b', multiLine: true))),
      );
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*pkexec\b', multiLine: true))),
      );
      expect(contents, isNot(matches(RegExp(r'^\s*sudo\b', multiLine: true))));
    });

    test('helper path matches the Dart client constant', () {
      final source = File('lib/core/platform/linux_system_maintenance.dart')
          .readAsStringSync();
      final contents = script.readAsStringSync();

      expect(
        source,
        contains(
          'static const String defaultHelperPath =\n'
          "      '/usr/libexec/broom/broom-system-helper';",
        ),
      );
      expect(contents, contains('/usr/libexec/broom/broom-system-helper'));
    });
  });

  group('AppImage packaging', () {
    final script = File('tool/package_appimage.sh');
    final appRun = File('packaging/appimage/AppRun');

    test('AppRun keeps the bundle layout and forwards arguments', () {
      expect(appRun.existsSync(), isTrue);
      final contents = appRun.readAsStringSync();
      expect(contents, contains('usr/lib/broom/lib'));
      expect(
        contents,
        contains(r'exec "$appdir/usr/lib/broom/broom" "$@"'),
      );
    });

    test('build script keeps the helper out and verifies appimagetool', () {
      expect(script.existsSync(), isTrue);
      final contents = script.readAsStringSync();

      expect(contents, contains('build/appimage/broom.AppDir'));
      expect(contents, contains('usr/lib/broom'));
      expect(contents, contains('packaging/appimage/AppRun'));
      expect(contents, contains('.DirIcon'));
      expect(contents, contains('appimagetool_version="1.9.1"'));
      expect(contents, contains('sha256sum -c'));
      expect(contents, contains('APPIMAGE_EXTRACT_AND_RUN=1'));
      expect(contents, contains('--no-appstream'));
      expect(contents, contains('BROOM_GPG_KEY'));
      expect(contents, contains('--sign'));
      expect(contents, contains('--sign-key'));
      expect(contents, contains('sha256sum'));
      expect(contents, contains('--skip-flutter-build'));
      expect(contents, isNot(contains('cmake -S linux/system_helper')));
      expect(contents, isNot(contains('usr/libexec')));
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*pkexec\b', multiLine: true))),
      );
      expect(contents, isNot(matches(RegExp(r'^\s*sudo\b', multiLine: true))));
    });
  });

  group('Linux release metadata', () {
    final script = File('tool/sign_linux_release.sh');

    test('manifest uses schemaVersion 1 and the data the app parses', () {
      expect(script.existsSync(), isTrue);
      final contents = script.readAsStringSync();

      expect(contents, contains('"schemaVersion": 1'));
      expect(contents, contains('"version": "'));
      expect(contents, contains('"publishedAt": "'));
      expect(contents, contains('"url": "'));
      expect(contents, contains('"sha256": "'));
      expect(contents, contains('"artifacts": ['));
      expect(contents, contains('SHA256SUMS'));
      expect(contents, contains('--base-url'));
      expect(contents, contains('--published-at'));
      expect(contents, contains('BROOM_GPG_KEY'));
      expect(contents, contains('--detach-sign'));
      expect(contents, contains('HTTPS'));
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*pkexec\b', multiLine: true))),
      );
      expect(contents, isNot(matches(RegExp(r'^\s*sudo\b', multiLine: true))));
    });

    test('Linux CI builds and verifies deb and AppImage artifacts', () {
      final workflow = File('.github/workflows/linux.yml').readAsStringSync();

      expect(workflow, contains('bash tool/package_deb.sh'));
      expect(workflow, contains('bash tool/package_appimage.sh'));
      expect(workflow, contains('dpkg-deb --info'));
      expect(workflow, contains('--appimage-extract'));
      expect(workflow, contains('bash tool/sign_linux_release.sh'));
      expect(workflow, contains('broom-linux.json'));
      expect(workflow, contains('broom-linux-x64'));
    });
  });
}
