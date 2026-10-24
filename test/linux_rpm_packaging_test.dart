import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RPM packaging', () {
    final spec = File('packaging/rpm/broom.spec');
    final script = File('tool/package_rpm.sh');

    test('spec installs the bundle, helper, policy and desktop entry', () {
      expect(spec.existsSync(), isTrue);
      final contents = spec.readAsStringSync();

      expect(contents, contains('Name:           broom'));
      expect(contents, contains('Version:        %{broom_version}'));
      expect(contents, contains('Release:        1%{?dist}'));
      expect(contents, contains('BuildArch:      x86_64'));
      expect(contents, contains('Requires:       polkit'));
      expect(contents, contains('Requires:       systemd'));
      expect(contents, contains('License:        MIT'));
      expect(contents, contains('%license LICENSE'));
      expect(contents, contains('%{_libexecdir}/broom/broom-system-helper'));
      expect(
        contents,
        contains('%{_datadir}/polkit-1/actions/com.broom.Broom.policy'),
      );
      expect(contents, contains('%{_bindir}/broom'));
      expect(contents, contains('%{_libdir}/broom/'));
      expect(
        contents,
        contains(
          '%attr(0644,root,root) %{_datadir}/applications/'
          'com.broom.Broom.desktop',
        ),
      );
      expect(
        contents,
        contains(
          '%attr(0755,root,root) '
          '%{_libexecdir}/broom/broom-system-helper',
        ),
      );
      expect(
        contents,
        contains(
          '%attr(0644,root,root) '
          '%{_datadir}/polkit-1/actions/com.broom.Broom.policy',
        ),
      );
      expect(contents, contains('gtk-update-icon-cache'));
      expect(
        contents,
        contains('%{_datadir}/icons/hicolor/256x256/apps/broom.png'),
      );
      expect(
        contents,
        contains('%{_datadir}/icons/hicolor/512x512/apps/broom.png'),
      );
      expect(contents, contains('%doc README.md docs/linux-system-cache.md'));
    });

    test('spec keeps the helper path used by the Dart client', () {
      final source = File('lib/core/platform/linux_system_maintenance.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final contents = spec.readAsStringSync();

      expect(
        source,
        contains(
          'static const String defaultHelperPath =\n'
          "      '/usr/libexec/broom/broom-system-helper';",
        ),
      );
      expect(contents, contains('%{_libexecdir}/broom/broom-system-helper'));
      expect(contents, contains('%{_datadir}/polkit-1/actions/'));
    });

    test('build script uses rpmbuild and never installs or runs cleanup', () {
      expect(script.existsSync(), isTrue);
      final contents = script.readAsStringSync();

      expect(contents, contains('cmake -S linux/system_helper'));
      expect(contents, contains('rpmbuild -bb'));
      expect(contents, contains('sha256sum'));
      expect(contents, contains('--skip-flutter-build'));
      expect(contents, contains('stat -f -c %T'));
      expect(contents, contains('POSIX permissions'));
      expect(contents, contains('BROOM_RPM_SIGN_KEY'));
      expect(contents, contains('rpm --addsign'));
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*rpm\s+-i\b', multiLine: true))),
      );
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*dnf\s+install\b', multiLine: true))),
      );
      expect(
        contents,
        isNot(matches(RegExp(r'^\s*pkexec\b', multiLine: true))),
      );
      expect(contents, isNot(matches(RegExp(r'^\s*sudo\b', multiLine: true))));
    });
    test('Linux CI builds the RPM in a Fedora container', () {
      final workflow = File('.github/workflows/linux.yml').readAsStringSync();

      expect(workflow, contains('container: fedora:44'));
      expect(workflow, contains('broom-linux-bundle.tar.gz'));
      expect(
        workflow,
        contains('bash tool/package_rpm.sh --skip-flutter-build'),
      );
      expect(workflow, contains('%{LICENSE}'));
    });
  });
}
