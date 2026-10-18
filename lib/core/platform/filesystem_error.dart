import 'dart:io';

/// Maps common Win32 filesystem errors to short messages. Codes that matter
/// for special filesystems (read-only media, network paths, disk-full) are
/// called out explicitly so reports distinguish them from generic I/O errors.
String describeFilesystemError(Object error) {
  if (error is String) return error;
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    final mapped = _messages[code];
    if (mapped != null) return mapped;
    final message = error.message.trim();
    return message.isEmpty ? '文件操作失败' : message;
  }
  return error.toString();
}

/// True when another handle blocks the access Broom needs (to read, move or
/// delete). These are transient skips rather than hard failures.
bool isFileLockConflict(Object error) {
  if (error is! FileSystemException) return false;
  final code = error.osError?.errorCode;
  return code == 32 || code == 33;
}

const _messages = <int, String>{
  2: '文件或目录不存在',
  3: '文件或目录不存在',
  5: '没有访问权限',
  19: '目标介质为只读（写保护）',
  21: '设备未就绪',
  32: '文件正被其他程序占用',
  33: '文件正被其他程序占用',
  50: '文件系统不支持该操作',
  53: '找不到网络路径',
  64: '网络连接已断开',
  67: '找不到网络路径',
  112: '磁盘空间不足',
  123: '文件名或路径格式无效',
};
