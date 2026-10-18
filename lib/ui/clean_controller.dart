import 'package:flutter/foundation.dart';

import '../core/clean/quarantine_service.dart';
import '../core/models/clean_models.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/scan_models.dart';
import '../core/platform/cleaner_platform.dart';
import '../core/safety/path_guard.dart';
import '../core/scan/scan_service.dart';
import '../core/settings/exclusion_store.dart';

enum CleanPhase { idle, scanning, preview, cleaning, done }

enum RuleExclusionScope { none, partial, all }

class RuleResult {
  RuleResult({required this.rule, required this.items})
    : totalBytes = items.fold(0, (total, item) => total + item.size);

  final CleanerRule rule;
  final List<JunkItem> items;
  final int totalBytes;
}

class CleanController extends ChangeNotifier {
  CleanController({
    required this.platform,
    required this.guard,
    required this.quarantine,
    required this.exclusions,
    ScanService Function()? scanServiceFactory,
  }) : _scanServiceFactory = scanServiceFactory ?? ScanService.new;

  final CleanerPlatform platform;
  final PathGuard guard;
  final QuarantineService quarantine;
  final ExclusionStore exclusions;
  final ScanService Function() _scanServiceFactory;

  CleanPhase _phase = CleanPhase.idle;
  ScanProgress? _scanProgress;
  List<RuleResult> _results = const [];
  Set<String> _selectedRuleIds = <String>{};
  CleanReport? _lastReport;
  CleanProgress? _cleanProgress;
  List<QuarantineSessionInfo> _pendingSessions = const [];
  Map<String, RuleExclusionScope> _ruleExclusionScopes = const {};
  int _scanDirectoryErrors = 0;
  bool _scanTruncated = false;
  bool _scanStarting = false;
  bool _initialized = false;
  bool _exclusionsReady = false;
  String? _exclusionError;
  int _scopeRevision = 0;
  String? _notice;
  String? _error;
  bool _undoBusy = false;
  bool _cleanCancelRequested = false;
  ScanService? _scanService;
  bool _disposed = false;

  CleanPhase get phase => _phase;
  ScanProgress? get scanProgress => _scanProgress;
  List<RuleResult> get results => _results;
  CleanReport? get lastReport => _lastReport;
  CleanProgress? get cleanProgress => _cleanProgress;
  List<QuarantineSessionInfo> get pendingSessions => _pendingSessions;
  List<QuarantineSessionInfo> get unfinishedSessions => [
    for (final session in _pendingSessions)
      if (session.status == QuarantineStatus.partial) session,
  ];
  QuarantineSessionInfo? get latestPendingSession =>
      _pendingSessions.isEmpty ? null : _pendingSessions.first;
  int get pendingBytes => _pendingSessions.fold<int>(
    0,
    (total, session) => total + session.pendingBytes,
  );
  int get pendingFileCount => _pendingSessions.fold<int>(
    0,
    (total, session) => total + session.pendingCount,
  );
  Map<String, RuleExclusionScope> get ruleExclusionScopes =>
      _ruleExclusionScopes;
  int get exclusionCount => exclusions.paths.length;
  bool get initialized => _initialized;
  bool get exclusionsLoaded => _exclusionsReady;
  String? get exclusionError => _exclusionError;
  int get scanDirectoryErrors => _scanDirectoryErrors;
  bool get scanTruncated => _scanTruncated;
  String? get notice => _notice;
  String? get error => _error;
  bool get undoBusy => _undoBusy;
  bool get cleanCancelRequested => _cleanCancelRequested;
  bool get isBusy =>
      _phase == CleanPhase.scanning || _phase == CleanPhase.cleaning;

  bool get canUndoLastReport {
    final id = _lastReport?.sessionId;
    if (id == null) return false;
    return _pendingSessions.any((session) => session.id == id);
  }

  int get selectedCount => selectedItems.length;
  int get selectedBytes =>
      selectedItems.fold(0, (total, item) => total + item.size);

  List<JunkItem> get selectedItems => [
    for (final result in _results)
      if (_selectedRuleIds.contains(result.rule.id)) ...result.items,
  ];

  bool isRuleSelected(String ruleId) => _selectedRuleIds.contains(ruleId);

  String? get scanningRuleTitle {
    final ruleId = _scanProgress?.ruleId;
    if (ruleId == null) return null;
    for (final rule in platform.rules) {
      if (rule.id == ruleId) return rule.title;
    }
    return null;
  }

  Future<void> initialize() async {
    await _ensureExclusionsLoaded();
    await _refreshPendingSessions(notify: false);
    _initialized = true;
    _notify();
  }

  Future<void> scan() async {
    if (isBusy || _scanStarting) return;
    _scanStarting = true;
    try {
      await _ensureExclusionsLoaded();
      if (_exclusionError != null) {
        _error = '$_exclusionError 请打开“排除列表”页面重置后重试。';
        _notify();
        return;
      }

      _notice = null;
      _error = null;
      _phase = CleanPhase.scanning;
      _scanProgress = ScanProgress(
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
      _notify();

      final service = _scanServiceFactory();
      _scanService = service;

      try {
        final jobs = await _buildScanJobs();
        if (jobs.isEmpty) {
          _phase = CleanPhase.idle;
          _notice = exclusions.paths.isEmpty
              ? '没有找到可扫描的缓存目录。'
              : '没有可扫描的缓存目录（可能已被排除列表覆盖）。';
          _notify();
          return;
        }

        final excludedPaths = <String>[
          ...exclusions.paths,
          ?platform.quarantineRoot,
          ...guard.protectedRoots,
        ];

        final result = await service.scan(
          jobs: jobs,
          excludedPaths: excludedPaths,
          onProgress: (progress) {
            _scanProgress = progress;
            _notify();
          },
        );

        if (result.cancelled) {
          _phase = CleanPhase.idle;
          _notice = '扫描已取消。';
          _notify();
          return;
        }

        _scanDirectoryErrors = result.directoryErrors;
        _scanTruncated = result.truncated;
        _results = _groupResults(result.items);
        _selectedRuleIds = {for (final result in _results) result.rule.id};
        _phase = CleanPhase.preview;
        if (_results.isEmpty) {
          _notice = '没有发现可清理的内容。';
        }
        _notify();
      } catch (error) {
        _phase = CleanPhase.idle;
        _error = '扫描失败：$error';
        _notify();
      } finally {
        _scanService = null;
        service.dispose();
      }
    } finally {
      _scanStarting = false;
    }
  }

  void cancelScan() {
    if (_phase != CleanPhase.scanning) return;
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
    if (_phase != CleanPhase.preview) return;
    final items = selectedItems;
    if (items.isEmpty) return;

    _phase = CleanPhase.cleaning;
    _cleanProgress = CleanProgress(
      moved: 0,
      processed: 0,
      total: items.length,
      movedBytes: 0,
    );
    _cleanCancelRequested = false;
    _error = null;
    _notify();

    try {
      final report = await quarantine.clean(
        items,
        onProgress: (progress) {
          _cleanProgress = progress;
          _notify();
        },
        isCancelled: () => _cleanCancelRequested,
      );
      _lastReport = report;
      _cleanProgress = null;
      _phase = CleanPhase.done;
      await _refreshPendingSessions(notify: false);
      _notify();
    } catch (error) {
      _phase = CleanPhase.preview;
      _cleanProgress = null;
      _error = '清理失败：$error';
      await _refreshPendingSessions(notify: false);
      _notify();
    }
  }

  void cancelCleaning() {
    if (_phase != CleanPhase.cleaning) return;
    _cleanCancelRequested = true;
    _notify();
  }

  Future<void> refreshQuarantine() async {
    await _refreshPendingSessions(notify: true);
  }

  Future<UndoReport> undo(String sessionId) async {
    if (_undoBusy) {
      throw StateError('正在执行撤销，请稍候');
    }
    _undoBusy = true;
    _error = null;
    _notify();
    try {
      final report = await quarantine.undo(sessionId);
      await _refreshPendingSessions(notify: false);
      return report;
    } catch (error) {
      _error = '撤销失败：$error';
      rethrow;
    } finally {
      _undoBusy = false;
      _notify();
    }
  }

  void returnHome() {
    _phase = CleanPhase.idle;
    _results = const [];
    _selectedRuleIds = <String>{};
    _lastReport = null;
    _cleanProgress = null;
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

  Future<String?> addExclusion(String path) =>
      _changeExclusions(() => exclusions.add(path), '添加');

  Future<String?> removeExclusion(String path) =>
      _changeExclusions(() => exclusions.remove(path), '移除');

  Future<String?> resetExclusions() async {
    try {
      await exclusions.reset();
      _exclusionsReady = true;
      _exclusionError = null;
      await _refreshRuleExclusionScopes(notify: false);
      _notify();
      return null;
    } on ExclusionException catch (error) {
      return error.message;
    } catch (error) {
      return '无法重置排除列表：$error';
    }
  }

  Future<void> refreshRuleExclusionScopes() =>
      _refreshRuleExclusionScopes(notify: true);

  Future<String?> _changeExclusions(
    Future<void> Function() change,
    String action,
  ) async {
    await _ensureExclusionsLoaded();
    if (!_exclusionsReady) {
      return _exclusionError ?? '无法读取排除列表。';
    }
    try {
      await change();
      await _refreshRuleExclusionScopes(notify: false);
      _notify();
      return null;
    } on ExclusionException catch (error) {
      return error.message;
    } catch (error) {
      return '无法$action排除项：$error';
    }
  }

  Future<List<ScanJob>> _buildScanJobs() async {
    final jobs = <ScanJob>[];
    final seenRoots = <String>{};
    for (final rule in platform.rules.where(
      (rule) => rule.risk == CleanRisk.safe,
    )) {
      final resolvedRoots = await platform.resolveRoots(rule);
      final safeRoots = <String>[];
      for (final root in resolvedRoots) {
        if (guard.isProtected(root)) continue;
        if (exclusions.excludes(root)) continue;
        final key = PathGuard.normalize(root).toLowerCase();
        if (!seenRoots.add(key)) continue;
        safeRoots.add(root);
      }
      if (safeRoots.isEmpty) continue;
      jobs.add(
        ScanJob(
          ruleId: rule.id,
          roots: safeRoots,
          minAge: rule.minAge,
          extensions: rule.extensions,
        ),
      );
    }
    return jobs;
  }

  Future<void> _ensureExclusionsLoaded() async {
    if (_exclusionsReady) return;
    try {
      await exclusions.ensureLoaded();
      _exclusionsReady = true;
      _exclusionError = null;
    } catch (_) {
      _exclusionsReady = false;
      _exclusionError = exclusions.loadError ?? '无法读取排除列表。';
    }
    if (_exclusionsReady) {
      await _refreshRuleExclusionScopes(notify: false);
    } else {
      _ruleExclusionScopes = const {};
    }
  }

  Future<void> _refreshRuleExclusionScopes({required bool notify}) async {
    final revision = ++_scopeRevision;
    if (!_exclusionsReady) {
      _ruleExclusionScopes = const {};
      if (notify) _notify();
      return;
    }

    final safeRules = platform.rules.where(
      (rule) => rule.risk == CleanRisk.safe,
    );
    final scopes = <String, RuleExclusionScope>{};
    if (exclusions.paths.isEmpty) {
      for (final rule in safeRules) {
        scopes[rule.id] = RuleExclusionScope.none;
      }
      if (revision != _scopeRevision) return;
      _ruleExclusionScopes = scopes;
      if (notify) _notify();
      return;
    }

    for (final rule in safeRules) {
      List<String> roots;
      try {
        roots = await platform.resolveRoots(rule);
      } catch (_) {
        continue;
      }
      final candidates = [
        for (final root in roots)
          if (!guard.isProtected(root)) root,
      ];
      if (candidates.isEmpty) continue;
      final excludedCount = candidates.where(exclusions.excludes).length;
      if (excludedCount == candidates.length) {
        scopes[rule.id] = RuleExclusionScope.all;
      } else if (excludedCount > 0 ||
          candidates.any((root) => exclusions.intersects(root))) {
        scopes[rule.id] = RuleExclusionScope.partial;
      } else {
        scopes[rule.id] = RuleExclusionScope.none;
      }
    }

    if (revision != _scopeRevision) return;
    _ruleExclusionScopes = scopes;
    if (notify) _notify();
  }

  List<RuleResult> _groupResults(List<JunkItem> items) {
    final grouped = <String, List<JunkItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.ruleId, () => []).add(item);
    }

    final results = <RuleResult>[];
    for (final rule in platform.rules) {
      final ruleItems = grouped.remove(rule.id);
      if (ruleItems == null || ruleItems.isEmpty) continue;
      ruleItems.sort((a, b) => b.size.compareTo(a.size));
      results.add(RuleResult(rule: rule, items: ruleItems));
    }
    return results;
  }

  Future<void> _refreshPendingSessions({bool notify = true}) async {
    try {
      _pendingSessions = await quarantine.listSessions();
    } catch (_) {
      _pendingSessions = const [];
    }
    if (notify) _notify();
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
