import 'dart:io';

import 'package:broom/core/platform/filesystem_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FileSystemException withCode(int code) => FileSystemException(
    'operation failed',
    r'C:\cache\file.tmp',
    OSError('system error', code),
  );

  test('maps read-only media and network errors', () {
    expect(describeFilesystemError(withCode(19)), contains('只读'));
    expect(describeFilesystemError(withCode(53)), contains('网络路径'));
    expect(describeFilesystemError(withCode(64)), contains('网络连接'));
    expect(describeFilesystemError(withCode(67)), contains('网络路径'));
  });

  test('maps common file system errors', () {
    expect(describeFilesystemError(withCode(2)), '文件或目录不存在');
    expect(describeFilesystemError(withCode(3)), '文件或目录不存在');
    expect(describeFilesystemError(withCode(5)), '没有访问权限');
    expect(describeFilesystemError(withCode(32)), '文件正被其他程序占用');
    expect(describeFilesystemError(withCode(33)), '文件正被其他程序占用');
    expect(describeFilesystemError(withCode(50)), '文件系统不支持该操作');
    expect(describeFilesystemError(withCode(112)), '磁盘空间不足');
    expect(describeFilesystemError(withCode(123)), '文件名或路径格式无效');
  });

  test('keeps explicit reasons and falls back to the exception message', () {
    expect(describeFilesystemError('位于排除列表中，已跳过'), '位于排除列表中，已跳过');
    expect(
      describeFilesystemError(withCode(9999)),
      contains('operation failed'),
    );
  });
}
