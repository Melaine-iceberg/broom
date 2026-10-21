import 'package:broom/core/clean/clean_history_store.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/safety/path_guard.dart';

QuarantineEntry fakeQuarantineEntry(
  String name, {
  int sequence = 1,
  int size = 5,
  bool originalExists = false,
  bool restored = false,
  String? integrityFailure,
}) => QuarantineEntry(
  storedName: '00000${sequence}_$name',
  originalPath: 'C:\\Users\\Alice\\Downloads\\$name',
  size: size,
  restored: restored,
  present: !restored,
  originalExists: originalExists,
  integrityFailure: integrityFailure,
);

class FakeQuarantineService implements QuarantineService {
  FakeQuarantineService([
    List<QuarantineEntry> entries = const [],
    this.remainingCount = 0,
  ]) : _entriesBySession = entries.isEmpty ? {} : {sessionId: List.of(entries)};

  static const sessionId = '20261018_120000_abcd';

  int remainingCount;
  int undoMetadataFailures = 0;
  final List<String> resumeRequests = [];
  CleanHistoryStore? history;

  @override
  final String quarantineRoot =
      r'C:\Users\Alice\AppData\Local\Broom\quarantine';

  @override
  final PathGuard guard = PathGuard(protectedRoots: const []);

  @override
  CleanHistoryStore? get historyStore => history;

  @override
  bool get operationInProgress => false;

  @override
  Future<QuarantineSpaceAssessment> assessSpace(List<JunkItem> items) async =>
      QuarantineSpaceAssessment(
        requiredBytes: 0,
        crossVolumeCount: 0,
        freeBytes: null,
        quarantineRoot: quarantineRoot,
      );

  final Map<String, List<QuarantineEntry>> _entriesBySession;
  final List<
    ({
      Set<String>? storedNames,
      UndoConflictPolicy policy,
      Map<String, UndoConflictPolicy> policies,
    })
  >
  restoreRequests = [];

  bool get isEmpty => _entriesBySession.isEmpty;

  @override
  Future<List<QuarantineSessionInfo>> listSessions() async {
    return [
      for (final session in _entriesBySession.entries)
        _sessionInfo(session.key, session.value),
    ];
  }

  @override
  Future<List<QuarantineEntry>> listEntries(String sessionId) async =>
      List.of(_entriesBySession[sessionId] ?? const []);

  @override
  Future<QuarantineSessionInfo> getSession(String sessionId) async {
    final entries = _entriesBySession[sessionId];
    if (entries == null) throw StateError('找不到隔离区记录');
    return _sessionInfo(sessionId, entries);
  }

  @override
  Future<CleanReport> resumeClean(
    String sessionId, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!_entriesBySession.containsKey(sessionId)) {
      throw StateError('找不到隔离区记录');
    }
    resumeRequests.add(sessionId);
    final total = remainingCount;
    remainingCount = 0;
    onProgress?.call(
      CleanProgress(moved: 0, processed: total, total: total, movedBytes: 0),
    );
    return CleanReport(
      sessionId: sessionId,
      movedCount: 0,
      movedBytes: 0,
      failureCount: 0,
      failures: const [],
      cancelled: false,
    );
  }

  @override
  Future<UndoReport> undo(
    String sessionId, {
    Set<String>? storedNames,
    UndoConflictPolicy conflictPolicy = UndoConflictPolicy.skip,
    Map<String, UndoConflictPolicy> conflictPolicies = const {},
  }) async {
    restoreRequests.add((
      storedNames: storedNames,
      policy: conflictPolicy,
      policies: Map.of(conflictPolicies),
    ));
    final entries = _entriesBySession[sessionId];
    if (entries == null) throw StateError('找不到隔离区记录');

    var restoredCount = 0;
    var restoredBytes = 0;
    var conflictCount = 0;
    var keptBothCount = 0;
    var overwrittenCount = 0;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (storedNames != null && !storedNames.contains(entry.storedName)) {
        continue;
      }
      if (!entry.restorable) continue;
      if (entry.originalExists) {
        final policy = conflictPolicies[entry.storedName] ?? conflictPolicy;
        switch (policy) {
          case UndoConflictPolicy.skip:
            conflictCount++;
            continue;
          case UndoConflictPolicy.keepBoth:
            keptBothCount++;
          case UndoConflictPolicy.overwrite:
            overwrittenCount++;
        }
      }
      entries[index] = QuarantineEntry(
        storedName: entry.storedName,
        originalPath: entry.originalPath,
        size: entry.size,
        restored: true,
        present: false,
        originalExists: true,
      );
      restoredCount++;
      restoredBytes += entry.size;
    }

    final pending = entries.where((entry) => !entry.restored).length;
    final sessionRemoved = pending == 0;
    if (sessionRemoved) _entriesBySession.remove(sessionId);
    return UndoReport(
      restoredCount: restoredCount,
      restoredBytes: restoredBytes,
      conflictCount: conflictCount,
      keptBothCount: keptBothCount,
      overwrittenCount: overwrittenCount,
      missingCount: 0,
      failureCount: 0,
      integrityFailureCount: 0,
      failures: const [],
      sessionRemoved: sessionRemoved,
      metadataFailureCount: undoMetadataFailures,
    );
  }

  @override
  Future<QuarantinePurgeReport> purgeSession(String sessionId) async {
    final entries = _entriesBySession.remove(sessionId);
    if (entries == null) throw StateError('找不到隔离区记录');
    final pending = entries.where((entry) => !entry.restored).toList();
    return QuarantinePurgeReport(
      removedCount: pending.length,
      removedBytes: pending.fold(0, (total, entry) => total + entry.size),
      failureCount: 0,
      failures: const [],
      sessionRemoved: true,
    );
  }

  @override
  Future<QuarantinePurgeReport> purgeAllSessions() async {
    final pending = _entriesBySession.values
        .expand((entries) => entries)
        .where((entry) => !entry.restored)
        .toList();
    _entriesBySession.clear();
    return QuarantinePurgeReport(
      removedCount: pending.length,
      removedBytes: pending.fold(0, (total, entry) => total + entry.size),
      failureCount: 0,
      failures: const [],
      sessionRemoved: true,
    );
  }

  Object? cleanError;
  List<JunkItem> cleanRequest = const [];

  @override
  Future<CleanReport> clean(
    List<JunkItem> items, {
    required ScanRoots roots,
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    cleanRequest = List.of(items);
    if (cleanError != null) throw cleanError!;
    throw UnimplementedError();
  }

  QuarantineSessionInfo _sessionInfo(String id, List<QuarantineEntry> entries) {
    final pending = entries.where((entry) => !entry.restored).toList();
    final status =
        remainingCount == 0 &&
            pending.length == entries.length &&
            pending.every((entry) => entry.restorable)
        ? QuarantineStatus.ready
        : QuarantineStatus.partial;
    return QuarantineSessionInfo(
      id: id,
      createdAt: DateTime(2026, 10, 18, 12),
      status: status,
      entryCount: entries.length,
      totalBytes: entries.fold(0, (total, entry) => total + entry.size),
      pendingCount: pending.length,
      pendingBytes: pending.fold(0, (total, entry) => total + entry.size),
      plannedCount: entries.length + remainingCount,
      remainingCount: remainingCount,
    );
  }
}
