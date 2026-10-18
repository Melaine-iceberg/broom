import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PathGuard', () {
    final guard = PathGuard(
      protectedRoots: [r'C:\Windows', r'C:\Program Files'],
    );

    test('accepts files inside the root and rejects the root itself', () {
      expect(
        guard.allows(
          path: r'C:\Users\Alice\AppData\Local\Temp\cache\file.tmp',
          root: r'C:\Users\Alice\AppData\Local\Temp',
        ),
        isTrue,
      );
      expect(
        guard.allows(
          path: r'C:\Users\Alice\AppData\Local\Temp',
          root: r'C:\Users\Alice\AppData\Local\Temp',
        ),
        isFalse,
      );
    });

    test('does not confuse a sibling prefix with a child path', () {
      expect(
        guard.isWithin(r'C:\Users\Alice\Cache', r'C:\Users\Alice\Cache2\x'),
        isFalse,
      );
      expect(
        guard.isWithin(r'C:\Users\Alice\Cache', r'c:\users\alice\cache\sub\x'),
        isTrue,
      );
    });

    test('rejects parent traversal outside the root', () {
      expect(
        guard.allows(
          path: r'C:\Users\Alice\Temp\..\..\Documents\secret.txt',
          root: r'C:\Users\Alice\Temp',
        ),
        isFalse,
      );
    });

    test('rejects protected Windows and Program Files paths', () {
      expect(
        guard.allows(
          path: r'C:\Windows\Temp\file.tmp',
          root: r'C:\Windows\Temp',
        ),
        isFalse,
      );
      expect(guard.isProtected(r'c:\program files\app\data.bin'), isTrue);
      expect(guard.isProtected(r'C:\Users\Alice\file.bin'), isFalse);
    });

    test('builds protected roots from a case-insensitive environment', () {
      final fromEnv = PathGuard.forWindows(
        environment: {
          'windir': r'C:\Windows',
          'PROGRAMFILES': r'C:\Program Files',
          'ProgramData': r'C:\ProgramData',
        },
      );
      expect(fromEnv.isProtected(r'C:\ProgramData\vendor\cache'), isTrue);
      expect(fromEnv.isProtected(r'C:\Users\Alice\cache'), isFalse);
    });
  });
}
