import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../models/quarantine_policy_models.dart';
import 'config_schema.dart';

/// A portable snapshot of Broom's user configuration.
///
/// Quarantine entries, clean history, scan results, and the online rule catalog
/// are deliberately not part of a bundle: restoring preferences must never
/// move, delete, or replace those files.
class ConfigBundle {
  const ConfigBundle({
    required this.settings,
    required this.exclusions,
    required this.retention,
    this.exportedAt,
  });

  final AppSettings settings;
  final List<String> exclusions;
  final QuarantineRetentionPolicy retention;
  final DateTime? exportedAt;
}

class ConfigBundleException implements Exception {
  const ConfigBundleException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ConfigTransferException implements Exception {
  const ConfigTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ConfigBundleCodec {
  static const String kind = 'broom-config';
  static const int currentSchemaVersion = 1;

  /// Encodes the bundle with readable formatting so it can be inspected and
  /// manually edited before importing.
  static String encode(ConfigBundle bundle, {DateTime? exportedAt}) {
    final encoded = <String, Object?>{
      'kind': kind,
      'schemaVersion': currentSchemaVersion,
      'exportedAt': (exportedAt ?? bundle.exportedAt ?? DateTime.now())
          .toUtc()
          .toIso8601String(),
      'settings': encodeSettingsDocument(bundle.settings),
      'exclusions': encodeExclusionsDocument(bundle.exclusions),
      'quarantinePolicy': encodeRetentionDocument(bundle.retention),
    };
    return '${const JsonEncoder.withIndent('  ').convert(encoded)}\n';
  }

  static ConfigBundle decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const ConfigBundleException('配置文件不是有效的 JSON。');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ConfigBundleException('配置文件格式无效。');
    }
    if (decoded['kind'] != kind) {
      throw const ConfigBundleException('这不是 Broom 配置文件，未进行任何修改。');
    }

    final rawVersion = decoded['schemaVersion'];
    if (rawVersion is! int) {
      throw const ConfigBundleException('配置文件缺少有效的版本号。');
    }
    if (rawVersion < 1) {
      throw ConfigBundleException('不支持的配置文件版本：$rawVersion');
    }
    if (rawVersion > currentSchemaVersion) {
      throw ConfigBundleException(
        '配置文件版本 $rawVersion 高于当前支持版本 '
        '$currentSchemaVersion，请升级 Broom 后再导入。',
      );
    }

    final rawSettings = decoded['settings'];
    final rawExclusions = decoded['exclusions'];
    final rawRetention = decoded['quarantinePolicy'];
    if (rawSettings is! Map<String, dynamic> ||
        rawExclusions is! Map<String, dynamic> ||
        rawRetention is! Map<String, dynamic>) {
      throw const ConfigBundleException('配置文件缺少设置、排除列表或保留策略。');
    }

    try {
      final exportedAt = DateTime.tryParse(
        decoded['exportedAt'] is String ? decoded['exportedAt'] as String : '',
      );
      return ConfigBundle(
        settings: decodeSettingsDocument(rawSettings),
        exclusions: decodeExclusionsDocument(rawExclusions),
        retention: decodeRetentionDocument(rawRetention),
        exportedAt: exportedAt,
      );
    } on FormatException catch (error) {
      throw ConfigBundleException('配置数据无效：${error.message}');
    }
  }
}

class ConfigTransferService {
  const ConfigTransferService();

  /// A configuration file is small; this limit keeps a mistaken selection from
  /// being read into memory. It also bounds imported exclusion lists.
  static const int maxImportBytes = 1024 * 1024;

  Future<void> exportTo({
    required String filePath,
    required ConfigBundle bundle,
  }) async {
    if (!p.windows.isAbsolute(filePath)) {
      throw const ConfigTransferException('导出路径必须是绝对路径。');
    }
    final content = ConfigBundleCodec.encode(bundle);
    if (utf8.encode(content).length > maxImportBytes) {
      throw const ConfigTransferException('配置超过 1 MiB，无法导出。请减少排除目录后重试。');
    }
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      final temp = File('$filePath.tmp');
      temp.writeAsStringSync(content, flush: true);
      temp.renameSync(filePath);
    } on FileSystemException catch (error) {
      throw ConfigTransferException('无法写入配置文件：${error.message}');
    }
  }

  Future<ConfigBundle> importFrom(String filePath) async {
    if (!p.windows.isAbsolute(filePath)) {
      throw const ConfigTransferException('导入路径必须是绝对路径。');
    }
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw const ConfigTransferException('找不到所选配置文件。');
      }
      if (file.lengthSync() > maxImportBytes) {
        throw const ConfigTransferException('配置文件超过 1 MiB，已拒绝导入。');
      }
      return ConfigBundleCodec.decode(file.readAsStringSync());
    } on FileSystemException catch (error) {
      throw ConfigTransferException('无法读取配置文件：${error.message}');
    } on FormatException {
      throw const ConfigTransferException('配置文件不是有效的 UTF-8 文本。');
    }
  }
}
