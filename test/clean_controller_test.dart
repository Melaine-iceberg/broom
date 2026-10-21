import 'dart:async';
import 'dart:io';

import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/file_lock_probe.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:broom/core/scan/scan_result_store.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/quarantine_fakes.dart';

class _TestPlatform implements CleanerPlatform {
  _TestPlatform({required this.definedRules, required this.rootsByRule});

  final List<CleanerRule> definedRules;
  final Map<String, List<String>> rootsByRule;

  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => definedRules;

  @override
  String get rulesVersion => 'builtin';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async =>
      rootsByRule[rule.id] ?? const [];
}

class _RecordingScanService extends ScanService {
  _RecordingScanService({this.items = const []});

  final List<JunkItem> items;
  List<ScanJob>? jobs;
  List<String>? excludedPaths;
  bool disposed = false;

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
    this.jobs = jobs;
    this.excludedPaths = excludedPaths;
    if (items.isNotEmpty) onItems?.call(items);
    return ScanResult(
      items: retainItems ? items : const [],
      scannedFiles: items.length,
      directoryErrors: 0,
      truncated: false,
      cancelled: false,
    );
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _ControlledScanService extends ScanService {
  _ControlledScanService(this.items);

  final List<JunkItem> items;
  final started = Completer<void>();
  final release = Completer<void>();
  int calls = 0;

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
    if (!started.isCompleted) started.complete();
    await release.future;
    if (items.isNotEmpty) onItems?.call(items);
    return ScanResult(
      items: retainItems ? items : const [],
      scannedFiles: items.length,
      directoryErrors: 0,
      truncated: false,
      cancelled: false,
    );
  }
}

class _ControlledQuarantineService extends FakeQuarantineService {
  final started = Completer<void>();
  final release = Completer<void>();
  int cleanCalls = 0;

  @override
  Future<CleanReport> clean(
    List<JunkItem> items, {
    required ScanRoots roots,
    void Function(CleanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    cleanCalls++;
    cleanRequest = List.of(items);
    if (!started.isCompleted) started.complete();
    await release.future;
    return CleanReport(
      sessionId: FakeQuarantineService.sessionId,
      movedCount: items.length,
      movedBytes: items.fold(0, (total, item) => total + item.size),
      failureCount: 0,
      failures: const [],
      cancelled: false,
    );
  }
}

class _FakeLockProbe implements FileLockProbe {
  _FakeLockProbe(this.lockedPaths, {this.error});

  final Set<String> lockedPaths;
  final Object? error;
  final List<List<String>> batches = [];

  @override
  Future<List<bool>> probePossiblyLocked(List<String> paths) async {
    batches.add(List.of(paths));
    if (error != null) throw error!;
    return [for (final path in paths) lockedPaths.contains(path)];
  }
}

void main() {
  late Directory temp;
  late Directory rootA;
  late Directory rootB;
  late Directory rulesRoot;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_clean_controller_');
    rulesRoot = Directory(p.windows.join(temp.path, 'rules'));
    rootA = Directory(p.windows.join(rulesRoot.path, 'a'));
    rootB = Directory(p.windows.join(rulesRoot.path, 'b'));
    await rootA.create(recursive: true);
    await rootB.create(recursive: true);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ExclusionStore createStore() => ExclusionStore(
    filePath: p.windows.join(temp.path, 'settings', 'exclusions.json'),
  );

  CleanerRule createRule({
    String id = 'test.rule',
    CleanRisk risk = CleanRisk.safe,
    List<String> excludedPathPatterns = const [],
  }) => CleanerRule(
    id: id,
    title: '测试缓存',
    category: '测试',
    description: '测试规则',
    risk: risk,
    pathPatterns: const [],
    excludedPathPatterns: excludedPathPatterns,
  );

  CleanController createController({
    required ExclusionStore exclusions,
    _RecordingScanService? scanner,
    ScanService? scanService,
    required List<CleanerRule> rules,
    required Map<String, List<String>> rootsByRule,
    FileLockProbe? lockProbe,
    ScanSettings Function()? scanSettings,
    ScanResultStore? scanResultStore,
    FakeQuarantineService? quarantine,
  }) {
    final service = scanService ?? scanner;
    if (service == null) {
      throw ArgumentError('scanner or scanService is required');
    }
    return CleanController(
      platform: _TestPlatform(definedRules: rules, rootsByRule: rootsByRule),
      guard: PathGuard(protectedRoots: const []),
      quarantine: quarantine ?? FakeQuarantineService(),
      exclusions: exclusions,
      scanServiceFactory: () => service,
      lockProbe: lockProbe,
      scanSettings: scanSettings,
      scanResultStore: scanResultStore,
    );
  }

  test('surfaces a disk space preflight failure before moving files', () async {
    final exclusions = createStore();
    final quarantine = FakeQuarantineService()
      ..cleanError = const QuarantineSpaceException(
        assessment: QuarantineSpaceAssessment(
          requiredBytes: 2048,
          crossVolumeCount: 1,
          freeBytes: 1024,
          quarantineRoot: r'C:\Users\Alice\AppData\Local\Broom\quarantine',
        ),
      );
    final item = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'a.tmp'),
      size: 2048,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _RecordingScanService(items: [item]);
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
      quarantine: quarantine,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();
    expect(controller.selectedCount, 1);

    await controller.cleanSelected();

    expect(controller.phase, CleanPhase.preview);
    expect(controller.error, contains('磁盘空间检查未通过'));
    expect(controller.error, contains('空间不足'));
    expect(quarantine.cleanRequest, hasLength(1));
  });

  test(
    'filters excluded roots and forwards exclusions to the scanner',
    () async {
      final exclusions = createStore();
      await exclusions.ensureLoaded();
      await exclusions.add(rootB.path);
      final scanner = _RecordingScanService();
      final rule = createRule();
      final controller = createController(
        exclusions: exclusions,
        scanner: scanner,
        rules: [rule],
        rootsByRule: {
          rule.id: [rootA.path, rootB.path],
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.scan();

      expect(scanner.jobs, hasLength(1));
      expect(scanner.jobs!.single.roots, [PathGuard.normalize(rootA.path)]);
      expect(scanner.excludedPaths, contains(PathGuard.normalize(rootB.path)));
      expect(controller.phase, CleanPhase.preview);
    },
  );

  test('forwards per-rule excluded roots to the scanner job', () async {
    final exclusions = createStore();
    await exclusions.ensureLoaded();
    final scanner = _RecordingScanService();
    final rule = createRule(excludedPathPatterns: ['claimed']);
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
        '${rule.id}.excluded': [rootB.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();

    expect(scanner.jobs, hasLength(1));
    expect(scanner.jobs!.single.excludedRoots, [
      PathGuard.normalize(rootB.path),
    ]);
  });

  test('skips scanning when every rule root is excluded', () async {
    final exclusions = createStore();
    await exclusions.ensureLoaded();
    await exclusions.add(rulesRoot.path);
    final scanner = _RecordingScanService();
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path, rootB.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();

    expect(scanner.jobs, isNull);
    expect(controller.phase, CleanPhase.idle);
    expect(controller.notice, contains('排除列表'));
  });

  test('updates partial and full exclusion scopes for each rule', () async {
    final exclusions = createStore();
    final scanner = _RecordingScanService();
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path, rootB.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(await controller.addExclusion(rootA.path), isNull);
    expect(controller.ruleExclusionScopes[rule.id], RuleExclusionScope.partial);
    expect(controller.exclusionCount, 1);

    expect(await controller.removeExclusion(rootA.path), isNull);
    expect(controller.ruleExclusionScopes[rule.id], RuleExclusionScope.none);

    expect(await controller.addExclusion(rulesRoot.path), isNull);
    expect(controller.ruleExclusionScopes[rule.id], RuleExclusionScope.all);
  });

  test('replaces exclusions from an imported configuration', () async {
    final exclusions = createStore();
    final scanner = _RecordingScanService();
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path, rootB.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(await controller.addExclusion(rootA.path), isNull);
    expect(await controller.replaceExclusions([rootB.path]), isNull);

    expect(controller.exclusionCount, 1);
    expect(controller.ruleExclusionScopes[rule.id], RuleExclusionScope.partial);
    final reloaded = createStore();
    await reloaded.ensureLoaded();
    expect(reloaded.paths, [PathGuard.normalize(rootB.path)]);
  });

  test(
    'blocks scanning when exclusions fail to load and reset recovers',
    () async {
      final exclusions = createStore();
      await File(exclusions.filePath).parent.create(recursive: true);
      await File(exclusions.filePath).writeAsString('{broken');
      final scanner = _RecordingScanService();
      final rule = createRule();
      final controller = createController(
        exclusions: exclusions,
        scanner: scanner,
        rules: [rule],
        rootsByRule: {
          rule.id: [rootA.path, rootB.path],
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(controller.exclusionError, isNotNull);

      await controller.scan();

      expect(scanner.jobs, isNull);
      expect(controller.phase, CleanPhase.idle);
      expect(controller.error, contains('排除列表'));

      expect(await controller.resetExclusions(), isNull);
      expect(controller.exclusionError, isNull);

      await controller.scan();

      expect(scanner.jobs, hasLength(1));
      expect(controller.phase, CleanPhase.preview);
    },
  );

  test('supports file-level selection and rule tri-state', () async {
    final exclusions = createStore();
    final first = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'first.tmp'),
      size: 10,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final second = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'second.tmp'),
      size: 25,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _RecordingScanService(items: [first, second]);
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();

    expect(controller.selectedCount, 2);
    expect(controller.selectedBytes, 35);
    expect(controller.ruleSelectionValue(rule.id), isTrue);
    expect(controller.isItemSelected(first.path), isTrue);
    expect(controller.allItemsSelected, isTrue);

    controller.toggleItem(first);

    expect(controller.selectedCount, 1);
    expect(controller.selectedBytes, 25);
    expect(controller.ruleSelectionValue(rule.id), isNull);
    expect(controller.isRuleSelected(rule.id), isFalse);
    expect(controller.selectedItems.single.path, second.path);

    controller.toggleRule(rule.id);

    expect(controller.selectedCount, 2);
    expect(controller.ruleSelectionValue(rule.id), isTrue);

    controller.invertSelection();

    expect(controller.selectedCount, 0);
    expect(controller.ruleSelectionValue(rule.id), isFalse);
    expect(controller.selectedItems, isEmpty);

    controller.invertSelection();

    expect(controller.selectedCount, 2);
    expect(controller.allItemsSelected, isTrue);

    controller.clearRuleSelection();

    expect(controller.selectedCount, 0);
    expect(controller.hasSelection, isFalse);

    controller.selectAllRules();

    expect(controller.selectedCount, 2);
    expect(controller.selectedBytesForRule(rule.id), 35);
  });

  test('keeps selection aggregates in sync on every selection path', () async {
    final safeRule = createRule();
    final reviewRule = createRule(id: 'test.review', risk: CleanRisk.review);
    JunkItem item(
      CleanerRule rule,
      String name,
      int size, {
      bool locked = false,
    }) => JunkItem(
      rootIndex: rule.id == safeRule.id ? 0 : 1,
      path: p.windows.join(rootA.path, name),
      size: size,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
      possiblyLocked: locked,
    );
    final safeItems = [
      item(safeRule, 'a.tmp', 10, locked: true),
      item(safeRule, 'b.tmp', 25),
      item(safeRule, 'c.tmp', 40),
    ];
    final reviewItems = [
      item(reviewRule, 'd.tmp', 7),
      item(reviewRule, 'e.tmp', 90),
    ];
    final controller = createController(
      exclusions: createStore(),
      scanner: _RecordingScanService(items: [...safeItems, ...reviewItems]),
      rules: [safeRule, reviewRule],
      rootsByRule: {
        safeRule.id: [rootA.path],
        reviewRule.id: [rootB.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    // Independent oracle: selectedItems is derived from _results and
    // _selectedPaths, so it must agree with the incremental counters.
    void expectAggregates(String step) {
      final selected = controller.selectedItems;
      expect(controller.selectedCount, selected.length, reason: '$step: count');
      expect(
        controller.selectedBytes,
        selected.fold<int>(0, (total, item) => total + item.size),
        reason: '$step: total bytes',
      );
      expect(
        controller.selectedPossiblyLockedCount,
        selected.where((item) => item.possiblyLocked).length,
        reason: '$step: locked count',
      );
      for (final rule in [safeRule, reviewRule]) {
        final ruleSelected = selected.where(
          (item) =>
              (item.rootIndex == 0 ? safeRule.id : reviewRule.id) == rule.id,
        );
        expect(
          controller.selectedCountForRule(rule.id),
          ruleSelected.length,
          reason: '$step: count for ${rule.id}',
        );
        expect(
          controller.selectedBytesForRule(rule.id),
          ruleSelected.fold<int>(0, (total, item) => total + item.size),
          reason: '$step: bytes for ${rule.id}',
        );
      }
    }

    await controller.scan();
    // Safe rules are selected by default; the pre-flagged item counts as
    // possibly locked even before the probe runs.
    expect(controller.selectedBytes, 75);
    expect(controller.selectedPossiblyLockedCount, 1);
    expectAggregates('default selection');

    controller.toggleItem(safeItems.first);
    expect(controller.selectedBytes, 65);
    expect(controller.selectedPossiblyLockedCount, 0);
    expectAggregates('toggle off');

    controller.toggleItem(safeItems.first);
    expect(controller.selectedBytes, 75);
    expect(controller.selectedPossiblyLockedCount, 1);
    expectAggregates('toggle on');

    controller.setRuleSelected(reviewRule.id, true);
    expect(controller.selectedBytes, 172);
    expectAggregates('select review rule');

    controller.invertRuleSelection(safeRule.id);
    expect(controller.selectedBytes, 97);
    expect(controller.selectedPossiblyLockedCount, 0);
    expectAggregates('invert rule');

    controller.invertSelection();
    expect(controller.selectedBytes, 75);
    expect(controller.selectedPossiblyLockedCount, 1);
    expectAggregates('invert all');

    controller.clearRuleSelection();
    expect(controller.selectedBytes, 0);
    expect(controller.selectedBytesForRule(safeRule.id), 0);
    expectAggregates('clear');

    controller.selectAllRules();
    expect(controller.selectedBytes, 172);
    expectAggregates('select all');

    controller.toggleRule(safeRule.id);
    expect(controller.selectedBytes, 97);
    expect(controller.selectedPossiblyLockedCount, 0);
    expectAggregates('toggle rule off');
  });

  test('bumps the items revision for new results and lock updates', () async {
    final rule = createRule();
    final first = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'first.tmp'),
      size: 10,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final second = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'second.tmp'),
      size: 25,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final controller = createController(
      exclusions: createStore(),
      scanner: _RecordingScanService(items: [first, second]),
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
      lockProbe: _FakeLockProbe({first.path}),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final beforeScan = controller.itemsRevision;
    await controller.scan();
    final afterScan = controller.itemsRevision;
    expect(afterScan, greaterThan(beforeScan));

    await pumpEventQueue();
    expect(controller.possiblyLockedCount, 1);
    expect(controller.itemsRevision, greaterThan(afterScan));
    expect(controller.selectedPossiblyLockedCount, 1);
  });

  test('scans review rules but leaves them unselected by default', () async {
    final safeRule = createRule();
    final reviewRule = createRule(id: 'test.review', risk: CleanRisk.review);
    final safeItem = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'safe.tmp'),
      size: 10,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final reviewItem = JunkItem(
      rootIndex: 1,
      path: p.windows.join(rootB.path, 'review.tmp'),
      size: 25,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _RecordingScanService(items: [safeItem, reviewItem]);
    final controller = createController(
      exclusions: createStore(),
      scanner: scanner,
      rules: [safeRule, reviewRule],
      rootsByRule: {
        safeRule.id: [rootA.path],
        reviewRule.id: [rootB.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();

    expect(scanner.jobs, hasLength(2));
    expect(controller.phase, CleanPhase.preview);
    expect(controller.selectedCount, 1);
    expect(controller.isItemSelected(safeItem.path), isTrue);
    expect(controller.isItemSelected(reviewItem.path), isFalse);
    expect(controller.ruleSelectionValue(reviewRule.id), isFalse);
    expect(controller.selectedReviewRuleCount, 0);
    expect(controller.previewReviewRuleCount, 1);

    controller.setRuleSelected(reviewRule.id, true);

    expect(controller.selectedCount, 2);
    expect(controller.selectedReviewRuleCount, 1);
    expect(controller.hasSelectedReview, isTrue);

    controller.clearRuleSelection();
    controller.selectAllRules();

    expect(controller.selectedCount, 2);
    expect(controller.selectedReviewRuleCount, 1);
  });

  test('skips rules disabled in settings', () async {
    final exclusions = createStore();
    final scanner = _RecordingScanService();
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
    );
    controller.isRuleEnabled = (_) => false;
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();

    expect(scanner.jobs, isNull);
    expect(controller.phase, CleanPhase.idle);
    expect(controller.notice, contains('没有找到'));
  });

  test(
    'marks possibly locked preview items without changing selection',
    () async {
      final first = JunkItem(
        rootIndex: 0,
        path: p.windows.join(rootA.path, 'first.tmp'),
        size: 10,
        modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
      );
      final second = JunkItem(
        rootIndex: 0,
        path: p.windows.join(rootA.path, 'second.tmp'),
        size: 25,
        modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
      );
      final scanner = _RecordingScanService(items: [first, second]);
      final probe = _FakeLockProbe({first.path});
      final rule = createRule();
      final controller = createController(
        exclusions: createStore(),
        scanner: scanner,
        rules: [rule],
        rootsByRule: {
          rule.id: [rootA.path],
        },
        lockProbe: probe,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.scan();
      await pumpEventQueue();

      expect(controller.phase, CleanPhase.preview);
      expect(controller.lockProbeRunning, isFalse);
      expect(controller.lockProbeChecked, 2);
      expect(controller.lockProbeTotal, 2);
      expect(controller.possiblyLockedCount, 1);
      expect(controller.possiblyLockedCountForRule(rule.id), 1);
      expect(controller.selectedCount, 2);
      expect(controller.selectedPossiblyLockedCount, 1);
      final items = controller.results.single.items;
      expect(
        items.firstWhere((item) => item.path == first.path).possiblyLocked,
        isTrue,
      );
      expect(
        items.firstWhere((item) => item.path == second.path).possiblyLocked,
        isFalse,
      );
      expect(probe.batches.single.toSet(), {first.path, second.path});
    },
  );

  test('keeps preview usable when lock probing is unavailable', () async {
    final item = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'file.tmp'),
      size: 10,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _RecordingScanService(items: [item]);
    final probe = _FakeLockProbe(
      const {},
      error: const FileLockProbeException('缺少原生通道'),
    );
    final rule = createRule();
    final controller = createController(
      exclusions: createStore(),
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
      lockProbe: probe,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();
    await pumpEventQueue();

    expect(controller.phase, CleanPhase.preview);
    expect(controller.lockProbeRunning, isFalse);
    expect(controller.possiblyLockedCount, 0);
    expect(controller.selectedCount, 1);
  });

  test('builds scan jobs only for enabled categories', () async {
    final exclusions = createStore();
    await exclusions.ensureLoaded();
    final devRule = createRule(id: 'dev.mock');
    final browserRule = createRule(id: 'browser.mock');
    final scanner = _RecordingScanService();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [devRule, browserRule],
      rootsByRule: {
        devRule.id: [rootA.path],
        browserRule.id: [rootB.path],
      },
      scanSettings: () => const ScanSettings(disabledCategoryIds: {'browser'}),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();

    expect(scanner.jobs, hasLength(1));
    expect(scanner.jobs!.single.ruleId, devRule.id);
    expect(controller.activeCategoryIds, isNot(contains('browser')));
  });

  test('persists results and restores them after restart', () async {
    final item = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'saved.tmp'),
      size: 42,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _RecordingScanService(items: [item]);
    final rule = createRule();
    final store = ScanResultStore(
      rootDirectory: p.windows.join(temp.path, 'scan-results'),
    );
    final exclusions = createStore();
    final first = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
      scanResultStore: store,
    );
    await first.initialize();
    await first.scan();

    expect(first.phase, CleanPhase.preview);
    expect(first.results.single.items, hasLength(1));
    expect(await store.loadLatest(), isNotNull);
    first.dispose();

    final second = createController(
      exclusions: exclusions,
      scanner: _RecordingScanService(),
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
      scanResultStore: store,
    );
    addTearDown(second.dispose);
    await second.initialize();

    expect(second.lastScanSummary, isNotNull);
    expect(second.lastScanStale, isFalse);

    await second.restoreLastScan();

    expect(second.error, isNull);
    expect(second.phase, CleanPhase.preview);
    expect(second.results.single.items, hasLength(1));
    expect(second.results.single.items.single.path, item.path);
    expect(second.scanRestoredFromPersistence, isTrue);
    expect(second.selectedCount, 1);
  });

  test('reports active and excluded roots for the rule detail page', () async {
    final exclusions = createStore();
    await exclusions.ensureLoaded();
    await exclusions.add(rootB.path);
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: _RecordingScanService(),
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path, rootB.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final roots = await controller.inspectRuleRoots(rule);

    expect(controller.rulesVersion, 'builtin');
    expect(roots, hasLength(2));
    expect(roots[0].path, rootA.path);
    expect(roots[0].state, RuleRootState.active);
    expect(roots[1].path, rootB.path);
    expect(roots[1].state, RuleRootState.excluded);
  });

  test('keeps scan counters for the preview summary', () async {
    final exclusions = createStore();
    await exclusions.ensureLoaded();
    final item = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'cache.tmp'),
      size: 42,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _RecordingScanService(items: [item]);
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.scan();

    expect(controller.phase, CleanPhase.preview);
    expect(controller.scanScannedFiles, 1);
    expect(controller.scanElapsed, isNotNull);
    expect(controller.scanDirectoryErrors, 0);
    expect(controller.scanTruncated, isFalse);
  });

  test('blocks scan, restore and undo while cleaning is in progress', () async {
    final exclusions = createStore();
    final item = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'busy.tmp'),
      size: 10,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _RecordingScanService(items: [item]);
    final quarantine = _ControlledQuarantineService();
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanner: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
      quarantine: quarantine,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();
    expect(controller.phase, CleanPhase.preview);

    final cleanFuture = controller.cleanSelected();
    await quarantine.started.future;
    expect(controller.phase, CleanPhase.cleaning);
    expect(controller.cleanProgress, isNotNull);

    await controller.scan();
    await controller.restoreLastScan();
    await expectLater(
      controller.undo(FakeQuarantineService.sessionId),
      throwsA(isA<StateError>()),
    );
    await controller.cleanSelected();
    expect(controller.phase, CleanPhase.cleaning);
    expect(quarantine.cleanCalls, 1);
    expect(controller.lastReport, isNull);

    quarantine.release.complete();
    await cleanFuture;

    expect(controller.phase, CleanPhase.done);
    expect(controller.lastReport?.movedCount, 1);
    expect(quarantine.cleanRequest.single.path, item.path);
  });

  test('ignores clean and undo while a scan is in progress', () async {
    final exclusions = createStore();
    final item = JunkItem(
      rootIndex: 0,
      path: p.windows.join(rootA.path, 'scanning.tmp'),
      size: 10,
      modifiedMicros: DateTime(2026, 10, 18).microsecondsSinceEpoch,
    );
    final scanner = _ControlledScanService([item]);
    final quarantine = FakeQuarantineService();
    final rule = createRule();
    final controller = createController(
      exclusions: exclusions,
      scanService: scanner,
      rules: [rule],
      rootsByRule: {
        rule.id: [rootA.path],
      },
      quarantine: quarantine,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final scanFuture = controller.scan();
    await scanner.started.future;
    expect(controller.phase, CleanPhase.scanning);

    await controller.cleanSelected();
    expect(quarantine.cleanRequest, isEmpty);
    await expectLater(
      controller.undo(FakeQuarantineService.sessionId),
      throwsA(isA<StateError>()),
    );
    await controller.scan();
    expect(scanner.calls, 1);
    expect(controller.phase, CleanPhase.scanning);

    scanner.release.complete();
    await scanFuture;

    expect(controller.phase, CleanPhase.preview);
    expect(controller.selectedCount, 1);
    expect(controller.results.single.items.single.path, item.path);
  });
}
