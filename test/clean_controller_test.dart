import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/safety/path_guard.dart';
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
    void Function(ScanProgress progress)? onProgress,
  }) async {
    this.jobs = jobs;
    this.excludedPaths = excludedPaths;
    return ScanResult(
      items: items,
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

  CleanerRule createRule() => const CleanerRule(
    id: 'test.rule',
    title: '测试缓存',
    category: '测试',
    description: '测试规则',
    pathPatterns: [],
  );

  CleanController createController({
    required ExclusionStore exclusions,
    required _RecordingScanService scanner,
    required List<CleanerRule> rules,
    required Map<String, List<String>> rootsByRule,
  }) {
    return CleanController(
      platform: _TestPlatform(definedRules: rules, rootsByRule: rootsByRule),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: exclusions,
      scanServiceFactory: () => scanner,
    );
  }

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
      ruleId: 'test.rule',
      rootPath: rootA.path,
      path: p.windows.join(rootA.path, 'first.tmp'),
      size: 10,
      modified: DateTime(2026, 10, 18),
    );
    final second = JunkItem(
      ruleId: 'test.rule',
      rootPath: rootA.path,
      path: p.windows.join(rootA.path, 'second.tmp'),
      size: 25,
      modified: DateTime(2026, 10, 18),
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

    controller.toggleItem(first.path);

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
}
