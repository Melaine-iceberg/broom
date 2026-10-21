import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/clean_models.dart';
import '../models/scan_models.dart';
import '../models/system_models.dart';
import '../platform/filesystem_error.dart';
import '../platform/windows_path.dart';
import '../safety/path_guard.dart';
import 'system_services.dart';

abstract interface class SystemCacheCleaner {
  Future<SystemCleanReport> clean({
    required List<JunkItem> items,
    required ScanRoots roots,
    required Map<String, List<String>> rootsByRule,
    required Iterable<String> serviceNames,
    void Function(SystemCleanProgress progress)? onProgress,
    void Function(SystemCleanStage stage)? onStage,
    bool Function()? isCancelled,
  });
}

/// Permanently deletes files inside pre-resolved system cache roots. There is
/// no quarantine: system caches are large and moving them within the same
/// volume would not free disk space.
class FileSystemCacheCleaner implements SystemCacheCleaner {
  FileSystemCacheCleaner({
    required this.services,
    this.maxFailureDetails = 100,
  });

  final ServiceControl services;
  final int maxFailureDetails;

  @override
  Future<SystemCleanReport> clean({
    required List<JunkItem> items,
    required ScanRoots roots,
    required Map<String, List<String>> rootsByRule,
    required Iterable<String> serviceNames,
    void Function(SystemCleanProgress progress)? onProgress,
    void Function(SystemCleanStage stage)? onStage,
    bool Function()? isCancelled,
  }) async {
    final failures = <CleanFailure>[];
    final skips = <CleanFailure>[];
    final serviceIssues = <String>[];
    var failureCount = 0;
    var skippedCount = 0;
    var deletedCount = 0;
    var deletedBytes = 0;
    var processed = 0;
    var cancelled = false;
    var lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

    void recordFailure(String path, String reason) {
      failureCount++;
      if (failures.length < maxFailureDetails) {
        failures.add(CleanFailure(path: path, reason: reason));
      }
    }

    void recordSkip(String path, String reason) {
      skippedCount++;
      if (skips.length < maxFailureDetails) {
        skips.add(CleanFailure(path: path, reason: reason));
      }
    }

    void recordAttemptError(String path, FileSystemException error) {
      if (_isSkippableError(error)) {
        recordSkip(path, _failureReason(error));
      } else {
        recordFailure(path, _failureReason(error));
      }
    }

    void report({bool force = false, String? currentPath}) {
      final now = DateTime.now();
      if (!force &&
          now.difference(lastReportAt) < const Duration(milliseconds: 120)) {
        return;
      }
      lastReportAt = now;
      onProgress?.call(
        SystemCleanProgress(
          processed: processed,
          total: items.length,
          deleted: deletedCount,
          deletedBytes: deletedBytes,
          skipped: skippedCount,
          currentPath: currentPath,
        ),
      );
    }

    SystemCleanReport buildReport() => SystemCleanReport(
      deletedCount: deletedCount,
      deletedBytes: deletedBytes,
      skippedCount: skippedCount,
      skips: List.unmodifiable(skips),
      failureCount: failureCount,
      failures: List.unmodifiable(failures),
      cancelled: cancelled,
      serviceIssues: List.unmodifiable(serviceIssues),
    );

    if (items.isEmpty) return buildReport();

    final trustedRoots = <String, List<String>>{
      for (final entry in rootsByRule.entries)
        entry.key: [
          for (final root in entry.value)
            if (_isSafeRoot(root)) PathGuard.normalize(root),
        ],
    };
    final uniqueServices = <String>{
      for (final name in serviceNames)
        if (name.trim().isNotEmpty) name,
    };

    var stoppedServices = <String>{};
    try {
      if (uniqueServices.isNotEmpty) {
        onStage?.call(SystemCleanStage.stoppingServices);
        stoppedServices = await services.stopServices(uniqueServices);
      }

      onStage?.call(SystemCleanStage.deleting);
      for (final item in items) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        processed++;

        final pathFailure = _pathFailure(
          item,
          roots.at(item.rootIndex),
          trustedRoots,
        );
        if (pathFailure != null) {
          recordFailure(item.path, pathFailure);
          report(currentPath: item.path);
          continue;
        }

        final FileSystemEntityType type;
        try {
          type = await FileSystemEntity.type(
            WindowsPath.forIo(item.path),
            followLinks: false,
          );
        } on FileSystemException catch (error) {
          recordAttemptError(item.path, error);
          report(currentPath: item.path);
          continue;
        }
        if (type == FileSystemEntityType.link) {
          recordSkip(item.path, '跳过符号链接或 junction');
          report(currentPath: item.path);
          continue;
        }
        if (type != FileSystemEntityType.file) {
          recordSkip(item.path, '文件已不存在或不是普通文件');
          report(currentPath: item.path);
          continue;
        }

        int size;
        try {
          size = await File(WindowsPath.forIo(item.path)).length();
        } on FileSystemException catch (error) {
          recordAttemptError(item.path, error);
          report(currentPath: item.path);
          continue;
        }

        try {
          await File(WindowsPath.forIo(item.path)).delete();
        } on FileSystemException catch (error) {
          recordAttemptError(item.path, error);
          report(currentPath: item.path);
          continue;
        }

        deletedCount++;
        deletedBytes += size;
        report(currentPath: item.path);
      }
    } finally {
      if (stoppedServices.isNotEmpty) {
        onStage?.call(SystemCleanStage.restartingServices);
        try {
          serviceIssues.addAll(await services.startServices(stoppedServices));
        } catch (error) {
          serviceIssues.add('$error');
        }
      }
      report(force: true);
    }

    return buildReport();
  }

  static String? _pathFailure(
    JunkItem item,
    ScanRoot root,
    Map<String, List<String>> trustedRoots,
  ) {
    if (!p.windows.isAbsolute(item.path) ||
        !p.windows.isAbsolute(root.rootPath)) {
      return '文件路径不是绝对路径';
    }
    final roots = trustedRoots[root.ruleId];
    if (roots == null || roots.isEmpty) {
      return '规则没有可信的缓存根目录';
    }

    final itemRootKey = _key(root.rootPath);
    String? matchedRoot;
    for (final root in roots) {
      if (_key(root) == itemRootKey) {
        matchedRoot = root;
        break;
      }
    }
    if (matchedRoot == null) {
      return '规则根目录未通过安全检查';
    }

    final pathKey = _key(item.path);
    final rootKey = _key(matchedRoot);
    if (pathKey == rootKey) {
      return '不会删除缓存根目录本身';
    }
    if (!_isWithin(rootKey, pathKey)) {
      return '文件不在声明的缓存目录内';
    }
    return null;
  }

  static bool _isSafeRoot(String root) {
    if (!p.windows.isAbsolute(root)) return false;
    final normalized = PathGuard.normalize(root);
    return p.windows.rootPrefix(normalized) != normalized;
  }

  static String _key(String path) => PathGuard.normalize(path).toLowerCase();

  static bool _isWithin(String rootKey, String candidateKey) {
    if (candidateKey == rootKey) return true;
    final prefix = rootKey.endsWith(p.windows.separator)
        ? rootKey
        : '$rootKey${p.windows.separator}';
    return candidateKey.startsWith(prefix);
  }

  static bool _isSkippableError(FileSystemException error) {
    if (isFileLockConflict(error)) return true;
    final code = error.osError?.errorCode;
    return code == 2 || code == 3;
  }

  static String _failureReason(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == 2 || code == 3) return '文件或目录不存在';
    if (code == 5) return '没有访问权限，请确认以管理员身份运行';
    if (code == 32 || code == 33) return '文件正被其他程序占用';
    return error.message;
  }
}
