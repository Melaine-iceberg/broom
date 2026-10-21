import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/clean/system_cache_cleaner.dart';
import '../core/models/scan_models.dart';
import '../core/models/system_models.dart';
import '../core/platform/file_lock_probe.dart';
import '../core/platform/system_access.dart';
import '../core/platform/system_cache_platform.dart';
import '../core/scan/scan_service.dart';
import '../l10n/broom_strings.dart';

enum SystemCachePhase { idle, scanning, preview, cleaning, done }

class SystemRuleResult {
  SystemRuleResult({
    required this.rule,
    required this.roots,
    required this.items,
  }) : totalBytes = items.fold(0, (total, item) => total + item.size);

  final SystemCacheRule rule;
  final List<String> roots;
  final List<JunkItem> items;
  final int totalBytes;
}

class SystemCacheController extends ChangeNotifier {
  SystemCacheController({
    required this.platform,
    required this.access,
    required this.cleaner,
    this.quarantineRoot,
    ScanService Function()? scanServiceFactory,
    FileLockProbe? lockProbe,
  }) : _scanServiceFactory = scanServiceFactory ?? ScanService.new,
       _lockProbe = lockProbe ?? const NoopFileLockProbe();

  final SystemCachePlatform platform;
  final SystemAccess access;
  final SystemCacheCleaner cleaner;
  final String? quarantineRoot;
  final ScanService Function() _scanServiceFactory;
  final FileLockProbe _lockProbe;

  SystemCachePhase _phase = SystemCachePhase.idle;
  bool _isElevated = false;
  bool _accessChecked = false;
  bool _checkingAccess = false;
  bool _relaunching = false;
  String? _accessError;
  ScanProgress? _scanProgress;
  List<SystemRuleResult> _results = const [];
  ScanRoots _scanRoots = ScanRoots.empty;
  Set<String> _selectedRuleIds = <String>{};
  SystemCleanReport? _lastReport;
  SystemCleanProgress? _cleanProgress;
  SystemCleanStage? _cleanStage;
  int _scanDirectoryErrors = 0;
  bool _scanTruncated = false;
  String? _notice;
  String? _error;
  bool _cleanCancelRequested = false;
  ScanService? _scanService;
  bool _disposed = false;
  int _lockProbeGeneration = 0;
  bool _lockProbeRunning = false;
  int _lockProbeChecked = 0;
  int _lockProbeTotal = 0;
  final Map<String, int> _lockedCountByRule = <String, int>{};

  SystemCachePhase get phase => _phase;
  bool get isElevated => _isElevated;
  bool get accessChecked => _accessChecked;
  bool get checkingAccess => _checkingAccess;
  bool get relaunching => _relaunching;
  String? get accessError => _accessError;
  ScanProgress? get scanProgress => _scanProgress;
  List<SystemRuleResult> get results => _results;
  SystemCleanReport? get lastReport => _lastReport;
  SystemCleanProgress? get cleanProgress => _cleanProgress;
  SystemCleanStage? get cleanStage => _cleanStage;
  int get scanDirectoryErrors => _scanDirectoryErrors;
  bool get scanTruncated => _scanTruncated;
  String? get notice => _notice;
  String? get error => _error;
  bool get cleanCancelRequested => _cleanCancelRequested;
  bool get isBusy =>
      _phase == SystemCachePhase.scanning ||
      _phase == SystemCachePhase.cleaning;
  bool get lockProbeRunning => _lockProbeRunning;
  int get lockProbeChecked => _lockProbeChecked;
  int get lockProbeTotal => _lockProbeTotal;

  int possiblyLockedCountForRule(String ruleId) =>
      _lockedCountByRule[ruleId] ?? 0;

  int get selectedPossiblyLockedCount {
    var count = 0;
    for (final result in _results) {
      if (!_selectedRuleIds.contains(result.rule.id)) continue;
      for (final item in result.items) {
        if (item.possiblyLocked) count++;
      }
    }
    return count;
  }

  bool isRuleSelected(String ruleId) => _selectedRuleIds.contains(ruleId);

  List<SystemRuleResult> get selectedResults => [
    for (final result in _results)
      if (_selectedRuleIds.contains(result.rule.id)) result,
  ];

  List<JunkItem> get selectedItems => [
    for (final result in selectedResults) ...result.items,
  ];

  int get selectedCount => selectedItems.length;

  int get selectedBytes =>
      selectedItems.fold(0, (total, item) => total + item.size);

  List<SystemServiceSpec> get selectedServices {
    final seen = <String>{};
    return [
      for (final result in selectedResults)
        for (final service in result.rule.services)
          if (seen.add(service.name)) service,
    ];
  }

  Future<void> checkAccess() async {
    if (_checkingAccess) return;
    _checkingAccess = true;
    _accessChecked = false;
    _notify();
    try {
      _isElevated = await access.isElevated();
      _accessError = null;
    } catch (error) {
      _isElevated = false;
      _accessError = '$error';
    } finally {
      _checkingAccess = false;
      _accessChecked = true;
      _notify();
    }
  }

  Future<bool> relaunchElevated() async {
    if (_relaunching) return false;
    _relaunching = true;
    _notice = null;
    _error = null;
    _notify();
    try {
      final launched = await access.relaunchElevated();
      if (!launched) {
        _notice = tr('已取消管理员授权，未做任何更改。');
      }
      return launched;
    } catch (error) {
      _error = trf('无法以管理员身份重新启动：{error}', {'error': error});
      return false;
    } finally {
      _relaunching = false;
      _notify();
    }
  }

  Future<void> scan() async {
    if (isBusy) return;

    _notice = null;
    _error = null;
    if (!_isElevated) {
      await checkAccess();
    }
    if (!_isElevated) {
      _notice = _accessError ?? tr('系统级缓存清理需要管理员权限。');
      _notify();
      return;
    }

    _phase = SystemCachePhase.scanning;
    _scanProgress = const ScanProgress(
      jobIndex: 0,
      jobCount: 0,
      ruleId: null,
      scannedFiles: 0,
      foundFiles: 0,
      foundBytes: 0,
    );
    _results = const [];
    _selectedRuleIds = <String>{};
    _resetLockProbeState();
    _scanDirectoryErrors = 0;
    _scanTruncated = false;
    _lastReport = null;
    _cleanProgress = null;
    _cleanStage = null;
    _notify();

    final service = _scanServiceFactory();
    _scanService = service;

    try {
      final jobs = <ScanJob>[];
      final rootsByRule = <String, List<String>>{};
      for (final rule in platform.rules) {
        final roots = await platform.resolveRoots(rule);
        if (roots.isEmpty) continue;
        rootsByRule[rule.id] = roots;
        jobs.add(ScanJob(ruleId: rule.id, roots: roots));
      }
      if (jobs.isEmpty) {
        _phase = SystemCachePhase.idle;
        _notice = tr('没有找到可扫描的系统缓存目录。');
        _notify();
        return;
      }
      _scanRoots = ScanRoots.fromJobs(jobs);

      final result = await service.scan(
        jobs: jobs,
        excludedPaths: [?quarantineRoot],
        onProgress: (progress) {
          _scanProgress = progress;
          _notify();
        },
      );

      if (result.cancelled) {
        _phase = SystemCachePhase.idle;
        _notice = tr('扫描已取消。');
        _notify();
        return;
      }

      _scanDirectoryErrors = result.directoryErrors;
      _scanTruncated = result.truncated;
      _results = _groupResults(result.items, rootsByRule);
      _selectedRuleIds = <String>{};
      _phase = SystemCachePhase.preview;
      if (_results.isEmpty) {
        _notice = tr('没有发现可清理的系统缓存。');
      }
      _notify();
      _startLockProbe();
    } catch (error) {
      _phase = SystemCachePhase.idle;
      _error = trf('扫描失败：{error}', {'error': error});
      _notify();
    } finally {
      _scanService = null;
      service.dispose();
    }
  }

  void cancelScan() {
    if (_phase != SystemCachePhase.scanning) return;
    _scanService?.cancel();
  }

  void toggleRule(String ruleId) {
    if (_selectedRuleIds.contains(ruleId)) {
      _selectedRuleIds.remove(ruleId);
    } else {
      _selectedRuleIds.add(ruleId);
    }
    _notify();
  }

  void selectAllRules() {
    _selectedRuleIds = {for (final result in _results) result.rule.id};
    _notify();
  }

  void clearRuleSelection() {
    _selectedRuleIds = <String>{};
    _notify();
  }

  Future<void> cleanSelected() async {
    if (_phase != SystemCachePhase.preview) return;
    final items = selectedItems;
    if (items.isEmpty) return;

    _cancelLockProbe();
    _phase = SystemCachePhase.cleaning;
    _cleanCancelRequested = false;
    _cleanStage = selectedServices.isEmpty
        ? SystemCleanStage.deleting
        : SystemCleanStage.stoppingServices;
    _cleanProgress = SystemCleanProgress(
      processed: 0,
      total: items.length,
      deleted: 0,
      deletedBytes: 0,
    );
    _error = null;
    _notify();

    final roots = <String, List<String>>{
      for (final result in selectedResults) result.rule.id: result.roots,
    };
    final services = [for (final service in selectedServices) service.name];

    try {
      final report = await cleaner.clean(
        items: items,
        roots: _scanRoots,
        rootsByRule: roots,
        serviceNames: services,
        onStage: (stage) {
          _cleanStage = stage;
          _notify();
        },
        onProgress: (progress) {
          _cleanProgress = progress;
          _notify();
        },
        isCancelled: () => _cleanCancelRequested,
      );
      _lastReport = report;
      _cleanProgress = null;
      _cleanStage = null;
      _phase = SystemCachePhase.done;
      _notify();
    } catch (error) {
      _phase = SystemCachePhase.preview;
      _cleanProgress = null;
      _cleanStage = null;
      _error = trf('清理失败：{error}', {'error': error});
      _notify();
    }
  }

  void cancelCleaning() {
    if (_phase != SystemCachePhase.cleaning) return;
    _cleanCancelRequested = true;
    _notify();
  }

  void returnToIdle() {
    _resetLockProbeState();
    _phase = SystemCachePhase.idle;
    _results = const [];
    _selectedRuleIds = <String>{};
    _lastReport = null;
    _cleanProgress = null;
    _cleanStage = null;
    _notice = null;
    _error = null;
    _notify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  List<SystemRuleResult> _groupResults(
    List<JunkItem> items,
    Map<String, List<String>> rootsByRule,
  ) {
    final grouped = <String, List<JunkItem>>{};
    for (final item in items) {
      grouped
          .putIfAbsent(_scanRoots.at(item.rootIndex).ruleId, () => [])
          .add(item);
    }

    final results = <SystemRuleResult>[];
    for (final rule in platform.rules) {
      final ruleItems = grouped.remove(rule.id);
      if (ruleItems == null || ruleItems.isEmpty) continue;
      ruleItems.sort((a, b) => b.size.compareTo(a.size));
      results.add(
        SystemRuleResult(
          rule: rule,
          roots: rootsByRule[rule.id] ?? const [],
          items: ruleItems,
        ),
      );
    }
    return results;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _resetLockProbeState() {
    _lockProbeGeneration++;
    _lockProbeRunning = false;
    _lockProbeChecked = 0;
    _lockProbeTotal = 0;
    _lockedCountByRule.clear();
  }

  void _cancelLockProbe() {
    _lockProbeGeneration++;
    _lockProbeRunning = false;
  }

  void _startLockProbe() {
    _lockedCountByRule.clear();
    final paths = <String>[];
    final starts = <int>[];
    for (final result in _results) {
      starts.add(paths.length);
      for (final item in result.items) {
        paths.add(item.path);
        if (!item.possiblyLocked) continue;
        _lockedCountByRule[result.rule.id] =
            (_lockedCountByRule[result.rule.id] ?? 0) + 1;
      }
    }
    if (paths.isEmpty) return;
    final generation = ++_lockProbeGeneration;
    _lockProbeRunning = true;
    _lockProbeChecked = 0;
    _lockProbeTotal = paths.length;
    _notify();
    unawaited(_runLockProbe(generation, paths, starts));
  }

  Future<void> _runLockProbe(
    int generation,
    List<String> paths,
    List<int> starts,
  ) async {
    var lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
    await runLockProbe(
      probe: _lockProbe,
      paths: paths,
      isActive: () => !_disposed && generation == _lockProbeGeneration,
      onBatch: (lockedIndexes, checked) async {
        _lockProbeChecked = checked;
        for (final index in lockedIndexes) {
          _markPossiblyLocked(index, starts);
        }
        final now = DateTime.now();
        if (now.difference(lastNotifyAt) >= const Duration(milliseconds: 120)) {
          lastNotifyAt = now;
          _notify();
        }
      },
    );
    if (_disposed || generation != _lockProbeGeneration) return;
    _lockProbeRunning = false;
    _notify();
  }

  void _markPossiblyLocked(int index, List<int> starts) {
    if (starts.isEmpty || index < 0) return;
    var resultIndex = starts.length - 1;
    while (resultIndex > 0 && index < starts[resultIndex]) {
      resultIndex--;
    }
    final result = _results[resultIndex];
    final itemIndex = index - starts[resultIndex];
    if (itemIndex < 0 || itemIndex >= result.items.length) return;
    final current = result.items[itemIndex];
    if (current.possiblyLocked) return;
    result.items[itemIndex] = current.copyWith(possiblyLocked: true);
    _lockedCountByRule[result.rule.id] =
        (_lockedCountByRule[result.rule.id] ?? 0) + 1;
  }

  @override
  void dispose() {
    _disposed = true;
    _lockProbeGeneration++;
    _scanService?.dispose();
    _scanService = null;
    super.dispose();
  }
}
