import 'package:broom/app.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../test/support/quarantine_fakes.dart';
import 'support/integration_fakes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens settings and previews a scanned cache', (tester) async {
    final controller = CleanController(
      platform: IntegrationPlatform(),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: ExclusionStore(
        filePath: p.join(r'C:\Integration', 'exclusions.json'),
      ),
      scanServiceFactory: IntegrationScanService.new,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: IntegrationShell()),
    );
    await tester.pumpAndSettle();

    expect(find.text('开始扫描'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('open-settings')));
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('开始扫描'), findsOneWidget);

    await tester.tap(find.text('开始扫描'));
    await tester.pumpAndSettle();

    expect(find.text('集成测试缓存'), findsOneWidget);
    expect(find.text('已选择 1 项'), findsOneWidget);
  });
}
