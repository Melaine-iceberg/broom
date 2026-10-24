import 'dart:io';

import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';

final _windowsOnly = !Platform.isWindows;

void main() {
  group('PathGuard', () {
    final guard = PathGuard(
      protectedRoots: [r'C:\Windows', r'C:\Program Files'],
      semantics: const WindowsPathSemantics(),
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

    test('normalizes extended-length paths before comparing', () {
      expect(
        PathGuard.normalize(r'\\?\C:\Users\Alice\Temp\..\Temp\file.tmp'),
        r'C:\Users\Alice\Temp\file.tmp',
      );
      expect(
        guard.allows(
          path: r'\\?\C:\Users\Alice\Temp\cache\file.tmp',
          root: r'C:\Users\Alice\Temp',
        ),
        isTrue,
      );
      expect(guard.isProtected(r'\\?\C:\Windows\Temp\file.tmp'), isTrue);
    }, skip: _windowsOnly);

    test('handles UNC roots without matching sibling shares', () {
      final uncGuard = PathGuard(
        protectedRoots: [r'\\server\share\Windows'],
        semantics: const WindowsPathSemantics(),
      );

      expect(
        uncGuard.allows(
          path: r'\\server\share\cache\file.tmp',
          root: r'\\server\share\cache',
        ),
        isTrue,
      );
      expect(
        uncGuard.allows(
          path: r'\\server\share2\cache\file.tmp',
          root: r'\\server\share\cache',
        ),
        isFalse,
      );
      expect(
        uncGuard.allows(
          path: r'\\server\share\cache',
          root: r'\\server\share\cache',
        ),
        isFalse,
      );
      expect(
        uncGuard.isWithin(
          r'\\server\share\cache',
          r'\\SERVER\Share\Cache\sub\file.tmp',
        ),
        isTrue,
      );
      expect(uncGuard.isProtected(r'\\server\share\Windows\file.dll'), isTrue);
      expect(
        uncGuard.isProtected(r'\\server\share\WindowsApps\file.dll'),
        isFalse,
      );
      expect(
        uncGuard.allows(
          path: r'\\?\UNC\server\share\cache\file.tmp',
          root: r'\\server\share\cache',
        ),
        isTrue,
      );
    });
  });
}
