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
    this.skipped = 0,
    this.currentPath,
  });

  final int moved;
  final int processed;
  final int total;
  final int movedBytes;
  final int skipped;
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
    this.skippedCount = 0,
    this.skips = const [],
    this.remainingCount = 0,
    this.removedDirectoryCount = 0,
  });

  final String? sessionId;
  final int movedCount;
  final int movedBytes;

  /// Files that could not be cleaned because of a blocking condition such as
  /// another program's file lock, a disappeared file, or an exclusion. These
  /// files stay untouched at their original paths.
  final int skippedCount;
  final List<CleanFailure> skips;

  final int failureCount;
  final List<CleanFailure> failures;
  final bool cancelled;
  final int remainingCount;

  /// Empty directories below the rule roots that were removed after their
  /// files moved to quarantine. Undo recreates them from the session records.
  final int removedDirectoryCount;

  bool get resumable => remainingCount > 0;

  bool get hasIssues => skippedCount > 0 || failureCount > 0;
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
    required this.integrityFailureCount,
    required this.failures,
    required this.sessionRemoved,
    this.metadataFailureCount = 0,
    this.metadataWarnings = const [],
    this.recreatedDirectoryCount = 0,
    this.directoryFailureCount = 0,
    this.directoryWarnings = const [],
  });

  final int restoredCount;
  final int restoredBytes;
  final int conflictCount;
  final int keptBothCount;
  final int overwrittenCount;
  final int missingCount;
  final int failureCount;
  final int integrityFailureCount;
  final List<CleanFailure> failures;
  final bool sessionRemoved;
  final int metadataFailureCount;
  final List<CleanFailure> metadataWarnings;
  final int recreatedDirectoryCount;
  final int directoryFailureCount;
  final List<CleanFailure> directoryWarnings;

  bool get hasPending =>
      conflictCount > 0 || failureCount > 0 || integrityFailureCount > 0;
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
    this.plannedCount = 0,
    this.remainingCount = 0,
  });

  final String id;
  final DateTime createdAt;
  final QuarantineStatus status;
  final int entryCount;
  final int totalBytes;
  final int pendingCount;
  final int pendingBytes;
  final int plannedCount;
  final int remainingCount;

  bool get resumable => remainingCount > 0;
}

class QuarantineEntry {
  const QuarantineEntry({
    required this.storedName,
    required this.originalPath,
    required this.size,
    required this.restored,
    required this.present,
    required this.originalExists,
    this.integrityFailure,
  });

  final String storedName;
  final String originalPath;
  final int size;
  final bool restored;
  final bool present;
  final bool originalExists;
  final String? integrityFailure;

  bool get restorable => !restored && present && integrityFailure == null;
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
