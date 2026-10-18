import 'dart:ui';

import 'package:broom/app.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
  testWidgets('renders the idle screen and handles an empty scan', (tester) async {
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
    expect(find.text('开始扫描'), findsOneWidget);
    expect(find.text('本次扫描范围'), findsOneWidget);

    await tester.tap(find.text('开始扫描'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('没有找到可扫描的缓存目录。'), findsOneWidget);
  });
}
