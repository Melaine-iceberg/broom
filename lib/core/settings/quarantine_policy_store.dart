import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/quarantine_policy_models.dart';
import '../safety/path_guard.dart';
import 'config_schema.dart';

class QuarantinePolicyException implements Exception {
  const QuarantinePolicyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class QuarantinePolicyStore {
  QuarantinePolicyStore({required this.filePath}) {
    if (!p.windows.isAbsolute(filePath)) {
      throw ArgumentError.value(filePath, 'filePath', '保留策略路径必须是绝对路径');
    }
  }

  static const fileName = 'quarantine_policy.json';

  static String defaultFilePath(String quarantineRoot) =>
      p.windows.join(p.windows.dirname(quarantineRoot), fileName);

  final String filePath;

  Future<QuarantineRetentionPolicy> load() async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return QuarantineRetentionPolicy.defaults;

      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('保留策略格式无效');
      }
      return decodeRetentionDocument(decoded);
    } on FormatException catch (error) {
      throw QuarantinePolicyException('保留策略数据无效：${error.message}');
    } on FileSystemException catch (error) {
      throw QuarantinePolicyException('无法读取保留策略：${error.message}');
    }
  }

  Future<void> save(QuarantineRetentionPolicy policy) async {
    if (!policy.isValid) {
      throw const QuarantinePolicyException('保留策略参数超出允许范围');
    }
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      final temp = File('$filePath.tmp');
      temp.writeAsStringSync(
        jsonEncode(encodeRetentionDocument(policy)),
        flush: true,
      );
      temp.renameSync(PathGuard.normalize(filePath));
    } on FileSystemException catch (error) {
      throw QuarantinePolicyException('无法保存保留策略：${error.message}');
    }
  }
}
