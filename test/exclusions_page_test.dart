import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:broom/ui/exclusions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/quarantine_fakes.dart';

class _PagePlatform implements CleanerPlatform {
  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => const [];

  @override
  String get rulesVersion => 'builtin';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

class _PickerShell implements SystemShell {
  _PickerShell(this.path);

  String? path;

  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => path;

  @override
  Future<String?> pickJsonFile({
    String? initialDirectory,
    String? title,
  }) async => null;

  @override
  Future<String?> saveJsonFile({
    required String suggestedName,
    String? initialDirectory,
    String? title,
  }) async => null;

  @override
  Future<DiskSpaceSnapshot> queryDiskSpace(String path) async =>
      const DiskSpaceSnapshot(freeBytes: 0, totalBytes: 0);

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 0, totalBytes: 0);

  @override
  Future<void> revealPath(String path) async {}
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_exclusions_page_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ExclusionStore createStore() => ExclusionStore(
    filePath: p.windows.join(temp.path, 'settings', 'exclusions.json'),
  );

  CleanController createController(ExclusionStore exclusions) {
    return CleanController(
      platform: _PagePlatform(),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: exclusions,
    );
  }

  testWidgets('adds and removes an exclusion through the folder picker', (
    tester,
  ) async {
    final keep = Directory(p.windows.join(temp.path, 'keep'));
    keep.createSync(recursive: true);
    final controller = createController(createStore());
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: ExclusionsPage(
          controller: controller,
          shell: _PickerShell(keep.path),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('尚未添加排除项'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-exclusion')));
    await tester.pumpAndSettle();

    expect(controller.exclusions.paths, [PathGuard.normalize(keep.path)]);
    expect(find.text(keep.path), findsOneWidget);
    expect(find.textContaining('1 个目录不参与扫描'), findsOneWidget);

    await tester.tap(find.byTooltip('移除排除项'));
    await tester.pumpAndSettle();

    expect(controller.exclusions.paths, isEmpty);
    expect(find.text('尚未添加排除项'), findsOneWidget);
  });

  testWidgets('shows a load error and resets the configuration', (
    tester,
  ) async {
    final exclusions = createStore();
    File(exclusions.filePath).parent.createSync(recursive: true);
    File(exclusions.filePath).writeAsStringSync('{broken');
    final controller = createController(exclusions);
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: ExclusionsPage(controller: controller, shell: _PickerShell(null)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('排除列表数据无效'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('add-exclusion')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('reset-exclusions')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('重置')),
    );
    await tester.pumpAndSettle();

    expect(controller.exclusionError, isNull);
    expect(find.text('尚未添加排除项'), findsOneWidget);
  });
}
