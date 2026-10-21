import 'dart:io';

import 'package:flutter/services.dart';

import '../app_info.dart';

/// Reads the version stamped into the executable at build time.
///
/// The native runner compiles `FLUTTER_VERSION` from `pubspec.yaml`, so this
/// matches the MSIX identity without having to query the package graph — which
/// would only work for packaged (MSIX) installs and fail for the portable ZIP.
abstract interface class AppVersionSource {
  Future<String?> read();
}

class MethodChannelAppVersion implements AppVersionSource {
  const MethodChannelAppVersion();

  static const MethodChannel channel = MethodChannel('broom/system');

  @override
  Future<String?> read() async {
    try {
      final value = await channel.invokeMethod<String>('appVersion');
      final trimmed = value?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class StaticAppVersion implements AppVersionSource {
  const StaticAppVersion(this.value);

  final String? value;

  @override
  Future<String?> read() async => value;
}

AppVersionSource createAppVersionSource() {
  if (Platform.isWindows) return const MethodChannelAppVersion();
  // Non-Windows platforms only see this build for development and tests; the
  // constant in app_info.dart is the documented mirror of pubspec.yaml.
  return const StaticAppVersion(broomAppVersion);
}
