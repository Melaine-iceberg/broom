import 'clean_models.dart';
import 'cleaner_rule.dart';

enum SystemCacheLocation { windowsUpdate, deliveryOptimization }

class SystemServiceSpec {
  const SystemServiceSpec({
    required this.name,
    required this.label,
    this.labelEn,
  });

  final String name;
  final String label;
  final String? labelEn;
}

class SystemCacheRule {
  const SystemCacheRule({
    required this.id,
    required this.title,
    required this.category,
    required this.description,
    required this.location,
    required this.displayPath,
    this.services = const [],
    this.note,
    this.titleEn,
    this.categoryEn,
    this.descriptionEn,
    this.noteEn,
  });

  final String id;
  final String title;
  final String category;
  final String description;
  final SystemCacheLocation location;
  final String displayPath;
  final List<SystemServiceSpec> services;
  final String? note;
  final String? titleEn;
  final String? categoryEn;
  final String? descriptionEn;
  final String? noteEn;

  CleanRisk get risk => CleanRisk.review;
}

class SystemCacheRoots {
  const SystemCacheRoots({
    required this.windowsUpdateDownload,
    required this.deliveryOptimizationCache,
  });

  final String windowsUpdateDownload;
  final String deliveryOptimizationCache;

  String pathFor(SystemCacheLocation location) => switch (location) {
    SystemCacheLocation.windowsUpdate => windowsUpdateDownload,
    SystemCacheLocation.deliveryOptimization => deliveryOptimizationCache,
  };
}

enum SystemCleanStage { stoppingServices, deleting, restartingServices }

class SystemCleanProgress {
  const SystemCleanProgress({
    required this.processed,
    required this.total,
    required this.deleted,
    required this.deletedBytes,
    this.skipped = 0,
    this.currentPath,
  });

  final int processed;
  final int total;
  final int deleted;
  final int deletedBytes;
  final int skipped;
  final String? currentPath;
}

class SystemCleanReport {
  const SystemCleanReport({
    required this.deletedCount,
    required this.deletedBytes,
    required this.failureCount,
    required this.failures,
    required this.cancelled,
    required this.serviceIssues,
    this.skippedCount = 0,
    this.skips = const [],
  });

  final int deletedCount;
  final int deletedBytes;
  final int skippedCount;
  final List<CleanFailure> skips;
  final int failureCount;
  final List<CleanFailure> failures;
  final bool cancelled;
  final List<String> serviceIssues;

  bool get hasServiceIssues => serviceIssues.isNotEmpty;
  bool get hasIssues => skippedCount > 0 || failureCount > 0;
}
