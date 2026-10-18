class CleanFailure {
  const CleanFailure({required this.path, required this.reason});

  final String path;
  final String reason;
}

class CleanProgress {
  const CleanProgress({
    required this.moved,
    required this.processed,
    required this.total,
    required this.movedBytes,
    this.currentPath,
  });

  final int moved;
  final int processed;
  final int total;
  final int movedBytes;
  final String? currentPath;
}

class CleanReport {
  const CleanReport({
    required this.sessionId,
    required this.movedCount,
    required this.movedBytes,
    required this.failureCount,
    required this.failures,
    required this.cancelled,
  });

  final String? sessionId;
  final int movedCount;
  final int movedBytes;
  final int failureCount;
  final List<CleanFailure> failures;
  final bool cancelled;
}

enum UndoConflictPolicy { skip, keepBoth, overwrite }

class UndoReport {
  const UndoReport({
    required this.restoredCount,
    required this.restoredBytes,
    required this.conflictCount,
    required this.keptBothCount,
    required this.overwrittenCount,
    required this.missingCount,
    required this.failureCount,
    required this.failures,
    required this.sessionRemoved,
  });

  final int restoredCount;
  final int restoredBytes;
  final int conflictCount;
  final int keptBothCount;
  final int overwrittenCount;
  final int missingCount;
  final int failureCount;
  final List<CleanFailure> failures;
  final bool sessionRemoved;

  bool get hasPending => conflictCount > 0 || failureCount > 0;
}

enum QuarantineStatus { cleaning, ready, partial, restored }

class QuarantineSessionInfo {
  const QuarantineSessionInfo({
    required this.id,
    required this.createdAt,
    required this.status,
    required this.entryCount,
    required this.totalBytes,
    required this.pendingCount,
    required this.pendingBytes,
  });

  final String id;
  final DateTime createdAt;
  final QuarantineStatus status;
  final int entryCount;
  final int totalBytes;
  final int pendingCount;
  final int pendingBytes;
}

class QuarantineEntry {
  const QuarantineEntry({
    required this.storedName,
    required this.originalPath,
    required this.size,
    required this.restored,
    required this.present,
    required this.originalExists,
  });

  final String storedName;
  final String originalPath;
  final int size;
  final bool restored;
  final bool present;
  final bool originalExists;

  bool get restorable => !restored && present;
}

class QuarantinePurgeReport {
  const QuarantinePurgeReport({
    required this.removedCount,
    required this.removedBytes,
    required this.failureCount,
    required this.failures,
    required this.sessionRemoved,
  });

  final int removedCount;
  final int removedBytes;
  final int failureCount;
  final List<CleanFailure> failures;
  final bool sessionRemoved;

  bool get complete => failureCount == 0 && sessionRemoved;
}
