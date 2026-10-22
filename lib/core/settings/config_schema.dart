import '../models/app_settings.dart';
import '../models/quarantine_policy_models.dart';
import '../platform/path_semantics.dart';

/// Current on-disk schema shared by the user configuration files.
///
/// Version history:
/// - 1: initial versioned layout. The three files had no document kind.
/// - 2: adds a stable `kind` discriminator so a settings document cannot be
///   loaded as an exclusion list (or vice versa), and centralizes migrations.
///   Field layouts are otherwise unchanged.
const int currentConfigSchemaVersion = 2;

/// Oldest configuration version the migrator knows how to upgrade.
const int minConfigSchemaVersion = 1;

const String settingsDocumentKind = 'broom.settings';
const String exclusionsDocumentKind = 'broom.exclusions';
const String retentionDocumentKind = 'broom.quarantine-policy';

/// Validates the schema envelope and upgrades a configuration document.
///
/// A missing version, a version outside the supported range, or a v2 document
/// with the wrong kind is rejected instead of guessed at. Version 1 files are
/// upgraded in memory; the migrated form is written on the next save.
Map<String, dynamic> migrateConfigDocument(
  Map<String, dynamic> raw, {
  required String kind,
  required String label,
}) {
  final rawVersion = raw['schemaVersion'];
  final int version;
  if (rawVersion is int) {
    version = rawVersion;
  } else if (rawVersion == null) {
    throw FormatException('$label缺少 schemaVersion');
  } else {
    throw FormatException('$label版本号无效：$rawVersion');
  }

  if (version < minConfigSchemaVersion) {
    throw FormatException('不支持的$label版本：$version');
  }
  if (version > currentConfigSchemaVersion) {
    throw FormatException(
      '不支持的$label版本：$version'
      '（当前支持版本 $currentConfigSchemaVersion，请升级 Broom 后再读取）',
    );
  }

  final migrated = Map<String, dynamic>.of(raw);
  if (version < 2) {
    migrated['kind'] = kind;
  } else if (migrated['kind'] != kind) {
    throw FormatException('$label类型无效：${migrated['kind']}');
  }
  migrated['schemaVersion'] = currentConfigSchemaVersion;
  return migrated;
}

Map<String, dynamic> encodeSettingsDocument(AppSettings settings) {
  return {
    'kind': settingsDocumentKind,
    'schemaVersion': currentConfigSchemaVersion,
    'theme': settings.theme.name,
    'language': settings.language.name,
    'disabledRuleIds': settings.disabledRuleIds.toList()..sort(),
    'disabledCategoryIds': settings.disabledCategoryIds.toList()..sort(),
    'scanParallelism': settings.scanParallelism,
    'scanLowPriority': settings.scanLowPriority,
    'useNtfsIndex': settings.useNtfsIndex,
    'scanItemLimit': settings.scanItemLimit,
    'ruleUpdateUrl': settings.ruleUpdateUrl,
    'onboardingCompleted': settings.onboardingCompleted,
    'diagnosticsEnabled': settings.diagnosticsEnabled,
  };
}

AppSettings decodeSettingsDocument(Map<String, dynamic> raw) {
  final migrated = migrateConfigDocument(
    raw,
    kind: settingsDocumentKind,
    label: '设置文件',
  );

  final theme = _parseTheme(migrated['theme']);
  final language = _parseLanguage(migrated['language']);
  final disabled = _parseStringSet(migrated['disabledRuleIds'], '规则开关数据无效');
  final disabledCategories = _parseStringSet(
    migrated['disabledCategoryIds'],
    '扫描类别数据无效',
  );
  final parallelism = migrated['scanParallelism'];
  final lowPriority = migrated['scanLowPriority'];
  final ntfsIndex = migrated['useNtfsIndex'];
  final itemLimit = migrated['scanItemLimit'];
  final updateUrl = migrated['ruleUpdateUrl'];
  final onboardingCompleted = migrated['onboardingCompleted'];
  final diagnosticsEnabled = migrated['diagnosticsEnabled'];
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
  if (onboardingCompleted != null && onboardingCompleted is! bool) {
    throw const FormatException('首次使用引导状态无效');
  }
  if (diagnosticsEnabled != null && diagnosticsEnabled is! bool) {
    throw const FormatException('诊断日志设置无效');
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
    onboardingCompleted: onboardingCompleted as bool? ?? true,
    diagnosticsEnabled: diagnosticsEnabled as bool? ?? false,
  );
}

Map<String, dynamic> encodeExclusionsDocument(Iterable<String> paths) {
  return {
    'kind': exclusionsDocumentKind,
    'schemaVersion': currentConfigSchemaVersion,
    'paths': paths.toList(),
  };
}

/// Decodes exclusion paths without requiring the folders to exist.
///
/// Imported configurations may be restored before an external drive is
/// connected, so existence is checked only when adding exclusions through the
/// UI. Paths are normalized, deduplicated and rejected when relative or when
/// they point at a volume or share root.
List<String> decodeExclusionsDocument(
  Map<String, dynamic> raw, {
  PathSemantics? semantics,
}) {
  final resolved = semantics ?? PathSemanticsFactory.forCurrentPlatform();
  final migrated = migrateConfigDocument(
    raw,
    kind: exclusionsDocumentKind,
    label: '排除列表',
  );
  final rawPaths = migrated['paths'];
  if (rawPaths is! List) {
    throw const FormatException('排除列表缺少路径数据');
  }

  final byKey = <String, String>{};
  for (final rawPath in rawPaths) {
    if (rawPath is! String || rawPath.trim().isEmpty) {
      throw const FormatException('排除列表包含无效路径');
    }
    final normalized = _normalizeExclusionPath(rawPath, resolved);
    byKey.putIfAbsent(resolved.key(normalized), () => normalized);
  }
  final paths = byKey.values.toList()
    ..sort(
      (first, second) => resolved.key(first).compareTo(resolved.key(second)),
    );
  return paths;
}

String _normalizeExclusionPath(String rawPath, PathSemantics semantics) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('排除路径不能为空');
  }
  if (!semantics.isAbsolute(trimmed)) {
    throw FormatException('排除路径必须是绝对路径：$trimmed');
  }
  final normalized = semantics.normalize(semantics.absolute(trimmed));
  if (semantics.rootPrefix(normalized) == normalized) {
    throw FormatException('不能排除整个磁盘或共享根目录：$trimmed');
  }
  return normalized;
}

Map<String, dynamic> encodeRetentionDocument(QuarantineRetentionPolicy policy) {
  return {
    'kind': retentionDocumentKind,
    'schemaVersion': currentConfigSchemaVersion,
    'enabled': policy.enabled,
    'retentionDays': policy.retentionDays,
    'maxBytes': policy.maxBytes,
  };
}

QuarantineRetentionPolicy decodeRetentionDocument(Map<String, dynamic> raw) {
  final migrated = migrateConfigDocument(
    raw,
    kind: retentionDocumentKind,
    label: '保留策略',
  );
  final enabled = migrated['enabled'];
  final retentionDays = migrated['retentionDays'];
  final maxBytes = migrated['maxBytes'];
  if (enabled is! bool || retentionDays is! int || maxBytes is! int) {
    throw const FormatException('保留策略缺少有效参数');
  }

  final policy = QuarantineRetentionPolicy(
    enabled: enabled,
    retentionDays: retentionDays,
    maxBytes: maxBytes,
  );
  if (!policy.isValid) {
    throw const FormatException('保留策略参数超出允许范围');
  }
  return policy;
}

Set<String> _parseStringSet(Object? raw, String error) {
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

AppThemePreference _parseTheme(Object? value) {
  return switch (value) {
    'system' => AppThemePreference.system,
    'light' => AppThemePreference.light,
    'dark' => AppThemePreference.dark,
    _ => throw const FormatException('主题设置无效'),
  };
}

AppLanguagePreference _parseLanguage(Object? value) {
  return switch (value) {
    'system' => AppLanguagePreference.system,
    'zh' => AppLanguagePreference.zh,
    'en' => AppLanguagePreference.en,
    _ => throw const FormatException('语言设置无效'),
  };
}
