import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../safety/path_guard.dart';
import 'config_schema.dart';

class SettingsException implements Exception {
  const SettingsException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SettingsStore {
  SettingsStore({required this.filePath}) {
    if (!p.windows.isAbsolute(filePath)) {
      throw ArgumentError.value(filePath, 'filePath', '设置文件路径必须是绝对路径');
    }
  }

  static const fileName = 'settings.json';

  static String defaultFilePath(String quarantineRoot) =>
      p.windows.join(p.windows.dirname(quarantineRoot), fileName);

  final String filePath;

  AppSettings load() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        // A missing settings file marks a fresh profile. Existing settings
        // files without the flag are treated as returning users.
        return AppSettings.defaults.copyWith(onboardingCompleted: false);
      }

      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('设置格式无效');
      }
      return decodeSettingsDocument(decoded);
    } on FormatException catch (error) {
      throw SettingsException('设置数据无效：${error.message}');
    } on FileSystemException catch (error) {
      throw SettingsException('无法读取设置：${error.message}');
    }
  }

  Future<void> save(AppSettings settings) async {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      final temp = File('$filePath.tmp');
      temp.writeAsStringSync(
        jsonEncode(encodeSettingsDocument(settings)),
        flush: true,
      );
      temp.renameSync(PathGuard.normalize(filePath));
    } on FileSystemException catch (error) {
      throw SettingsException('无法保存设置：${error.message}');
    }
  }
}
