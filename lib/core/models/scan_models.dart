import 'dart:io';

class ScanJob {
  const ScanJob({
    required this.ruleId,
    required this.roots,
    this.minAge = Duration.zero,
    this.extensions,
    this.excludedRoots = const [],
  });

  final String ruleId;
  final List<String> roots;
  final Duration minAge;
  final Set<String>? extensions;

  /// Paths under [roots] that belong to another scan job with stricter rules.
  final List<String> excludedRoots;
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

/// Stable machine-readable categories for scan failures.
enum ScanErrorKind {
  accessDenied,
  pathTooLong,
  notFound,
  deviceNotReady,
  networkUnavailable,
  writeProtected,
  diskFull,
  unsupported,
  sharingViolation,
  invalidName,
  ioError,
  other,
}

class ScanIssue {
  const ScanIssue({
    required this.ruleId,
    required this.path,
    required this.kind,
    required this.message,
    this.isDirectory = false,
  });

  final String ruleId;
  final String path;
  final ScanErrorKind kind;
  final String message;
  final bool isDirectory;
}

/// Options consumed by the scan coordinator. [maxItems] is null by default:
/// the engine no longer has a fixed 100,000 item cap. A positive value is a
/// user-configured safety limit, and the UI must explain if it truncates.
class ScanOptions {
  const ScanOptions({
    this.maxItems,
    this.parallelism = 1,
    this.lowPriority = false,
    this.useNtfsIndex = false,
    this.batchSize = 256,
  });

  final int? maxItems;
  final int parallelism;
  final bool lowPriority;
  final bool useNtfsIndex;
  final int batchSize;

  ScanOptions copyWith({
    int? maxItems,
    bool clearMaxItems = false,
    int? parallelism,
    bool? lowPriority,
    bool? useNtfsIndex,
    int? batchSize,
  }) {
    return ScanOptions(
      maxItems: clearMaxItems ? null : (maxItems ?? this.maxItems),
      parallelism: parallelism ?? this.parallelism,
      lowPriority: lowPriority ?? this.lowPriority,
      useNtfsIndex: useNtfsIndex ?? this.useNtfsIndex,
      batchSize: batchSize ?? this.batchSize,
    );
  }
}

/// Snapshot of user scan preferences. Kept separate from [ScanOptions] because
/// the controller also needs category filters that are resolved before jobs
/// are created.
class ScanSettings {
  const ScanSettings({
    this.disabledCategoryIds = const <String>{},
    this.parallelism = 2,
    this.lowPriority = true,
    this.useNtfsIndex = false,
    this.itemLimit,
  });

  final Set<String> disabledCategoryIds;
  final int parallelism;
  final bool lowPriority;
  final bool useNtfsIndex;
  final int? itemLimit;

  bool isCategoryEnabled(String categoryId) =>
      !disabledCategoryIds.contains(categoryId);

  ScanOptions toOptions({int batchSize = 256}) => ScanOptions(
    maxItems: itemLimit,
    parallelism: parallelism,
    lowPriority: lowPriority,
    useNtfsIndex: useNtfsIndex,
    batchSize: batchSize,
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
    this.errorCount = 0,
    this.elapsed = Duration.zero,
    this.workerCount = 1,
  });

  final int jobIndex;
  final int jobCount;
  final String? ruleId;
  final int scannedFiles;
  final int foundFiles;
  final int foundBytes;

  /// Number of directory and file errors reported so far.
  final int errorCount;
  final Duration elapsed;
  final int workerCount;
}

class ScanResult {
  const ScanResult({
    required this.items,
    required this.scannedFiles,
    required this.directoryErrors,
    required this.truncated,
    required this.cancelled,
    this.issues = const [],
    this.elapsed = Duration.zero,
  });

  final List<JunkItem> items;
  final int scannedFiles;

  /// Number of scan issues. Kept as a count for existing callers; [issues]
  /// carries the per-path kind and message.
  final int directoryErrors;
  final bool truncated;
  final bool cancelled;
  final List<ScanIssue> issues;
  final Duration elapsed;

  int get totalBytes => items.fold(0, (total, item) => total + item.size);
}

/// Maps OS errors to categories that the preview can explain.
ScanErrorKind classifyScanError(Object error) {
  final osError = error is FileSystemException ? error.osError : null;
  final code = osError?.errorCode;
  final message = '${osError?.message ?? error}'.toLowerCase();

  switch (code) {
    case 2:
    case 3:
      return ScanErrorKind.notFound;
    case 5:
      return ScanErrorKind.accessDenied;
    case 19:
      return ScanErrorKind.writeProtected;
    case 21:
      return ScanErrorKind.deviceNotReady;
    case 32:
    case 33:
      return ScanErrorKind.sharingViolation;
    case 36: // ENAMETOOLONG on POSIX
    case 206:
      return ScanErrorKind.pathTooLong;
    case 50:
    case 4390:
      return ScanErrorKind.unsupported;
    case 53:
    case 64:
    case 67:
      return ScanErrorKind.networkUnavailable;
    case 112:
      return ScanErrorKind.diskFull;
    case 123:
    case 161:
      return ScanErrorKind.invalidName;
  }

  if (message.contains('access is denied') ||
      message.contains('permission denied')) {
    return ScanErrorKind.accessDenied;
  }
  if (message.contains('name too long') || message.contains('path too long')) {
    return ScanErrorKind.pathTooLong;
  }
  if (message.contains('network path') || message.contains('network name')) {
    return ScanErrorKind.networkUnavailable;
  }
  if (message.contains('being used') || message.contains('sharing')) {
    return ScanErrorKind.sharingViolation;
  }
  if (error is FileSystemException) return ScanErrorKind.ioError;
  return ScanErrorKind.other;
}

String describeScanIssue(ScanIssue issue) {
  return '${issue.message} (${issue.path})';
}
