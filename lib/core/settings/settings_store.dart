import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../safety/path_guard.dart';

const _schemaVersion = 1;

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
      if (!file.existsSync()) return AppSettings.defaults;

      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('设置格式无效');
      }
      final version = decoded['schemaVersion'];
      if (version != _schemaVersion) {
        throw FormatException('不支持的设置版本：$version');
      }

      final theme = _parseTheme(decoded['theme']);
      final language = _parseLanguage(decoded['language']);
      final rawDisabled = decoded['disabledRuleIds'];
      final disabled = <String>{};
      if (rawDisabled != null) {
        if (rawDisabled is! List) {
          throw const FormatException('规则开关数据无效');
        }
        for (final value in rawDisabled) {
          if (value is! String || value.trim().isEmpty) {
            throw const FormatException('规则开关数据无效');
          }
          disabled.add(value);
        }
      }
      return AppSettings(
        theme: theme,
        language: language,
        disabledRuleIds: Set.unmodifiable(disabled),
      );
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
        jsonEncode({
          'schemaVersion': _schemaVersion,
          'theme': settings.theme.name,
          'language': settings.language.name,
          'disabledRuleIds': settings.disabledRuleIds.toList()..sort(),
        }),
        flush: true,
      );
      temp.renameSync(PathGuard.normalize(filePath));
    } on FileSystemException catch (error) {
      throw SettingsException('无法保存设置：${error.message}');
    }
  }

  static AppThemePreference _parseTheme(Object? value) {
    return switch (value) {
      'system' => AppThemePreference.system,
      'light' => AppThemePreference.light,
      'dark' => AppThemePreference.dark,
      _ => throw const FormatException('主题设置无效'),
    };
  }

  static AppLanguagePreference _parseLanguage(Object? value) {
    return switch (value) {
      'system' => AppLanguagePreference.system,
      'zh' => AppLanguagePreference.zh,
      'en' => AppLanguagePreference.en,
      _ => throw const FormatException('语言设置无效'),
    };
  }
}
