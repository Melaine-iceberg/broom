enum AnalysisPhase { scanning, comparing }

class DuplicateProgress {
  const DuplicateProgress({
    required this.phase,
    required this.scannedFiles,
    required this.scannedBytes,
    required this.processedFiles,
    required this.totalFiles,
    this.currentPath,
  });

  final AnalysisPhase phase;
  final int scannedFiles;
  final int scannedBytes;
  final int processedFiles;
  final int totalFiles;
  final String? currentPath;

  double? get fraction {
    if (phase != AnalysisPhase.comparing || totalFiles <= 0) return null;
    return processedFiles / totalFiles;
  }
}

class DuplicateFile {
  const DuplicateFile({
    required this.path,
    required this.size,
    required this.modified,
  });

  final String path;
  final int size;
  final DateTime modified;
}

class DuplicateGroup {
  const DuplicateGroup({required this.size, required this.files});

  final int size;
  final List<DuplicateFile> files;

  int get wastedBytes => size * (files.length - 1);
  int get totalBytes => size * files.length;
}

class DuplicateScanReport {
  const DuplicateScanReport({
    required this.groups,
    required this.scannedFiles,
    required this.scannedBytes,
    required this.errorCount,
    required this.truncated,
    required this.cancelled,
  });

  final List<DuplicateGroup> groups;
  final int scannedFiles;
  final int scannedBytes;
  final int errorCount;
  final bool truncated;
  final bool cancelled;

  int get groupCount => groups.length;

  int get duplicateFileCount =>
      groups.fold(0, (total, group) => total + group.files.length);

  int get redundantFileCount =>
      groups.fold(0, (total, group) => total + group.files.length - 1);

  int get reclaimableBytes =>
      groups.fold(0, (total, group) => total + group.wastedBytes);
}

class LargeFileProgress {
  const LargeFileProgress({
    required this.scannedFiles,
    required this.scannedBytes,
    required this.matchedFiles,
    this.currentPath,
  });

  final int scannedFiles;
  final int scannedBytes;
  final int matchedFiles;
  final String? currentPath;
}

class LargeFileEntry {
  const LargeFileEntry({
    required this.path,
    required this.size,
    required this.modified,
  });

  final String path;
  final int size;
  final DateTime modified;
}

class LargeFileScanReport {
  const LargeFileScanReport({
    required this.files,
    required this.matchedCount,
    required this.matchedBytes,
    required this.scannedFiles,
    required this.scannedBytes,
    required this.errorCount,
    required this.truncated,
    required this.cancelled,
  });

  final List<LargeFileEntry> files;
  final int matchedCount;
  final int matchedBytes;
  final int scannedFiles;
  final int scannedBytes;
  final int errorCount;
  final bool truncated;
  final bool cancelled;

  bool get resultsCapped => matchedCount > files.length;
}
