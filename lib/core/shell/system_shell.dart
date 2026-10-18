import 'dart:io';

import 'package:flutter/services.dart';

class RecycleBinSnapshot {
  const RecycleBinSnapshot({required this.itemCount, required this.totalBytes});

  final int itemCount;
  final int totalBytes;

  bool get isEmpty => itemCount <= 0;
}

class SystemShellException implements Exception {
  const SystemShellException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Narrow bridge to Windows shell features that Dart cannot access directly.
abstract interface class SystemShell {
  Future<RecycleBinSnapshot> queryRecycleBin();

  Future<void> emptyRecycleBin();

  Future<String?> pickFolder({String? initialDirectory});

  Future<void> revealPath(String path);
}

class MethodChannelSystemShell implements SystemShell {
  const MethodChannelSystemShell();

  static const MethodChannel channel = MethodChannel('broom/shell');

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async {
    try {
      final result = await channel.invokeMethod<Object?>('queryRecycleBin');
      if (result is! Map) {
        throw const SystemShellException('无法读取回收站信息。');
      }
      final itemCount = result['itemCount'];
      final totalBytes = result['totalBytes'];
      if (itemCount is! int || totalBytes is! int) {
        throw const SystemShellException('回收站返回了无法识别的数据。');
      }
      return RecycleBinSnapshot(itemCount: itemCount, totalBytes: totalBytes);
    } on PlatformException catch (error) {
      throw _mapError(error, '无法读取回收站信息。');
    } on MissingPluginException {
      throw const SystemShellException('当前系统不支持读取回收站。');
    }
  }

  @override
  Future<void> emptyRecycleBin() async {
    try {
      await channel.invokeMethod<void>('emptyRecycleBin');
    } on PlatformException catch (error) {
      throw _mapError(error, '无法清空回收站。');
    } on MissingPluginException {
      throw const SystemShellException('当前系统不支持清空回收站。');
    }
  }

  @override
  Future<String?> pickFolder({String? initialDirectory}) async {
    try {
      final result = await channel.invokeMethod<String>(
        'pickFolder',
        initialDirectory == null
            ? null
            : {'initialDirectory': initialDirectory},
      );
      return result == null || result.isEmpty ? null : result;
    } on PlatformException catch (error) {
      throw _mapError(error, '无法打开文件夹选择器。');
    } on MissingPluginException {
      throw const SystemShellException('当前系统不支持选择文件夹。');
    }
  }

  @override
  Future<void> revealPath(String path) async {
    try {
      await channel.invokeMethod<void>('revealPath', {'path': path});
    } on PlatformException catch (error) {
      throw _mapError(error, '无法在资源管理器中显示该文件。');
    } on MissingPluginException {
      throw const SystemShellException('当前系统不支持打开文件位置。');
    }
  }

  static SystemShellException _mapError(
    PlatformException error,
    String fallback,
  ) {
    final details = error.details;
    if (details is int) {
      final code = details.toRadixString(16).toUpperCase().padLeft(8, '0');
      return SystemShellException(
        '$fallback（Windows 错误 0x$code）',
        code: error.code,
      );
    }
    final message = error.message?.trim();
    return SystemShellException(
      message == null || message.isEmpty ? fallback : message,
      code: error.code,
    );
  }
}

class UnsupportedSystemShell implements SystemShell {
  const UnsupportedSystemShell();

  Never _unsupported() => throw const SystemShellException('当前平台不支持此操作。');

  @override
  Future<void> emptyRecycleBin() async => _unsupported();

  @override
  Future<String?> pickFolder({String? initialDirectory}) async =>
      _unsupported();

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async => _unsupported();

  @override
  Future<void> revealPath(String path) async => _unsupported();
}

SystemShell createSystemShell() {
  if (Platform.isWindows) return const MethodChannelSystemShell();
  return const UnsupportedSystemShell();
}
