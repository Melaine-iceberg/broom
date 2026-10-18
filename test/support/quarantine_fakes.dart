import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/safety/path_guard.dart';

QuarantineEntry fakeQuarantineEntry(
  String name, {
  int sequence = 1,
  int size = 5,
}) => QuarantineEntry(
  storedName: '00000${sequence}_$name',
  originalPath: 'C:\\Users\\Alice\\Downloads\\$name',
  size: size,
  restored: false,
  present: true,
  originalExists: false,
);

class FakeQuarantineService implements QuarantineService {
  FakeQuarantineService([List<QuarantineEntry> entries = const []])
    : _entriesBySession = entries.isEmpty ? {} : {sessionId: List.of(entries)};

  static const sessionId = '20261018_120000_abcd';

  @override
  final String quarantineRoot =
      r'C:\Users\Alice\AppData\Local\Broom\quarantine';

  @override
  final PathGuard guard = PathGuard(protectedRoots: const []);

  final Map<String, List<QuarantineEntry>> _entriesBySession;
  final List<Set<String>?> restoreRequests = [];

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
  Future<UndoReport> undo(String sessionId, {Set<String>? storedNames}) async {
    restoreRequests.add(storedNames);
    final entries = _entriesBySession[sessionId];
    if (entries == null) throw StateError('找不到隔离区记录');

    var restoredCount = 0;
    var restoredBytes = 0;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (storedNames != null && !storedNames.contains(entry.storedName)) {
        continue;
      }
      if (!entry.restorable || entry.originalExists) continue;
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

    final pending = entries.where((entry) => entry.restorable).length;
    final sessionRemoved = pending == 0;
    if (sessionRemoved) _entriesBySession.remove(sessionId);
    return UndoReport(
      restoredCount: restoredCount,
      restoredBytes: restoredBytes,
      conflictCount: 0,
      missingCount: 0,
      failureCount: 0,
      failures: const [],
      sessionRemoved: sessionRemoved,
    );
  }

  @override
  Future<QuarantinePurgeReport> purgeSession(String sessionId) async {
    final entries = _entriesBySession.remove(sessionId);
    if (entries == null) throw StateError('找不到隔离区记录');
    final pending = entries.where((entry) => entry.restorable).toList();
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
        .where((entry) => entry.restorable)
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

  @override
  Future<CleanReport> clean(
    List<JunkItem> items, {
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    throw UnimplementedError();
  }

  QuarantineSessionInfo _sessionInfo(String id, List<QuarantineEntry> entries) {
    final pending = entries.where((entry) => entry.restorable).toList();
    return QuarantineSessionInfo(
      id: id,
      createdAt: DateTime(2026, 10, 18, 12),
      status: pending.length == entries.length
          ? QuarantineStatus.ready
          : QuarantineStatus.partial,
      entryCount: entries.length,
      totalBytes: entries.fold(0, (total, entry) => total + entry.size),
      pendingCount: pending.length,
      pendingBytes: pending.fold(0, (total, entry) => total + entry.size),
    );
  }
}
