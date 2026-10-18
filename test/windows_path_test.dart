import 'dart:io';

import 'package:broom/core/platform/windows_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final windowsOnly = Platform.isWindows ? false : 'Windows only';

  test('strips extended-length prefixes to the canonical form', () {
    expect(WindowsPath.canonical(r'C:\cache\a.tmp'), r'C:\cache\a.tmp');
    expect(WindowsPath.canonical(r'\\?\C:\cache\a.tmp'), r'C:\cache\a.tmp');
    expect(
      WindowsPath.canonical(r'\\?\UNC\server\share\cache\a.tmp'),
      r'\\server\share\cache\a.tmp',
    );
    expect(
      WindowsPath.canonical(r'\\?\unc\server\share\cache\a.tmp'),
      r'\\server\share\cache\a.tmp',
    );
  });

  test('converts long local paths to the extended namespace', () {
    final longPath = 'C:\\cache\\${'a' * 300}\\file.tmp';
    final extended = WindowsPath.extended(longPath);
    expect(extended, r'\\?\C:\cache\' + 'a' * 300 + r'\file.tmp');
    expect(WindowsPath.extended(extended), extended);
    expect(WindowsPath.canonical(extended), longPath);
  }, skip: windowsOnly);

  test('converts long UNC paths to the extended UNC namespace', () {
    final longPath = '\\\\server\\share\\${'b' * 300}\\file.tmp';
    final extended = WindowsPath.extended(longPath);
    expect(extended, r'\\?\UNC\server\share\' + 'b' * 300 + r'\file.tmp');
    expect(WindowsPath.canonical(extended), longPath);
  }, skip: windowsOnly);

  test('leaves short paths alone and extends only long ones', () {
    expect(WindowsPath.forIo(r'C:\cache\a.tmp'), r'C:\cache\a.tmp');
    final longPath = p.windows.join(r'C:\cache', 'c' * 300, 'a.tmp');
    expect(WindowsPath.forIo(longPath), WindowsPath.extended(longPath));
    expect(
      WindowsPath.forIo(WindowsPath.extended(longPath)),
      WindowsPath.extended(longPath),
    );
    expect(
      WindowsPath.forIo(r'\\server\share\cache\a.tmp'),
      r'\\server\share\cache\a.tmp',
    );
  }, skip: windowsOnly);
}
