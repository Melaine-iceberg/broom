/// Current on-disk schema for `session.json`.
///
/// Version history:
/// - 1: initial versioned format (status, counts, plan/remaining metadata).
/// - 2: adds cumulative `skippedCount` and `updatedAt`.
const int currentQuarantineSessionSchemaVersion = 2;

/// Oldest version the migrator knows how to upgrade.
const int minQuarantineSessionSchemaVersion = 1;

/// Thrown when a session file cannot be interpreted safely.
class QuarantineSessionFormatException implements Exception {
  const QuarantineSessionFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Upgrades a decoded `session.json` map to [currentQuarantineSessionSchemaVersion].
///
/// Unknown or newer versions are rejected instead of guessed at, so a future
/// Broom build cannot silently corrupt or restore files from a session format
/// it does not understand. A missing `schemaVersion` is treated as the legacy
/// v1 layout written before the field was introduced.
Map<String, dynamic> migrateQuarantineSessionJson(Map<String, dynamic> raw) {
  final rawVersion = raw['schemaVersion'];
  final int version;
  if (rawVersion == null) {
    version = 1;
  } else if (rawVersion is int) {
    version = rawVersion;
  } else {
    throw QuarantineSessionFormatException('隔离区记录版本号无效：$rawVersion');
  }

  if (version < minQuarantineSessionSchemaVersion) {
    throw QuarantineSessionFormatException('不支持的隔离区记录版本：$version');
  }
  if (version > currentQuarantineSessionSchemaVersion) {
    throw QuarantineSessionFormatException(
      '隔离区记录版本 $version 高于当前支持版本 '
      '$currentQuarantineSessionSchemaVersion，请升级 Broom 后再处理',
    );
  }

  final migrated = Map<String, dynamic>.of(raw);
  if (version < 2) {
    // v1 sessions did not track skipped items separately; they were only
    // visible in the transient clean report. Default to zero so a migrated
    // session remains internally consistent.
    migrated.putIfAbsent('skippedCount', () => 0);
    migrated['updatedAt'] =
        migrated['createdAt'] ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String();
  }
  migrated['schemaVersion'] = currentQuarantineSessionSchemaVersion;
  return migrated;
}
