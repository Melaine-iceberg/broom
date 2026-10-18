import 'package:flutter/foundation.dart';

import '../core/clean/system_cache_cleaner.dart';
import '../core/models/scan_models.dart';
import '../core/models/system_models.dart';
import '../core/platform/system_access.dart';
import '../l10n/broom_strings.dart';
import '../core/platform/system_cache_platform.dart';
import '../core/scan/scan_service.dart';

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
  }) : _scanServiceFactory = scanServiceFactory ?? ScanService.new;

  final SystemCachePlatform platform;
  final SystemAccess access;
  final SystemCacheCleaner cleaner;
  final String? quarantineRoot;
  final ScanService Function() _scanServiceFactory;

  SystemCachePhase _phase = SystemCachePhase.idle;
  bool _isElevated = false;
  bool _accessChecked = false;
  bool _checkingAccess = false;
  bool _relaunching = false;
  String? _accessError;
  ScanProgress? _scanProgress;
  List<SystemRuleResult> _results = const [];
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
      grouped.putIfAbsent(item.ruleId, () => []).add(item);
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

  @override
  void dispose() {
    _disposed = true;
    _scanService?.dispose();
    _scanService = null;
    super.dispose();
  }
}
