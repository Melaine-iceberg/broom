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
      final disabled = _parseStringSet(decoded['disabledRuleIds'], '规则开关数据无效');
      final disabledCategories = _parseStringSet(
        decoded['disabledCategoryIds'],
        '扫描类别数据无效',
      );
      final parallelism = decoded['scanParallelism'];
      final lowPriority = decoded['scanLowPriority'];
      final ntfsIndex = decoded['useNtfsIndex'];
      final itemLimit = decoded['scanItemLimit'];
      final updateUrl = decoded['ruleUpdateUrl'];
      if (parallelism != null &&
          (parallelism is! int || parallelism < 0 || parallelism > 16)) {
        throw const FormatException('扫描线程数无效');
      }
      if (lowPriority != null && lowPriority is! bool) {
        throw const FormatException('低优先级设置无效');
      }
      if (ntfsIndex != null && ntfsIndex is! bool) {
        throw const FormatException('NTFS 索引设置无效');
      }
      if (itemLimit != null &&
          (itemLimit is! int || itemLimit < 1 || itemLimit > 100000000)) {
        throw const FormatException('扫描结果上限无效');
      }
      if (updateUrl != null && updateUrl is! String) {
        throw const FormatException('规则更新地址无效');
      }
      return AppSettings(
        theme: theme,
        language: language,
        disabledRuleIds: Set.unmodifiable(disabled),
        disabledCategoryIds: Set.unmodifiable(disabledCategories),
        scanParallelism: parallelism as int? ?? 2,
        scanLowPriority: lowPriority as bool? ?? true,
        useNtfsIndex: ntfsIndex as bool? ?? false,
        scanItemLimit: itemLimit as int?,
        ruleUpdateUrl: updateUrl as String? ?? '',
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
          'disabledCategoryIds': settings.disabledCategoryIds.toList()..sort(),
          'scanParallelism': settings.scanParallelism,
          'scanLowPriority': settings.scanLowPriority,
          'useNtfsIndex': settings.useNtfsIndex,
          'scanItemLimit': settings.scanItemLimit,
          'ruleUpdateUrl': settings.ruleUpdateUrl,
        }),
        flush: true,
      );
      temp.renameSync(PathGuard.normalize(filePath));
    } on FileSystemException catch (error) {
      throw SettingsException('无法保存设置：${error.message}');
    }
  }

  static Set<String> _parseStringSet(Object? raw, String error) {
    final values = <String>{};
    if (raw == null) return values;
    if (raw is! List) throw FormatException(error);
    for (final value in raw) {
      if (value is! String || value.trim().isEmpty) {
        throw FormatException(error);
      }
      values.add(value);
    }
    return values;
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
