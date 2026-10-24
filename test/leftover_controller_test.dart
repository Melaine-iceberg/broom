import 'dart:io';

import 'package:broom/core/leftover/leftover_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/installed_apps.dart';
import 'package:broom/core/platform/path_semantics.dart';
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
  PathSemantics get pathSemantics => const WindowsPathSemantics();

  @override
  List<String> get protectedRoots => const [];

  @override
  String get rulesVersion => 'builtin';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async =>
      rootsByRule[rule.id] ?? const [];
}

class _EmptyInstalledApps implements InstalledApps {
  const _EmptyInstalledApps();

  @override
  Future<InstalledAppInventory> list() async =>
      const InstalledAppInventory(apps: [], complete: true);
}

class _FakeLeftoverService extends LeftoverService {
  _FakeLeftoverService({required this.detection})
    : super(
        installedApps: const _EmptyInstalledApps(),
        guard: PathGuard(protectedRoots: const []),
        entries: const [],
        environment: const {},
      );

  LeftoverDetection detection;
  LeftoverValidation validation = const LeftoverValidation();
  int detectCalls = 0;
  int revalidateCalls = 0;
  Set<String>? revalidatedRuleIds;

  @override
  Future<LeftoverDetection> detect() async {
    detectCalls++;
    return detection;
  }

  @override
  Future<LeftoverValidation> revalidate(Iterable<String> ruleIds) async {
    revalidateCalls++;
    revalidatedRuleIds = ruleIds.toSet();
    return validation;
  }
}

class _RecordingScanService extends ScanService {
  _RecordingScanService(this.items);

  final List<JunkItem> items;
  List<ScanJob>? jobs;

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

class _RecordingQuarantineService extends FakeQuarantineService {
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

void main() {
  late Directory temp;
  late Directory cacheDir;
  late Directory leftoverDir;
  late ExclusionStore exclusions;
  late CleanerRule baseRule;
  late LeftoverCatalogEntry leftoverEntry;
  late LeftoverCandidate candidate;
  late JunkItem baseItem;
  late JunkItem leftoverItem;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_leftover_controller_');
    cacheDir = await Directory(p.join(temp.path, 'cache'))
        .create(recursive: true);
    leftoverDir = await Directory(p.join(temp.path, 'leftover'))
        .create(recursive: true);
    await File(p.join(cacheDir.path, 'a.tmp')).writeAsString('1234');
    await File(p.join(leftoverDir.path, 'b.dat')).writeAsString('5678');
    exclusions = ExclusionStore(filePath: p.join(temp.path, 'exclusions.json'));
    baseRule = const CleanerRule(
      id: 'test.cache',
      title: '测试缓存',
      category: '测试',
      description: '测试规则',
      risk: CleanRisk.safe,
      pathPatterns: [],
    );
    leftoverEntry = const LeftoverCatalogEntry(
      id: 'example',
      appName: 'Example',
      appNameEn: 'Example',
      description: 'Example local data.',
      descriptionEn: 'Example local data.',
      dataPathPatterns: [r'%APPDATA%\Example'],
      installMarkerPatterns: [r'%LOCALAPPDATA%\Example\app.exe'],
      installDisplayNamePrefixes: ['Example'],
    );
    candidate = LeftoverCandidate(
      entry: leftoverEntry,
      paths: [leftoverDir.path],
      evidence: 'evidence',
      evidenceEn: 'evidence',
    );
    final modified = DateTime(2026, 10, 21).microsecondsSinceEpoch;
    baseItem = JunkItem(
      rootIndex: 0,
      path: p.join(cacheDir.path, 'a.tmp'),
      size: 4,
      modifiedMicros: modified,
    );
    leftoverItem = JunkItem(
      rootIndex: 1,
      path: p.join(leftoverDir.path, 'b.dat'),
      size: 4,
      modifiedMicros: modified,
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ({
    CleanController controller,
    _RecordingQuarantineService quarantine,
    _RecordingScanService scanner,
    _FakeLeftoverService leftover,
  })
  createController({ScanResultStore? store}) {
    final leftover = _FakeLeftoverService(
      detection: LeftoverDetection(candidates: [candidate]),
    );
    final scanner = _RecordingScanService([baseItem, leftoverItem]);
    final quarantine = _RecordingQuarantineService();
    final controller = CleanController(
      platform: _TestPlatform(
        definedRules: [baseRule],
        rootsByRule: {
          baseRule.id: [cacheDir.path],
          leftoverEntry.ruleId: [leftoverDir.path],
        },
      ),
      guard: PathGuard(protectedRoots: const []),
      quarantine: quarantine,
      exclusions: exclusions,
      leftoverService: leftover,
      scanServiceFactory: () => scanner,
      scanResultStore: store,
    );
    addTearDown(controller.dispose);
    return (
      controller: controller,
      quarantine: quarantine,
      scanner: scanner,
      leftover: leftover,
    );
  }

  test('scans leftover rules but keeps them out of persistence', () async {
    final store = ScanResultStore(
      rootDirectory: p.join(temp.path, 'scan-results'),
    );
    final first = createController(store: store);

    await first.controller.initialize();

    expect(first.leftover.detectCalls, 1);
    expect(
      first.controller.rules.map((rule) => rule.id),
      containsAll([baseRule.id, leftoverEntry.ruleId]),
    );

    await first.controller.scan();

    expect(first.leftover.detectCalls, 2);
    expect(first.scanner.jobs, hasLength(2));
    expect(first.scanner.jobs!.map((job) => job.ruleId), [
      baseRule.id,
      leftoverEntry.ruleId,
    ]);
    expect(first.controller.results.map((result) => result.rule.id), [
      baseRule.id,
      leftoverEntry.ruleId,
    ]);
    expect(first.controller.selectedCount, 1);
    expect(first.controller.selectedBytes, baseItem.size);

    final summary = await store.loadLatest();
    expect(summary, isNotNull);
    expect(summary!.ruleIds, [baseRule.id]);
    expect(summary.persistedItemCount, 1);

    final second = createController(store: store);
    await second.controller.initialize();
    await second.controller.restoreLastScan();

    expect(second.controller.results.map((result) => result.rule.id), [
      baseRule.id,
    ]);
    expect(second.controller.results.single.items.single.path, baseItem.path);
    expect(second.controller.selectedCount, 1);
  });

  test('cleans leftovers that are still orphaned', () async {
    final setup = createController();
    await setup.controller.initialize();
    await setup.controller.scan();

    setup.controller.setRuleSelected(baseRule.id, false);
    setup.controller.setRuleSelected(leftoverEntry.ruleId, true);
    setup.leftover.validation = const LeftoverValidation(
      orphanedRuleIds: {'leftover.example'},
    );

    await setup.controller.cleanSelected();

    expect(setup.leftover.revalidateCalls, 1);
    expect(setup.leftover.revalidatedRuleIds, {leftoverEntry.ruleId});
    expect(setup.quarantine.cleanCalls, 1);
    expect(setup.quarantine.cleanRequest.single.path, leftoverItem.path);
    expect(setup.controller.phase, CleanPhase.done);
  });

  test(
    'drops leftover results when the application is installed again',
    () async {
      final setup = createController();
      await setup.controller.initialize();
      await setup.controller.scan();

      setup.controller.setRuleSelected(baseRule.id, false);
      setup.controller.setRuleSelected(leftoverEntry.ruleId, true);
      setup.leftover.validation = const LeftoverValidation();

      await setup.controller.cleanSelected();

      expect(setup.leftover.revalidateCalls, 1);
      expect(setup.quarantine.cleanCalls, 0);
      expect(setup.controller.phase, CleanPhase.preview);
      expect(setup.controller.error, contains('重新安装'));
      expect(
        setup.controller.results.map((result) => result.rule.id),
        isNot(contains(leftoverEntry.ruleId)),
      );
      expect(setup.controller.selectedCount, 0);
    },
  );

  test('cleans other items while skipping reinstalled leftovers', () async {
    final setup = createController();
    await setup.controller.initialize();
    await setup.controller.scan();

    setup.controller.setRuleSelected(leftoverEntry.ruleId, true);
    setup.leftover.validation = const LeftoverValidation();

    await setup.controller.cleanSelected();

    expect(setup.quarantine.cleanCalls, 1);
    expect(setup.quarantine.cleanRequest.map((item) => item.path), [
      baseItem.path,
    ]);
    expect(setup.controller.phase, CleanPhase.done);
    expect(setup.controller.results.map((result) => result.rule.id), [
      baseRule.id,
    ]);
    expect(setup.controller.error, contains('跳过'));
  });

  test('cancels cleaning when the install state cannot be verified', () async {
    final setup = createController();
    await setup.controller.initialize();
    await setup.controller.scan();

    setup.controller.setRuleSelected(baseRule.id, false);
    setup.controller.setRuleSelected(leftoverEntry.ruleId, true);
    setup.leftover.validation = const LeftoverValidation(
      error: 'inventory failed',
    );

    await setup.controller.cleanSelected();

    expect(setup.quarantine.cleanCalls, 0);
    expect(setup.controller.phase, CleanPhase.preview);
    expect(setup.controller.error, contains('无法确认'));
    expect(setup.controller.results, isNotEmpty);
  });
}
