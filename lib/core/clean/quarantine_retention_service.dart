import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/clean_models.dart';
import '../models/quarantine_policy_models.dart';
import '../settings/quarantine_policy_store.dart';
import 'quarantine_service.dart';

const _maxFailureDetails = 100;

class QuarantineRetentionService {
  QuarantineRetentionService({
    required this.quarantine,
    required this.store,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final QuarantineService quarantine;
  final QuarantinePolicyStore store;
  final DateTime Function() _clock;

  QuarantineRetentionPolicy? _policy;
  QuarantineRetentionReport? _lastReport;
  String? _loadError;
  bool _initialized = false;
  Future<void>? _initializing;

  QuarantineRetentionPolicy? get policy => _policy;

  QuarantineRetentionReport? get lastReport => _lastReport;

  String? get loadError => _loadError;

  bool get initialized => _initialized;

  Future<void> ensureInitialized() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<void> _initialize() async {
    try {
      _policy = await store.load();
      _loadError = null;
    } catch (error) {
      // A broken policy file must never trigger automatic deletion.
      _policy = QuarantineRetentionPolicy.defaults;
      _loadError = '$error';
    }
    if (_policy!.enabled) {
      _lastReport = await _applySafely(_policy!);
    }
    _initialized = true;
  }

  Future<QuarantineRetentionReport> apply(
    QuarantineRetentionPolicy policy,
  ) async {
    if (!policy.enabled) return QuarantineRetentionReport.empty;
    if (!policy.isValid) {
      throw ArgumentError.value(policy, 'policy', '保留策略参数无效');
    }

    final sessions = await quarantine.listSessions();
    final cutoff = _clock().subtract(Duration(days: policy.retentionDays));
    final selectedIds = <String>{
      for (final session in sessions)
        if (session.createdAt.isBefore(cutoff)) session.id,
    };

    var retainedBytes = sessions
        .where((session) => !selectedIds.contains(session.id))
        .fold<int>(0, (total, session) => total + session.pendingBytes);
    for (final session in sessions.reversed) {
      if (retainedBytes <= policy.maxBytes) break;
      if (!selectedIds.add(session.id)) continue;
      retainedBytes -= session.pendingBytes;
    }

    final targets = sessions.reversed
        .where((session) => selectedIds.contains(session.id))
        .toList();
    final failures = <CleanFailure>[];
    var failureCount = 0;
    var removedSessionCount = 0;
    var removedFileCount = 0;
    var removedBytes = 0;

    void recordFailure(String path, Object error) {
      failureCount++;
      if (failures.length < _maxFailureDetails) {
        failures.add(
          CleanFailure(
            path: path,
            reason: error is FileSystemException
                ? error.message
                : error.toString(),
          ),
        );
      }
    }

    for (final session in targets) {
      try {
        final report = await quarantine.purgeSession(session.id);
        removedFileCount += report.removedCount;
        removedBytes += report.removedBytes;
        failureCount += report.failureCount;
        if (failures.length < _maxFailureDetails) {
          failures.addAll(
            report.failures.take(_maxFailureDetails - failures.length),
          );
        }
        if (report.sessionRemoved) {
          removedSessionCount++;
        }
      } catch (error) {
        recordFailure(
          p.windows.join(quarantine.quarantineRoot, session.id),
          error,
        );
      }
    }

    return QuarantineRetentionReport(
      evaluatedSessionCount: sessions.length,
      selectedSessionCount: targets.length,
      removedSessionCount: removedSessionCount,
      removedFileCount: removedFileCount,
      removedBytes: removedBytes,
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
    );
  }

  /// Persists a policy without running automatic release.
  ///
  /// Imported or reset policies must never delete quarantine sessions as a
  /// side effect of restoring preferences. The policy takes effect on the next
  /// startup or the next explicit [save].
  Future<void> replacePolicy(QuarantineRetentionPolicy policy) async {
    if (!policy.isValid) {
      throw const QuarantinePolicyException('保留策略参数超出允许范围');
    }
    await store.save(policy);
    _policy = policy;
    _loadError = null;
    _initialized = true;
  }

  Future<QuarantineRetentionReport?> save(
    QuarantineRetentionPolicy policy,
  ) async {
    await store.save(policy);
    _policy = policy;
    _loadError = null;
    if (!policy.enabled) {
      _lastReport = null;
      return null;
    }
    final report = await _applySafely(policy);
    _lastReport = report;
    return report;
  }

  void clearLastReport() {
    _lastReport = null;
  }

  Future<QuarantineRetentionReport> _applySafely(
    QuarantineRetentionPolicy policy,
  ) async {
    try {
      return await apply(policy);
    } catch (error) {
      return QuarantineRetentionReport(
        evaluatedSessionCount: 0,
        selectedSessionCount: 0,
        removedSessionCount: 0,
        removedFileCount: 0,
        removedBytes: 0,
        failureCount: 1,
        failures: [
          CleanFailure(
            path: quarantine.quarantineRoot,
            reason: error.toString(),
          ),
        ],
      );
    }
  }
}
