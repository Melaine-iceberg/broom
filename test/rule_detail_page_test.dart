import 'dart:io';

import 'package:broom/app.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/rule_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/quarantine_fakes.dart';

class _Platform implements CleanerPlatform {
  _Platform({required CleanerRule rule, required this.roots}) : rules = [rule];

  @override
  final List<CleanerRule> rules;
  final List<String> roots;

  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => roots;
}

class _FakeScanService extends ScanService {
  _FakeScanService(this.items);

  final List<JunkItem> items;

  @override
  Future<ScanResult> scan({
    required List<ScanJob> jobs,
    required List<String> excludedPaths,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    return ScanResult(
      items: items,
      scannedFiles: items.length,
      directoryErrors: 0,
      truncated: false,
      cancelled: false,
    );
  }
}

void main() {
  testWidgets('selects individual files and keeps rule state in sync', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('broom_rule_detail_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final root = Directory(p.windows.join(temp.path, 'cache'))
      ..createSync(recursive: true);
    final first = JunkItem(
      ruleId: 'test.cache',
      rootPath: root.path,
      path: p.windows.join(root.path, 'first.tmp'),
      size: 10,
      modified: DateTime(2026, 10, 18),
    );
    final second = JunkItem(
      ruleId: 'test.cache',
      rootPath: root.path,
      path: p.windows.join(root.path, 'second.tmp'),
      size: 25,
      modified: DateTime(2026, 10, 18),
    );
    const rule = CleanerRule(
      id: 'test.cache',
      title: '测试缓存',
      category: '测试',
      description: '测试规则',
      pathPatterns: [],
    );
    final exclusions = ExclusionStore(
      filePath: p.windows.join(temp.path, 'exclusions.json'),
    );
    await exclusions.ensureLoaded();
    final controller = CleanController(
      platform: _Platform(rule: rule, roots: [root.path]),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: exclusions,
      scanServiceFactory: () => _FakeScanService([first, second]),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildBroomTheme(Brightness.light),
        home: RuleDetailPage(
          controller: controller,
          result: controller.results.single,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.selectedCount, 2);
    expect(find.textContaining('已选 2 / 2 个文件'), findsOneWidget);

    final firstRow = find.byKey(ValueKey('rule-file-${first.path}'));
    await tester.tap(
      find.descendant(of: firstRow, matching: find.byType(Checkbox)),
    );
    await tester.pump();

    expect(controller.isItemSelected(first.path), isFalse);
    expect(controller.selectedCount, 1);
    expect(find.textContaining('已选 1 / 2 个文件'), findsOneWidget);
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('rule-select-all')))
          .value,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('rule-select-all')));
    await tester.pump();

    expect(controller.selectedCount, 2);
    expect(controller.isRuleSelected(rule.id), isTrue);

    await tester.tap(find.text('取消全选'));
    await tester.pump();

    expect(controller.selectedCount, 0);
    expect(find.textContaining('已选 0 / 2 个文件'), findsOneWidget);

    await tester.tap(find.text('反选'));
    await tester.pump();

    expect(controller.selectedCount, 2);
  });
}
