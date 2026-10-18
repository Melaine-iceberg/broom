import 'dart:io';

import 'package:flutter/services.dart';

import '../models/system_models.dart';

class SystemAccessException implements Exception {
  const SystemAccessException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Native capabilities needed by the admin-only system cache tool: elevation
/// state, self-relaunch through UAC, and canonical system cache locations.
abstract interface class SystemAccess {
  Future<bool> isElevated();

  Future<bool> relaunchElevated();

  Future<SystemCacheRoots> locateSystemCacheRoots();
}

class MethodChannelSystemAccess implements SystemAccess {
  const MethodChannelSystemAccess();

  static const MethodChannel channel = MethodChannel('broom/system');

  @override
  Future<bool> isElevated() async {
    try {
      final result = await channel.invokeMethod<bool>('isElevated');
      return result ?? false;
    } on PlatformException catch (error) {
      throw _mapError(error, '无法确认管理员权限。');
    } on MissingPluginException {
      throw const SystemAccessException('当前系统不支持管理员模式。');
    }
  }

  @override
  Future<bool> relaunchElevated() async {
    try {
      final result = await channel.invokeMethod<bool>('relaunchElevated');
      return result ?? false;
    } on PlatformException catch (error) {
      if (error.code == 'elevation_cancelled') return false;
      throw _mapError(error, '无法以管理员身份重新启动。');
    } on MissingPluginException {
      throw const SystemAccessException('当前系统不支持管理员模式。');
    }
  }

  @override
  Future<SystemCacheRoots> locateSystemCacheRoots() async {
    try {
      final result = await channel.invokeMethod<Object?>('systemCacheRoots');
      if (result is! Map) {
        throw const SystemAccessException('无法定位系统缓存目录。');
      }
      final windowsUpdate = result['windowsUpdate'];
      final deliveryOptimization = result['deliveryOptimization'];
      final windowsOld = result['windowsOld'];
      if (windowsUpdate is! String ||
          deliveryOptimization is! String ||
          windowsOld is! String ||
          windowsUpdate.isEmpty ||
          deliveryOptimization.isEmpty ||
          windowsOld.isEmpty) {
        throw const SystemAccessException('系统缓存目录返回了无法识别的数据。');
      }
      return SystemCacheRoots(
        windowsUpdateDownload: windowsUpdate,
        deliveryOptimizationCache: deliveryOptimization,
        windowsOld: windowsOld,
      );
    } on PlatformException catch (error) {
      throw _mapError(error, '无法定位系统缓存目录。');
    } on MissingPluginException {
      throw const SystemAccessException('当前系统不支持系统缓存清理。');
    }
  }

  static SystemAccessException _mapError(
    PlatformException error,
    String fallback,
  ) {
    final details = error.details;
    if (details is int) {
      final code = details.toRadixString(16).toUpperCase().padLeft(8, '0');
      return SystemAccessException(
        '$fallback（Windows 错误 0x$code）',
        code: error.code,
      );
    }
    final message = error.message?.trim();
    return SystemAccessException(
      message == null || message.isEmpty ? fallback : message,
      code: error.code,
    );
  }
}

class UnsupportedSystemAccess implements SystemAccess {
  const UnsupportedSystemAccess();

  Never _unsupported() => throw const SystemAccessException('当前平台不支持系统级缓存清理。');

  @override
  Future<bool> isElevated() async => false;

  @override
  Future<SystemCacheRoots> locateSystemCacheRoots() async => _unsupported();

  @override
  Future<bool> relaunchElevated() async => _unsupported();
}

SystemAccess createSystemAccess() {
  if (Platform.isWindows) return const MethodChannelSystemAccess();
  return const UnsupportedSystemAccess();
}
