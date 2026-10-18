import 'dart:ui';

import 'package:broom/app.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeSystemShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 7, totalBytes: 7340032);

  @override
  Future<void> revealPath(String path) async {}
}

class _FakePlatform implements CleanerPlatform {
  @override
  String get displayName => 'Test';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => windowsSafeRules;

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

void main() {
  testWidgets('renders the idle screen and handles an empty scan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guard = PathGuard(protectedRoots: const []);
    final controller = CleanController(
      platform: _FakePlatform(),
      guard: guard,
      quarantine: QuarantineService(
        quarantineRoot: p.windows.join(r'C:\broom_widget_test', 'quarantine'),
        guard: guard,
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(BroomApp(controller: controller));

    expect(find.text('Broom'), findsOneWidget);
    expect(find.text('Windows 安全清理'), findsOneWidget);
    expect(find.byKey(const ValueKey('window-minimize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-maximize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-close')), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
    expect(find.text('本次扫描范围'), findsOneWidget);
    expect(find.text('分析与审阅'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-recycle-bin')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-duplicate-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-large-files')), findsOneWidget);
    expect(find.text('REVIEW · 需确认'), findsOneWidget);
    expect(find.text('INFO · 只读'), findsNWidgets(2));

    await tester.tap(find.text('开始扫描'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('没有找到可扫描的缓存目录。'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('opens the recycle bin review tool', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final guard = PathGuard(protectedRoots: const []);
    final controller = CleanController(
      platform: _FakePlatform(),
      guard: guard,
      quarantine: QuarantineService(
        quarantineRoot: p.windows.join(r'C:\broom_widget_test', 'quarantine'),
        guard: guard,
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: _FakeSystemShell()),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('tool-recycle-bin')));
    await tester.tap(find.byKey(const ValueKey('tool-recycle-bin')));
    await tester.pumpAndSettle();

    expect(find.text('回收站中有 7 个项目'), findsOneWidget);
    expect(find.text('REVIEW · 需确认'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
