/// Result of one completed or interrupted cleaning session.
enum CleanHistoryOutcome { completed, partial, cancelled, failed }

class CleanHistoryRule {
  const CleanHistoryRule({
    required this.ruleId,
    required this.fileCount,
    required this.bytes,
  });

  final String ruleId;
  final int fileCount;
  final int bytes;

  Map<String, Object?> toJson() => {
    'ruleId': ruleId,
    'fileCount': fileCount,
    'bytes': bytes,
  };

  static CleanHistoryRule? fromJson(Object? value) {
    if (value is! Map) return null;
    final ruleId = value['ruleId'];
    final fileCount = value['fileCount'];
    final bytes = value['bytes'];
    if (ruleId is! String ||
        ruleId.isEmpty ||
        fileCount is! int ||
        fileCount < 0 ||
        bytes is! int ||
        bytes < 0) {
      return null;
    }
    return CleanHistoryRule(ruleId: ruleId, fileCount: fileCount, bytes: bytes);
  }
}

/// A cleaning history entry. Unlike [QuarantineSessionInfo], this record is
/// never deleted when a quarantine session is restored or permanently purged.
class CleanHistoryRecord {
  const CleanHistoryRecord({
    required this.sessionId,
    required this.startedAt,
    required this.completedAt,
    required this.outcome,
    required this.plannedCount,
    required this.plannedBytes,
    required this.movedCount,
    required this.movedBytes,
    required this.skippedCount,
    required this.failureCount,
    required this.remainingCount,
    required this.rules,
  });

  final String sessionId;
  final DateTime startedAt;
  final DateTime completedAt;
  final CleanHistoryOutcome outcome;

  /// Files selected for this session, including files left unprocessed.
  final int plannedCount;
  final int plannedBytes;

  /// Files currently held in the quarantine (or released) for this session.
  final int movedCount;
  final int movedBytes;

  final int skippedCount;
  final int failureCount;
  final int remainingCount;
  final List<CleanHistoryRule> rules;

  bool get hasIssues =>
      skippedCount > 0 || failureCount > 0 || remainingCount > 0;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'completedAt': completedAt.toUtc().toIso8601String(),
    'outcome': outcome.name,
    'plannedCount': plannedCount,
    'plannedBytes': plannedBytes,
    'movedCount': movedCount,
    'movedBytes': movedBytes,
    'skippedCount': skippedCount,
    'failureCount': failureCount,
    'remainingCount': remainingCount,
    'rules': [for (final rule in rules) rule.toJson()],
  };

  static CleanHistoryRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final sessionId = value['sessionId'];
    final startedAt = _parseDate(value['startedAt']);
    final completedAt = _parseDate(value['completedAt']);
    final outcome = _parseOutcome(value['outcome']);
    final plannedCount = value['plannedCount'];
    final plannedBytes = value['plannedBytes'];
    final movedCount = value['movedCount'];
    final movedBytes = value['movedBytes'];
    final skippedCount = value['skippedCount'];
    final failureCount = value['failureCount'];
    final remainingCount = value['remainingCount'];
    final rawRules = value['rules'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        startedAt == null ||
        completedAt == null ||
        outcome == null ||
        plannedCount is! int ||
        plannedCount < 0 ||
        plannedBytes is! int ||
        plannedBytes < 0 ||
        movedCount is! int ||
        movedCount < 0 ||
        movedBytes is! int ||
        movedBytes < 0 ||
        skippedCount is! int ||
        skippedCount < 0 ||
        failureCount is! int ||
        failureCount < 0 ||
        remainingCount is! int ||
        remainingCount < 0 ||
        rawRules is! List) {
      return null;
    }
    final rules = <CleanHistoryRule>[];
    for (final rawRule in rawRules) {
      final rule = CleanHistoryRule.fromJson(rawRule);
      if (rule != null) rules.add(rule);
    }
    return CleanHistoryRecord(
      sessionId: sessionId,
      startedAt: startedAt,
      completedAt: completedAt,
      outcome: outcome,
      plannedCount: plannedCount,
      plannedBytes: plannedBytes,
      movedCount: movedCount,
      movedBytes: movedBytes,
      skippedCount: skippedCount,
      failureCount: failureCount,
      remainingCount: remainingCount,
      rules: List.unmodifiable(rules),
    );
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value);
  }

  static CleanHistoryOutcome? _parseOutcome(Object? value) {
    for (final outcome in CleanHistoryOutcome.values) {
      if (outcome.name == value) return outcome;
    }
    return null;
  }
}
