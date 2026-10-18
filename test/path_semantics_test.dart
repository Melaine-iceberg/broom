import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WindowsPathSemantics', () {
    const semantics = WindowsPathSemantics();

    test('normalizes case and separators for comparison', () {
      expect(
        semantics.key(r'C:\Users\Alice\Cache\..\Cache\file.tmp'),
        r'c:\users\alice\cache\file.tmp',
      );
      expect(semantics.same(r'C:\Cache\A.TMP', r'c:\cache\a.tmp'), isTrue);
    });

    test('does not confuse sibling prefixes with children', () {
      expect(semantics.isWithin(r'C:\Cache', r'c:\cache\sub\a.tmp'), isTrue);
      expect(semantics.isWithin(r'C:\Cache', r'C:\Cache2\a.tmp'), isFalse);
      expect(semantics.isWithin(r'C:\Cache', r'C:\Cache'), isTrue);
    });

    test('recognizes reserved DOS device names', () {
      expect(semantics.isReservedComponent('CON'), isTrue);
      expect(semantics.isReservedComponent('com1.txt'), isTrue);
      expect(semantics.isReservedComponent('console.txt'), isFalse);
    });
  });

  group('PosixPathSemantics', () {
    const semantics = PosixPathSemantics();

    test('keeps comparisons case-sensitive', () {
      expect(semantics.key('/var/cache'), '/var/cache');
      expect(semantics.same('/var/cache', '/VAR/cache'), isFalse);
    });

    test('uses forward slashes for containment', () {
      expect(semantics.isWithin('/var/cache', '/var/cache/app/a.tmp'), isTrue);
      expect(semantics.isWithin('/var/cache', '/var/cache2/a.tmp'), isFalse);
      expect(semantics.join('/var/cache', 'app'), '/var/cache/app');
      expect(semantics.separator, '/');
    });
  });

  test('PathGuard honors the injected path semantics', () {
    final guard = PathGuard(
      protectedRoots: const ['/var/log'],
      semantics: const PosixPathSemantics(),
    );

    expect(guard.isProtected('/var/log/app.log'), isTrue);
    expect(guard.isProtected('/VAR/log/app.log'), isFalse);
    expect(
      guard.allows(path: '/home/user/cache/a.tmp', root: '/home/user/cache'),
      isTrue,
    );
    expect(
      guard.allows(path: '/home/user/cache2/a.tmp', root: '/home/user/cache'),
      isFalse,
    );
  });
}
