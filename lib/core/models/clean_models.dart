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

class UndoReport {
  const UndoReport({
    required this.restoredCount,
    required this.restoredBytes,
    required this.conflictCount,
    required this.missingCount,
    required this.failureCount,
    required this.failures,
    required this.sessionRemoved,
  });

  final int restoredCount;
  final int restoredBytes;
  final int conflictCount;
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
