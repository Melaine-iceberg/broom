import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/clean/quarantine_service.dart';
import '../core/diagnostics/app_logger.dart';
import '../core/models/clean_models.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/scan_models.dart';
import '../core/platform/cleaner_platform.dart';
import '../core/platform/file_lock_probe.dart';
import '../core/safety/path_guard.dart';
import '../core/scan/ntfs_index.dart';
import '../core/scan/scan_result_store.dart';
import '../core/scan/scan_service.dart';
import '../core/settings/exclusion_store.dart';
import '../l10n/broom_strings.dart';

enum CleanPhase { idle, scanning, preview, cleaning, done }

enum RuleExclusionScope { none, partial, all }

class RuleResult {
  RuleResult({required this.rule, required this.items})
    : totalBytes = items.fold(0, (total, item) => total + item.size);

  final CleanerRule rule;
  final List<JunkItem> items;
  final int totalBytes;
}

class ScanIssueGroup {
  const ScanIssueGroup({
    required this.kind,
    required this.count,
    required this.samplePaths,
  });

  final ScanErrorKind kind;
  final int count;
  final List<String> samplePaths;
}

enum RuleRootState { active, protected, excluded }

/// A resolved rule root as seen by the current safety configuration. The rule
/// detail page uses this to explain where a scan will actually look.
class RuleRootInspection {
  const RuleRootInspection({required this.path, required this.state});

  final String path;
  final RuleRootState state;
}

class CleanController extends ChangeNotifier {
  CleanController({
    required this.platform,
    required this.guard,
    required this.quarantine,
    required this.exclusions,
    this.isRuleEnabled,
    this.scanSettings,
    this.scanResultStore,
    this.ntfsIndex,
    ScanService Function()? scanServiceFactory,
    FileLockProbe? lockProbe,
    this.logger,
  }) : _scanServiceFactory = scanServiceFactory ?? ScanService.new,
       _lockProbe = lockProbe ?? const NoopFileLockProbe();

  final CleanerPlatform platform;
  final PathGuard guard;
  final QuarantineService quarantine;
  final ExclusionStore exclusions;
  bool Function(String ruleId)? isRuleEnabled;
  ScanSettings Function()? scanSettings;
  final ScanResultStore? scanResultStore;
  final NtfsIndex? ntfsIndex;
  final ScanService Function() _scanServiceFactory;
  final FileLockProbe _lockProbe;
  final AppLogger? logger;

  CleanPhase _phase = CleanPhase.idle;
  ScanProgress? _scanProgress;
  List<RuleResult> _results = const [];
  final Set<String> _selectedPaths = <String>{};
  final Map<String, int> _selectedCountByRule = <String, int>{};
  final Map<String, JunkItem> _itemsByPath = <String, JunkItem>{};
  CleanReport? _lastReport;
  CleanProgress? _cleanProgress;
  List<QuarantineSessionInfo> _pendingSessions = const [];
  Map<String, RuleExclusionScope> _ruleExclusionScopes = const {};
  int _scanDirectoryErrors = 0;
  bool _scanTruncated = false;
  int _scanScannedFiles = 0;
  Duration? _scanElapsed;
  bool _scanStarting = false;
  final Map<String, List<JunkItem>> _streamItemsByRule = {};
  final List<JunkItem> _recentScanItems = [];
  final Map<ScanErrorKind, int> _issueCounts = {};
  final Map<ScanErrorKind, List<String>> _issueSamples = {};
  int _liveFoundCount = 0;
  int _liveFoundBytes = 0;
  static const _streamNotifyInterval = Duration(milliseconds: 200);
  DateTime _lastStreamNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _persistQueue = Future<void>.value();
  String? _persistenceNotice;
  StoredScanSummary? _lastScanSummary;
  bool _restoringLastScan = false;
  bool _scanRestoredFromPersistence = false;
  Set<String> _activeCategoryIds = const {};
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
  int _lockProbeGeneration = 0;
  bool _lockProbeRunning = false;
  int _lockProbeChecked = 0;
  int _lockProbeTotal = 0;
  int _possiblyLockedCount = 0;
  final Map<String, int> _lockedCountByRule = <String, int>{};
  final Map<String, ({int ruleIndex, int itemIndex})> _itemLocations = {};

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
  int get scanScannedFiles => _scanScannedFiles;
  Duration? get scanElapsed => _scanElapsed;
  String get rulesVersion => platform.rulesVersion;
  int get liveFoundCount => _liveFoundCount;
  int get liveFoundBytes => _liveFoundBytes;
  List<JunkItem> get recentScanItems => List.unmodifiable(_recentScanItems);
  Set<String> get activeCategoryIds => _activeCategoryIds;
  Map<String, int> get liveRuleCounts => {
    for (final entry in _streamItemsByRule.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.length,
  };
  String? get scanPersistenceNotice => _persistenceNotice;
  StoredScanSummary? get lastScanSummary => _lastScanSummary;
  bool get restoringLastScan => _restoringLastScan;
  bool get scanRestoredFromPersistence => _scanRestoredFromPersistence;

  bool get lastScanStale {
    final summary = _lastScanSummary;
    if (summary == null) return false;
    if (summary.rulesVersion != platform.rulesVersion) return true;
    final currentIds = {for (final rule in platform.rules) rule.id};
    return summary.ruleIds.any((id) => !currentIds.contains(id));
  }

  List<ScanIssueGroup> get scanIssueGroups {
    final entries = _issueCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final entry in entries)
        ScanIssueGroup(
          kind: entry.key,
          count: entry.value,
          samplePaths: List.unmodifiable(_issueSamples[entry.key] ?? const []),
        ),
    ];
  }

  String? get notice => _notice;
  String? get error => _error;
  bool get undoBusy => _undoBusy;
  bool get cleanCancelRequested => _cleanCancelRequested;
  bool get isBusy =>
      _phase == CleanPhase.scanning || _phase == CleanPhase.cleaning;
  bool get lockProbeRunning => _lockProbeRunning;
  int get lockProbeChecked => _lockProbeChecked;
  int get lockProbeTotal => _lockProbeTotal;
  int get possiblyLockedCount => _possiblyLockedCount;

  int possiblyLockedCountForRule(String ruleId) =>
      _lockedCountByRule[ruleId] ?? 0;

  int get selectedPossiblyLockedCount {
    var count = 0;
    for (final result in _results) {
      for (final item in result.items) {
        if (item.possiblyLocked && _selectedPaths.contains(item.path)) {
          count++;
        }
      }
    }
    return count;
  }

  bool get canUndoLastReport {
    final id = _lastReport?.sessionId;
    if (id == null) return false;
    return _pendingSessions.any(
      (session) => session.id == id && session.pendingCount > 0,
    );
  }

  bool get canResumeLastReport {
    final id = _lastReport?.sessionId;
    if (id == null) return false;
    return _pendingSessions.any(
      (session) => session.id == id && session.resumable,
    );
  }

  int get selectedCount => _selectedPaths.length;
  int get selectedBytes =>
      selectedItems.fold(0, (total, item) => total + item.size);

  int get selectedReviewRuleCount => _results
      .where(
        (result) =>
            result.rule.risk == CleanRisk.review &&
            (_selectedCountByRule[result.rule.id] ?? 0) > 0,
      )
      .length;

  bool get hasSelectedReview => selectedReviewRuleCount > 0;

  int get previewReviewRuleCount =>
      _results.where((result) => result.rule.risk == CleanRisk.review).length;

  List<JunkItem> get selectedItems => [
    for (final result in _results)
      for (final item in result.items)
        if (_selectedPaths.contains(item.path)) item,
  ];

  bool get allItemsSelected =>
      _results.isNotEmpty &&
      _results.every(
        (result) => _selectedCountByRule[result.rule.id] == result.items.length,
      );

  bool get hasSelection => _selectedPaths.isNotEmpty;

  bool isItemSelected(String path) => _selectedPaths.contains(path);

  bool isRuleSelected(String ruleId) {
    final result = _findResult(ruleId);
    if (result == null || result.items.isEmpty) return false;
    return _selectedCountByRule[ruleId] == result.items.length;
  }

  bool? ruleSelectionValue(String ruleId) {
    final result = _findResult(ruleId);
    if (result == null || result.items.isEmpty) return false;
    final selected = _selectedCountByRule[ruleId] ?? 0;
    if (selected == 0) return false;
    if (selected == result.items.length) return true;
    return null;
  }

  int selectedCountForRule(String ruleId) => _selectedCountByRule[ruleId] ?? 0;

  int selectedBytesForRule(String ruleId) {
    var total = 0;
    for (final item in _findResult(ruleId)?.items ?? const <JunkItem>[]) {
      if (_selectedPaths.contains(item.path)) total += item.size;
    }
    return total;
  }

  Future<void> initialize() async {
    await _ensureExclusionsLoaded();
    await _refreshPendingSessions(notify: false);
    await _refreshLastScanSummary(notify: false);
    _initialized = true;
    _notify();
  }

  Future<void> _refreshLastScanSummary({bool notify = true}) async {
    final store = scanResultStore;
    if (store == null) {
      _lastScanSummary = null;
      if (notify) _notify();
      return;
    }
    try {
      _lastScanSummary = await store.loadLatest();
    } catch (_) {
      _lastScanSummary = null;
    }
    if (notify) _notify();
  }

  Future<void> restoreLastScan() async {
    if (isBusy || _restoringLastScan || _scanStarting || _undoBusy) return;
    final store = scanResultStore;
    final summary = _lastScanSummary;
    if (store == null || summary == null) {
      _error = tr('没有可恢复的上次扫描结果。');
      _notify();
      return;
    }
    _restoringLastScan = true;
    _error = null;
    _notice = null;
    _persistenceNotice = null;
    _notify();
    try {
      final data = await store.load(summary);
      if (data == null) {
        _lastScanSummary = null;
        _error = tr('上次扫描结果已不可用，请重新扫描。');
        _notify();
        return;
      }
      final settings = scanSettings?.call() ?? const ScanSettings();
      final allowedRules = {
        for (final rule in platform.rules)
          if ((isRuleEnabled?.call(rule.id) ?? true) &&
              settings.isCategoryEnabled(ruleCategoryKey(rule)))
            rule.id,
      };
      final restoredItems = [
        for (final item in data.items)
          if (allowedRules.contains(item.ruleId)) item,
      ];
      final filteredCount = data.items.length - restoredItems.length;
      _resetScanStreamState();
      _resetSelection();
      _resetLockProbeState();
      _results = _groupResults(restoredItems);
      _resetSelection();
      _selectDefaultItems(notify: false);
      _liveFoundCount = restoredItems.length;
      _liveFoundBytes = restoredItems.fold(
        0,
        (total, item) => total + item.size,
      );
      _scanDirectoryErrors = summary.issueCount;
      _scanScannedFiles = summary.scannedFiles;
      _scanElapsed = null;
      _issueCounts
        ..clear()
        ..addAll(summary.errorCounts);
      _issueSamples.clear();
      _scanTruncated = summary.truncated || summary.persistenceLimited;
      _scanRestoredFromPersistence = true;
      _lastReport = null;
      _cleanProgress = null;
      _phase = CleanPhase.preview;
      _notice = restoredItems.isEmpty
          ? tr('已恢复上次扫描结果：按当前规则与类别没有可清理的内容。')
          : trf('已恢复 {time} 的扫描结果，清理前会重新校验路径。', {
              'time': _formatRestoreTime(summary.completedAt),
            });
      if (filteredCount > 0) {
        _notice =
            '${_notice!} ${trf('已按当前规则与类别过滤 {count} 项。', {'count': filteredCount})}';
      }
      if (lastScanStale) {
        _notice = '${_notice!} ${tr('规则或内置目录已变化，建议重新扫描。')}';
      }
      if (summary.persistenceLimited) {
        _persistenceNotice = tr('上次扫描结果超出磁盘保护上限，持久化内容可能不完整。');
      }
      _notify();
      _startLockProbe();
    } catch (error) {
      _error = trf('无法恢复上次扫描结果：{error}', {'error': error});
      _notify();
    } finally {
      _restoringLastScan = false;
      _notify();
    }
  }

  String _formatRestoreTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> refreshLastScanSummary() => _refreshLastScanSummary();

  Future<void> scan() async {
    if (isBusy || _scanStarting || _undoBusy) return;
    _scanStarting = true;
    try {
      await _ensureExclusionsLoaded();
      if (_exclusionError != null) {
        _error = trf('{error} 请打开“排除列表”页面重置后重试。', {'error': _exclusionError});
        _notify();
        return;
      }

      _notice = null;
      _error = null;
      _persistenceNotice = null;
      _scanRestoredFromPersistence = false;
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
      _resetSelection();
      _resetLockProbeState();
      _resetScanStreamState();
      _scanDirectoryErrors = 0;
      _scanTruncated = false;
      _scanScannedFiles = 0;
      _scanElapsed = null;
      _lastReport = null;
      _cleanProgress = null;
      _notify();

      final service = _scanServiceFactory();
      _scanService = service;
      ScanResultWriter? writer;
      var writerFailed = false;

      try {
        final jobs = await _buildScanJobs();
        if (jobs.isEmpty) {
          _phase = CleanPhase.idle;
          _notice = exclusions.paths.isEmpty
              ? tr('没有找到可扫描的缓存目录。')
              : tr('没有可扫描的缓存目录（可能已被排除列表覆盖）。');
          logger?.info('scan', '没有可扫描的目录');
          _notify();
          return;
        }
        logger?.info(
          'scan',
          '开始扫描：${jobs.length} 个任务，'
              '${jobs.fold<int>(0, (total, job) => total + job.roots.length)} 个根目录',
        );

        final excludedPaths = <String>[
          ...exclusions.paths,
          ?platform.quarantineRoot,
          ...guard.protectedRoots,
        ];
        final store = scanResultStore;
        if (store != null) {
          try {
            writer = await store.begin(
              ruleIds: [for (final job in jobs) job.ruleId],
              rulesVersion: platform.rulesVersion,
            );
          } catch (error) {
            writerFailed = true;
            _persistenceNotice = trf('无法保存本次扫描结果：{error}', {'error': error});
          }
        }

        final settings = scanSettings?.call() ?? const ScanSettings();
        final result = await service.scan(
          jobs: jobs,
          excludedPaths: excludedPaths,
          options: settings.toOptions(),
          ntfsIndex: ntfsIndex,
          retainItems: false,
          onProgress: _acceptScanProgress,
          onItems: (items) {
            _acceptScanBatch(items);
            if (writer != null && !writerFailed) {
              _queuePersist(writer, items);
            }
          },
          onIssue: _acceptScanIssue,
        );

        await _persistQueue;

        if (result.cancelled) {
          await _abortWriter(writer);
          _phase = CleanPhase.idle;
          _notice = tr('扫描已取消。');
          logger?.info('scan', '扫描已取消');
          _notify();
          return;
        }

        _scanDirectoryErrors = result.directoryErrors;
        _scanTruncated = result.truncated;
        _scanScannedFiles = result.scannedFiles;
        _scanElapsed = result.elapsed;
        _results = _groupResultsFromStream();
        _resetSelection();
        _selectDefaultItems(notify: false);
        _phase = CleanPhase.preview;
        logger?.info(
          'scan',
          '扫描完成：扫描 ${result.scannedFiles} 个文件，'
              '命中 $_liveFoundCount 个，共 $_liveFoundBytes 字节，'
              '错误 ${result.directoryErrors} 个，耗时 ${result.elapsed.inMilliseconds} 毫秒',
        );
        if (_results.isEmpty) {
          _notice = tr('没有发现可清理的内容。');
        }
        _notify();

        if (writer != null) {
          try {
            final summary = await writer.complete(
              scannedFiles: result.scannedFiles,
              foundFiles: _liveFoundCount,
              foundBytes: _liveFoundBytes,
              issueCount: _scanDirectoryErrors,
              errorCounts: Map<ScanErrorKind, int>.of(_issueCounts),
              truncated: result.truncated,
            );
            _lastScanSummary = summary;
            if (summary.persistenceLimited) {
              _persistenceNotice = tr('扫描结果超出磁盘保护上限，持久化内容可能不完整。');
            }
          } catch (error) {
            _persistenceNotice = trf('无法保存本次扫描结果：{error}', {'error': error});
          }
        }
        _notify();
        _startLockProbe();
      } catch (error) {
        await _abortWriter(writer);
        _phase = CleanPhase.idle;
        _error = trf('扫描失败：{error}', {'error': error});
        logger?.error('scan', '扫描失败', error: error);
        _notify();
      } finally {
        _scanService = null;
        service.dispose();
      }
    } finally {
      _scanStarting = false;
    }
  }

  void _resetScanStreamState() {
    _streamItemsByRule.clear();
    _recentScanItems.clear();
    _issueCounts.clear();
    _issueSamples.clear();
    _liveFoundCount = 0;
    _liveFoundBytes = 0;
    _lastStreamNotify = DateTime.fromMillisecondsSinceEpoch(0);
    _persistQueue = Future<void>.value();
  }

  void _acceptScanProgress(ScanProgress progress) {
    _scanProgress = progress;
    _scanDirectoryErrors = progress.errorCount;
    _maybeNotifyScanStream();
  }

  void _acceptScanBatch(List<JunkItem> items) {
    if (items.isEmpty) return;
    for (final item in items) {
      _streamItemsByRule.putIfAbsent(item.ruleId, () => <JunkItem>[]).add(item);
      _liveFoundCount++;
      _liveFoundBytes += item.size;
    }
    _recentScanItems.insertAll(0, items.take(5));
    if (_recentScanItems.length > 8) {
      _recentScanItems.removeRange(8, _recentScanItems.length);
    }
    _maybeNotifyScanStream();
  }

  void _acceptScanIssue(ScanIssue issue) {
    _issueCounts[issue.kind] = (_issueCounts[issue.kind] ?? 0) + 1;
    final samples = _issueSamples.putIfAbsent(issue.kind, () => <String>[]);
    if (!samples.contains(issue.path) && samples.length < 5) {
      samples.add(issue.path);
    }
    _scanDirectoryErrors = _issueCounts.values.fold(0, (a, b) => a + b);
    _maybeNotifyScanStream();
  }

  // Progress, batches, and issues all feed the same live scanning surface, so
  // they share one throttled notification instead of rebuilding it per event.
  void _maybeNotifyScanStream() {
    final now = DateTime.now();
    if (now.difference(_lastStreamNotify) < _streamNotifyInterval) return;
    _lastStreamNotify = now;
    _notify();
  }

  void _queuePersist(ScanResultWriter writer, List<JunkItem> items) {
    _persistQueue = _persistQueue.then((_) async {
      try {
        await writer.addItems(items);
      } catch (error) {
        _persistenceNotice = trf('无法保存本次扫描结果：{error}', {'error': error});
      }
    });
  }

  Future<void> _abortWriter(ScanResultWriter? writer) async {
    if (writer == null) return;
    try {
      await _persistQueue;
    } catch (_) {
      // Individual writes report their own errors.
    }
    await writer.abort();
  }

  List<RuleResult> _groupResultsFromStream() {
    final results = <RuleResult>[];
    for (final rule in platform.rules) {
      final items = _streamItemsByRule[rule.id];
      if (items == null || items.isEmpty) continue;
      items.sort((a, b) => b.size.compareTo(a.size));
      results.add(RuleResult(rule: rule, items: items));
    }
    return results;
  }

  void cancelScan() {
    if (_phase != CleanPhase.scanning) return;
    _scanService?.cancel();
  }

  void toggleRule(String ruleId) {
    final result = _findResult(ruleId);
    if (result == null || result.items.isEmpty) return;
    if (isRuleSelected(ruleId)) {
      _setRuleSelected(ruleId, false, notify: false);
    } else {
      _setRuleSelected(ruleId, true, notify: false);
    }
    _notify();
  }

  void setRuleSelected(String ruleId, bool selected) {
    final result = _findResult(ruleId);
    if (result == null || result.items.isEmpty) return;
    _setRuleSelected(ruleId, selected, notify: false);
    _notify();
  }

  void toggleItem(String path) {
    final item = _itemsByPath[path];
    if (item == null) return;
    if (_selectedPaths.contains(path)) {
      _selectedPaths.remove(path);
      _selectedCountByRule[item.ruleId] =
          (_selectedCountByRule[item.ruleId] ?? 1) - 1;
    } else {
      _selectedPaths.add(path);
      _selectedCountByRule[item.ruleId] =
          (_selectedCountByRule[item.ruleId] ?? 0) + 1;
    }
    _notify();
  }

  void setItemSelected(String path, bool selected) {
    final item = _itemsByPath[path];
    if (item == null) return;
    final isSelected = _selectedPaths.contains(path);
    if (isSelected == selected) return;
    toggleItem(path);
  }

  void selectAllRules() {
    _selectAllItems(notify: false);
    _notify();
  }

  void invertSelection() {
    for (final entry in _itemsByPath.entries) {
      if (_selectedPaths.contains(entry.key)) {
        _selectedPaths.remove(entry.key);
      } else {
        _selectedPaths.add(entry.key);
      }
    }
    for (final result in _results) {
      _selectedCountByRule[result.rule.id] = result.items
          .where((item) => _selectedPaths.contains(item.path))
          .length;
    }
    _notify();
  }

  void invertRuleSelection(String ruleId) {
    final result = _findResult(ruleId);
    if (result == null) return;
    var selected = 0;
    for (final item in result.items) {
      if (_selectedPaths.remove(item.path)) continue;
      _selectedPaths.add(item.path);
      selected++;
    }
    _selectedCountByRule[ruleId] = selected;
    _notify();
  }

  void clearRuleSelection() {
    _selectedPaths.clear();
    _selectedCountByRule.clear();
    _notify();
  }

  void _selectAllItems({required bool notify}) {
    for (final result in _results) {
      for (final item in result.items) {
        _selectedPaths.add(item.path);
        _itemsByPath[item.path] = item;
      }
      _selectedCountByRule[result.rule.id] = result.items.length;
    }
    if (notify) _notify();
  }

  /// Review rules are opt-in: a fresh scan selects Safe rules only.
  void _selectDefaultItems({required bool notify}) {
    for (final result in _results) {
      for (final item in result.items) {
        _itemsByPath[item.path] = item;
        if (result.rule.risk != CleanRisk.safe) continue;
        _selectedPaths.add(item.path);
      }
      _selectedCountByRule[result.rule.id] = result.rule.risk == CleanRisk.safe
          ? result.items.length
          : 0;
    }
    if (notify) _notify();
  }

  void _setRuleSelected(String ruleId, bool selected, {required bool notify}) {
    final result = _findResult(ruleId);
    if (result == null) return;
    for (final item in result.items) {
      _itemsByPath[item.path] = item;
      if (selected) {
        _selectedPaths.add(item.path);
      } else {
        _selectedPaths.remove(item.path);
      }
    }
    _selectedCountByRule[ruleId] = selected ? result.items.length : 0;
    if (notify) _notify();
  }

  void _resetSelection() {
    _selectedPaths.clear();
    _selectedCountByRule.clear();
    _itemsByPath.clear();
  }

  Future<void> cleanSelected() async {
    if (_phase != CleanPhase.preview ||
        _scanStarting ||
        _restoringLastScan ||
        _undoBusy) {
      return;
    }
    final items = selectedItems;
    if (items.isEmpty) return;

    _cancelLockProbe();
    _phase = CleanPhase.cleaning;
    _cleanProgress = CleanProgress(
      moved: 0,
      processed: 0,
      total: items.length,
      movedBytes: 0,
    );
    _cleanCancelRequested = false;
    _error = null;
    logger?.info('clean', '开始清理：${items.length} 个文件');
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
      logger?.info(
        'clean',
        '清理结束：移动 ${report.movedCount} 个，跳过 ${report.skippedCount} 个，'
            '失败 ${report.failureCount} 个，剩余 ${report.remainingCount} 个，'
            '取消 ${report.cancelled}',
      );
      for (final failure in report.failures.take(20)) {
        logger?.warning('clean', '失败：${failure.path}：${failure.reason}');
      }
      await _refreshPendingSessions(notify: false);
      _notify();
    } on QuarantineSpaceException catch (error) {
      _phase = CleanPhase.preview;
      _cleanProgress = null;
      _error = trf('清理前磁盘空间检查未通过：{error}', {'error': error});
      logger?.warning('clean', '磁盘空间预检未通过', error: error);
      await _refreshPendingSessions(notify: false);
      _notify();
    } catch (error) {
      _phase = CleanPhase.preview;
      _cleanProgress = null;
      _error = trf('清理失败：{error}', {'error': error});
      logger?.error('clean', '清理失败', error: error);
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
      throw StateError(tr('正在执行撤销，请稍候'));
    }
    if (_phase == CleanPhase.scanning || _phase == CleanPhase.cleaning) {
      throw StateError(tr('扫描或清理进行中，无法撤销'));
    }
    _undoBusy = true;
    _error = null;
    logger?.info('undo', '开始撤销会话 $sessionId');
    _notify();
    try {
      final report = await quarantine.undo(sessionId);
      logger?.info(
        'undo',
        '撤销结束：恢复 ${report.restoredCount} 个，冲突 ${report.conflictCount} 个，'
            '失败 ${report.failureCount} 个，会话已移除 ${report.sessionRemoved}',
      );
      await _refreshPendingSessions(notify: false);
      return report;
    } catch (error) {
      _error = trf('撤销失败：{error}', {'error': error});
      logger?.error('undo', '撤销失败', error: error);
      rethrow;
    } finally {
      _undoBusy = false;
      _notify();
    }
  }

  void returnHome() {
    _resetLockProbeState();
    _phase = CleanPhase.idle;
    _results = const [];
    _resetSelection();
    _resetScanStreamState();
    _lastReport = null;
    _cleanProgress = null;
    _notice = null;
    _error = null;
    _persistenceNotice = null;
    _scanRestoredFromPersistence = false;
    _scanScannedFiles = 0;
    _scanElapsed = null;
    unawaited(_refreshLastScanSummary(notify: false));
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
      _changeExclusions(() => exclusions.add(path), tr('添加'));

  Future<String?> removeExclusion(String path) =>
      _changeExclusions(() => exclusions.remove(path), tr('移除'));

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
      return trf('无法重置排除列表：{error}', {'error': error});
    }
  }

  /// Replaces the exclusion list with an imported configuration.
  ///
  /// This also recovers from a corrupted exclusions file, matching the reset
  /// path: validation and the write happen before in-memory state changes.
  Future<String?> replaceExclusions(List<String> paths) async {
    try {
      await exclusions.replaceAll(paths);
      _exclusionsReady = true;
      _exclusionError = null;
      await _refreshRuleExclusionScopes(notify: false);
      _notify();
      return null;
    } on ExclusionException catch (error) {
      return error.message;
    } catch (error) {
      return trf('无法导入排除列表：{error}', {'error': error});
    }
  }

  Future<void> refreshRuleExclusionScopes() =>
      _refreshRuleExclusionScopes(notify: true);

  /// Resolves a rule again and reports whether each root currently takes part
  /// in scanning. This is read-only and is used by the rule detail page.
  Future<List<RuleRootInspection>> inspectRuleRoots(CleanerRule rule) async {
    await _ensureExclusionsLoaded();
    final roots = await platform.resolveRoots(rule);
    final seen = <String>{};
    final inspections = <RuleRootInspection>[];
    for (final root in roots) {
      final key = PathGuard.normalize(root).toLowerCase();
      if (!seen.add(key)) continue;
      final state = guard.isProtected(root)
          ? RuleRootState.protected
          : _exclusionsReady && exclusions.excludes(root)
          ? RuleRootState.excluded
          : RuleRootState.active;
      inspections.add(RuleRootInspection(path: root, state: state));
    }
    return inspections;
  }

  Future<String?> _changeExclusions(
    Future<void> Function() change,
    String action,
  ) async {
    await _ensureExclusionsLoaded();
    if (!_exclusionsReady) {
      return _exclusionError ?? tr('无法读取排除列表。');
    }
    try {
      await change();
      await _refreshRuleExclusionScopes(notify: false);
      _notify();
      return null;
    } on ExclusionException catch (error) {
      return error.message;
    } catch (error) {
      return trf('无法{action}排除项：{error}', {'action': action, 'error': error});
    }
  }

  Future<List<ScanJob>> _buildScanJobs() async {
    final jobs = <ScanJob>[];
    final seenRoots = <String>{};
    final settings = scanSettings?.call() ?? const ScanSettings();
    _activeCategoryIds = {
      for (final rule in platform.rules)
        if ((isRuleEnabled?.call(rule.id) ?? true) &&
            settings.isCategoryEnabled(ruleCategoryKey(rule)))
          ruleCategoryKey(rule),
    };
    for (final rule in platform.rules.where(
      (rule) =>
          (isRuleEnabled?.call(rule.id) ?? true) &&
          settings.isCategoryEnabled(ruleCategoryKey(rule)),
    )) {
      final resolvedRoots = await platform.resolveRoots(rule);
      final scanRoots = <String>[];
      for (final root in resolvedRoots) {
        if (guard.isProtected(root)) continue;
        if (exclusions.excludes(root)) continue;
        final key = PathGuard.normalize(root).toLowerCase();
        if (!seenRoots.add(key)) continue;
        scanRoots.add(root);
      }
      if (scanRoots.isEmpty) continue;
      jobs.add(
        ScanJob(
          ruleId: rule.id,
          roots: scanRoots,
          minAge: rule.minAge,
          extensions: rule.extensions,
          excludedRoots: await _resolveRuleExclusionRoots(rule),
        ),
      );
    }
    return jobs;
  }

  Future<List<String>> _resolveRuleExclusionRoots(CleanerRule rule) async {
    if (rule.excludedPathPatterns.isEmpty) return const [];
    return platform.resolveRoots(
      CleanerRule(
        id: '${rule.id}.excluded',
        title: rule.title,
        category: rule.category,
        description: rule.description,
        pathPatterns: rule.excludedPathPatterns,
        risk: rule.risk,
      ),
    );
  }

  Future<void> _ensureExclusionsLoaded() async {
    if (_exclusionsReady) return;
    try {
      await exclusions.ensureLoaded();
      _exclusionsReady = true;
      _exclusionError = null;
    } catch (_) {
      _exclusionsReady = false;
      _exclusionError = exclusions.loadError ?? tr('无法读取排除列表。');
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

    final rules = platform.rules;
    final scopes = <String, RuleExclusionScope>{};
    if (exclusions.paths.isEmpty) {
      for (final rule in rules) {
        scopes[rule.id] = RuleExclusionScope.none;
      }
      if (revision != _scopeRevision) return;
      _ruleExclusionScopes = scopes;
      if (notify) _notify();
      return;
    }

    for (final rule in rules) {
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
      } else if (excludedCount > 0 || candidates.any(exclusions.intersects)) {
        scopes[rule.id] = RuleExclusionScope.partial;
      } else {
        scopes[rule.id] = RuleExclusionScope.none;
      }
    }

    if (revision != _scopeRevision) return;
    _ruleExclusionScopes = scopes;
    if (notify) _notify();
  }

  RuleResult? _findResult(String ruleId) {
    for (final result in _results) {
      if (result.rule.id == ruleId) return result;
    }
    return null;
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

  void _resetLockProbeState() {
    _lockProbeGeneration++;
    _lockProbeRunning = false;
    _lockProbeChecked = 0;
    _lockProbeTotal = 0;
    _possiblyLockedCount = 0;
    _lockedCountByRule.clear();
    _itemLocations.clear();
  }

  void _cancelLockProbe() {
    _lockProbeGeneration++;
    _lockProbeRunning = false;
  }

  void _startLockProbe() {
    _possiblyLockedCount = 0;
    _lockedCountByRule.clear();
    _itemLocations.clear();
    final paths = <String>[];
    for (var ruleIndex = 0; ruleIndex < _results.length; ruleIndex++) {
      final items = _results[ruleIndex].items;
      for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
        final item = items[itemIndex];
        _itemLocations[item.path] = (
          ruleIndex: ruleIndex,
          itemIndex: itemIndex,
        );
        paths.add(item.path);
        if (!item.possiblyLocked) continue;
        _possiblyLockedCount++;
        _lockedCountByRule[item.ruleId] =
            (_lockedCountByRule[item.ruleId] ?? 0) + 1;
      }
    }
    if (paths.isEmpty) return;
    final generation = ++_lockProbeGeneration;
    _lockProbeRunning = true;
    _lockProbeChecked = 0;
    _lockProbeTotal = paths.length;
    _notify();
    unawaited(_runLockProbe(generation, paths));
  }

  Future<void> _runLockProbe(int generation, List<String> paths) async {
    var lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
    await runLockProbe(
      probe: _lockProbe,
      paths: paths,
      isActive: () => !_disposed && generation == _lockProbeGeneration,
      onBatch: (lockedPaths, checked) async {
        _lockProbeChecked = checked;
        for (final path in lockedPaths) {
          _markPossiblyLocked(path);
        }
        final now = DateTime.now();
        if (now.difference(lastNotifyAt) >= const Duration(milliseconds: 250)) {
          lastNotifyAt = now;
          _notify();
        }
      },
    );
    if (_disposed || generation != _lockProbeGeneration) return;
    _lockProbeRunning = false;
    _notify();
  }

  void _markPossiblyLocked(String path) {
    final location = _itemLocations[path];
    if (location == null) return;
    final result = _results[location.ruleIndex];
    final current = result.items[location.itemIndex];
    if (current.possiblyLocked) return;
    final updated = current.copyWith(possiblyLocked: true);
    result.items[location.itemIndex] = updated;
    _itemsByPath[path] = updated;
    _possiblyLockedCount++;
    _lockedCountByRule[current.ruleId] =
        (_lockedCountByRule[current.ruleId] ?? 0) + 1;
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
