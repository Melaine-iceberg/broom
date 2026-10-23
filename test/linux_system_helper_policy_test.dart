import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Polkit policy template binds the helper through pkexec', () {
    final policy = File('linux/system_helper/policy/com.broom.Broom.policy.in');
    expect(policy.existsSync(), isTrue);
    final xml = policy.readAsStringSync();

    expect(xml, contains('com.broom.Broom.clean-system-cache'));
    expect(xml, contains('org.freedesktop.policykit.exec.path'));
    expect(xml, contains('@BROOM_HELPER_INSTALL_PATH@'));
    expect(xml, contains('<allow_any>no</allow_any>'));
    expect(xml, contains('<allow_inactive>no</allow_inactive>'));
    expect(xml, contains('<allow_active>auth_admin</allow_active>'));
    expect(xml, isNot(contains('auth_self')));
    expect(xml, isNot(contains('<allow_any>yes</allow_any>')));
  });
}
