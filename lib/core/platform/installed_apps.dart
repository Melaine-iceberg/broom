import 'dart:io';

import 'package:flutter/services.dart';

import '../models/leftover_models.dart';

class InstalledAppsException implements Exception {
  const InstalledAppsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Read-only access to the applications registered with Windows.
abstract interface class InstalledApps {
  Future<InstalledAppInventory> list();
}

class MethodChannelInstalledApps implements InstalledApps {
  const MethodChannelInstalledApps();

  static const MethodChannel channel = MethodChannel('broom/apps');

  @override
  Future<InstalledAppInventory> list() async {
    try {
      final result = await channel.invokeMethod<Object?>('list');
      return _decode(result);
    } on PlatformException catch (error) {
      throw _mapError(error, '无法读取已安装应用清单。');
    } on MissingPluginException {
      throw const InstalledAppsException('当前系统不支持读取已安装应用清单。');
    }
  }

  InstalledAppInventory _decode(Object? value) {
    if (value is! Map) {
      throw const InstalledAppsException('已安装应用清单返回了无法识别的数据。');
    }
    final rawApps = value['apps'];
    if (rawApps is! List) {
      throw const InstalledAppsException('已安装应用清单缺少应用列表。');
    }

    final apps = <InstalledApp>[];
    for (final raw in rawApps) {
      if (raw is! Map) {
        throw const InstalledAppsException('已安装应用清单包含无法识别的条目。');
      }
      final displayName = raw['displayName'];
      if (displayName is! String || displayName.trim().isEmpty) {
        throw const InstalledAppsException('已安装应用清单包含无效的应用名称。');
      }
      apps.add(
        InstalledApp(
          displayName: displayName.trim(),
          publisher: _optionalString(raw['publisher']),
          installLocation: _optionalString(raw['installLocation']),
          uninstallKey: _optionalString(raw['uninstallKey']),
          scope: _scope(raw['scope']),
        ),
      );
    }

    final error = _optionalString(value['error']);
    return InstalledAppInventory(
      apps: List.unmodifiable(apps),
      complete: value['complete'] == true && error == null,
      error: error,
    );
  }

  static InstalledAppScope _scope(Object? value) => switch (value) {
    'user' => InstalledAppScope.user,
    'machine' => InstalledAppScope.machine,
    _ => InstalledAppScope.unknown,
  };

  static String? _optionalString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static InstalledAppsException _mapError(
    PlatformException error,
    String fallback,
  ) {
    final details = error.details;
    final suffix = details is int
        ? '（Windows 错误 0x${details.toRadixString(16).toUpperCase().padLeft(8, '0')}）'
        : '';
    final message = error.message?.trim();
    return InstalledAppsException(
      message == null || message.isEmpty
          ? '$fallback$suffix'
          : '$message$suffix',
    );
  }
}

class UnsupportedInstalledApps implements InstalledApps {
  const UnsupportedInstalledApps();

  @override
  Future<InstalledAppInventory> list() async => const InstalledAppInventory(
    apps: [],
    complete: false,
    error: '当前平台不支持读取已安装应用清单。',
  );
}

InstalledApps createInstalledApps() {
  if (Platform.isWindows) return const MethodChannelInstalledApps();
  return const UnsupportedInstalledApps();
}
