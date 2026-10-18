class ScanJob {
  const ScanJob({
    required this.ruleId,
    required this.roots,
    this.minAge = Duration.zero,
    this.extensions,
  });

  final String ruleId;
  final List<String> roots;
  final Duration minAge;
  final Set<String>? extensions;
}

class JunkItem {
  const JunkItem({
    required this.ruleId,
    required this.rootPath,
    required this.path,
    required this.size,
    required this.modified,
    this.possiblyLocked = false,
  });

  final String ruleId;
  final String rootPath;
  final String path;
  final int size;
  final DateTime modified;

  /// Preview-only hint that another process may block moving this file.
  /// Cleanup re-checks and reports the actual outcome.
  final bool possiblyLocked;

  JunkItem copyWith({bool? possiblyLocked}) => JunkItem(
    ruleId: ruleId,
    rootPath: rootPath,
    path: path,
    size: size,
    modified: modified,
    possiblyLocked: possiblyLocked ?? this.possiblyLocked,
  );
}

class ScanProgress {
  const ScanProgress({
    required this.jobIndex,
    required this.jobCount,
    required this.ruleId,
    required this.scannedFiles,
    required this.foundFiles,
    required this.foundBytes,
  });

  final int jobIndex;
  final int jobCount;
  final String? ruleId;
  final int scannedFiles;
  final int foundFiles;
  final int foundBytes;
}

class ScanResult {
  const ScanResult({
    required this.items,
    required this.scannedFiles,
    required this.directoryErrors,
    required this.truncated,
    required this.cancelled,
  });

  final List<JunkItem> items;
  final int scannedFiles;
  final int directoryErrors;
  final bool truncated;
  final bool cancelled;

  int get totalBytes => items.fold(0, (total, item) => total + item.size);
}
