import 'package:broom/core/platform/path_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('is stable and stays a positive 62-bit value', () {
    final value = pathFingerprint(r'c:\users\alice\appdata\local\temp\a.tmp');
    expect(value, pathFingerprint(r'c:\users\alice\appdata\local\temp\a.tmp'));
    expect(value, greaterThanOrEqualTo(0));
    expect(value, lessThanOrEqualTo(0x3fffffffffffffff));
  });

  test('separates realistic paths without collisions', () {
    const folders = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
    final fingerprints = <int>{
      for (var index = 0; index < 200000; index++)
        pathFingerprint(
          'c:\\users\\alice\\appdata\\local\\temp\\'
          '${folders[index % folders.length]}\\sub${index % 97}\\'
          'file-$index.tmp',
        ),
    };
    expect(fingerprints, hasLength(200000));
  });
}
