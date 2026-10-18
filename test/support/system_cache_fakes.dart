import 'package:broom/core/clean/system_cache_cleaner.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:broom/core/models/system_models.dart';
import 'package:broom/core/platform/system_access.dart';
import 'package:broom/core/platform/system_cache_platform.dart';
import 'package:broom/core/rules/windows_system_rules.dart';
import 'package:broom/core/scan/scan_service.dart';

class FakeSystemAccess implements SystemAccess {
  FakeSystemAccess({this.elevated = true, this.relaunchResult = false});

  bool elevated;
  bool relaunchResult;
  SystemCacheRoots roots = const SystemCacheRoots(
    windowsUpdateDownload: '',
    deliveryOptimizationCache: '',
    windowsOld: '',
  );
  Object? isElevatedError;
  Object? relaunchError;
  int isElevatedCalls = 0;
  int relaunchCalls = 0;

  @override
  Future<bool> isElevated() async {
    isElevatedCalls++;
    if (isElevatedError case final error?) throw error;
    return elevated;
  }

  @override
  Future<bool> relaunchElevated() async {
    relaunchCalls++;
    if (relaunchError case final error?) throw error;
    return relaunchResult;
  }

  @override
  Future<SystemCacheRoots> locateSystemCacheRoots() async => roots;
}

class FakeSystemCachePlatform implements SystemCachePlatform {
  FakeSystemCachePlatform({List<SystemCacheRule>? rules, this.resolver})
    : rules = rules ?? windowsSystemCacheRules;

  @override
  final List<SystemCacheRule> rules;

  final List<String> Function(SystemCacheRule rule)? resolver;
  Object? resolveError;

  @override
  bool get isSupported => true;

  @override
  Future<List<String>> resolveRoots(SystemCacheRule rule) async {
    if (resolveError case final error?) throw error;
    return resolver?.call(rule) ?? const [];
  }
}

class FakeSystemCacheCleaner implements SystemCacheCleaner {
  FakeSystemCacheCleaner({
    this.report = const SystemCleanReport(
      deletedCount: 0,
      deletedBytes: 0,
      failureCount: 0,
      failures: [],
      cancelled: false,
      serviceIssues: [],
    ),
  });

  SystemCleanReport report;
  Object? error;
  int calls = 0;
  List<JunkItem>? items;
  Map<String, List<String>>? rootsByRule;
  List<String>? serviceNames;
  final List<SystemCleanStage> stages = [];

  @override
  Future<SystemCleanReport> clean({
    required List<JunkItem> items,
    required Map<String, List<String>> rootsByRule,
    required Iterable<String> serviceNames,
    void Function(SystemCleanProgress progress)? onProgress,
    void Function(SystemCleanStage stage)? onStage,
    bool Function()? isCancelled,
  }) async {
    calls++;
    this.items = List.of(items);
    this.rootsByRule = rootsByRule;
    this.serviceNames = serviceNames.toList();

    void record(SystemCleanStage stage) {
      stages.add(stage);
      onStage?.call(stage);
    }

    if (serviceNames.isNotEmpty) {
      record(SystemCleanStage.stoppingServices);
    }
    record(SystemCleanStage.deleting);
    onProgress?.call(
      SystemCleanProgress(
        processed: items.length,
        total: items.length,
        deleted: report.deletedCount,
        deletedBytes: report.deletedBytes,
      ),
    );
    if (error case final failure?) throw failure;
    if (serviceNames.isNotEmpty) {
      record(SystemCleanStage.restartingServices);
    }
    return report;
  }
}

class FakeScanService extends ScanService {
  FakeScanService({this.result, this.error});

  ScanResult? result;
  Object? error;
  int calls = 0;
  bool disposed = false;
  List<ScanJob>? lastJobs;
  List<String>? lastExcludedPaths;

  @override
  Future<ScanResult> scan({
    required List<ScanJob> jobs,
    required List<String> excludedPaths,
    ScanOptions options = const ScanOptions(),
    NtfsIndex? ntfsIndex,
    void Function(ScanProgress progress)? onProgress,
    void Function(List<JunkItem> items)? onItems,
    void Function(ScanIssue issue)? onIssue,
    bool retainItems = true,
  }) async {
    calls++;
    lastJobs = jobs;
    lastExcludedPaths = excludedPaths;
    onProgress?.call(
      const ScanProgress(
        jobIndex: 0,
        jobCount: 1,
        ruleId: null,
        scannedFiles: 1,
        foundFiles: 1,
        foundBytes: 1,
      ),
    );
    if (error case final failure?) throw failure;
    final scanResult =
        result ??
        const ScanResult(
          items: [],
          scannedFiles: 0,
          directoryErrors: 0,
          truncated: false,
          cancelled: false,
        );
    if (scanResult.items.isNotEmpty) onItems?.call(scanResult.items);
    return scanResult;
  }

  @override
  void dispose() {
    disposed = true;
  }
}
