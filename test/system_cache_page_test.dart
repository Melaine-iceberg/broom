import 'package:broom/app.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/models/system_models.dart';
import 'package:broom/ui/system_cache_controller.dart';
import 'package:broom/ui/system_cache_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/system_cache_fakes.dart';

const _updateRoot = r'C:\Windows\SoftwareDistribution\Download';

Future<void> _pumpPage(
  WidgetTester tester,
  SystemCacheController controller,
) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildBroomTheme(Brightness.light),
      home: SystemCachePage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

JunkItem _item() {
  return JunkItem(
    ruleId: 'windows.update_cache',
    rootPath: _updateRoot,
    path: p.windows.join(_updateRoot, 'update.cab'),
    size: 2048,
    modified: DateTime(2026, 1, 1),
  );
}

SystemCacheController _controller({
  required FakeSystemAccess access,
  FakeSystemCacheCleaner? cleaner,
  FakeScanService? scanner,
}) {
  final controller = SystemCacheController(
    platform: FakeSystemCachePlatform(resolver: (_) => [_updateRoot]),
    access: access,
    cleaner: cleaner ?? FakeSystemCacheCleaner(),
    scanServiceFactory: () => scanner ?? FakeScanService(),
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  testWidgets('gates the tool behind administrator elevation', (tester) async {
    final access = FakeSystemAccess(elevated: false);
    final controller = _controller(access: access);
    await _pumpPage(tester, controller);

    expect(find.text('需要管理员权限'), findsOneWidget);
    expect(find.text('以管理员身份重新启动'), findsOneWidget);
    expect(find.text('Windows 更新缓存'), findsOneWidget);
    expect(find.text('扫描系统缓存'), findsNothing);
    expect(find.text('REVIEW · 需确认'), findsOneWidget);

    await tester.tap(find.text('以管理员身份重新启动'));
    await tester.pumpAndSettle();

    expect(access.relaunchCalls, 1);
    expect(find.text('已取消管理员授权，未做任何更改。'), findsOneWidget);

    access.elevated = true;
    await tester.tap(find.text('重新检测'));
    await tester.pumpAndSettle();

    expect(find.text('扫描系统缓存'), findsOneWidget);
    expect(find.text('需要管理员权限'), findsNothing);
  });

  testWidgets('scans, requires explicit selection and confirmation, then '
      'cleans', (tester) async {
    final access = FakeSystemAccess();
    final scanner = FakeScanService(
      result: ScanResult(
        items: [_item()],
        scannedFiles: 1,
        directoryErrors: 0,
        truncated: false,
        cancelled: false,
      ),
    );
    final cleaner = FakeSystemCacheCleaner(
      report: const SystemCleanReport(
        deletedCount: 1,
        deletedBytes: 2048,
        failureCount: 0,
        failures: [],
        cancelled: false,
        serviceIssues: [],
      ),
    );
    final controller = _controller(
      access: access,
      cleaner: cleaner,
      scanner: scanner,
    );
    await _pumpPage(tester, controller);

    await tester.tap(find.text('扫描系统缓存'));
    await tester.pumpAndSettle();

    expect(controller.phase, SystemCachePhase.preview);
    expect(find.textContaining('发现 1 个文件'), findsOneWidget);
    final emptySelection = find.widgetWithText(FilledButton, '永久删除 0 项');
    expect(tester.widget<FilledButton>(emptySelection).onPressed, isNull);

    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    expect(controller.selectedCount, 1);
    final deleteButton = find.widgetWithText(FilledButton, '永久删除 1 项');
    expect(tester.widget<FilledButton>(deleteButton).onPressed, isNotNull);

    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    expect(find.text('永久删除系统缓存？'), findsOneWidget);
    expect(find.textContaining('不会进入 Broom 隔离区'), findsWidgets);
    expect(find.textContaining('Windows Update'), findsWidgets);
    final confirmButton = find.widgetWithText(FilledButton, '永久删除');
    expect(tester.widget<FilledButton>(confirmButton).onPressed, isNull);

    await tester.tap(find.text('我明白系统缓存将被永久删除，且无法撤销'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirmButton).onPressed, isNotNull);

    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    expect(cleaner.calls, 1);
    expect(cleaner.serviceNames, ['wuauserv', 'bits']);
    expect(controller.phase, SystemCachePhase.done);
    expect(find.text('清理完成'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsWidgets);
  });
}
