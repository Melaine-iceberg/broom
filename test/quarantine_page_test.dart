import 'package:broom/app.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/quarantine_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/quarantine_fakes.dart';

class _FakeSystemShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

  @override
  Future<DiskSpaceSnapshot> queryDiskSpace(String path) async =>
      const DiskSpaceSnapshot(
        freeBytes: 5 * 1024 * 1024,
        totalBytes: 10 * 1024 * 1024,
      );

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 0, totalBytes: 0);

  @override
  Future<void> revealPath(String path) async {}
}

void main() {
  Future<void> pumpPage(WidgetTester tester, QuarantineService service) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildBroomTheme(Brightness.light),
        home: QuarantinePage(service: service, shell: _FakeSystemShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('restores selected files from a quarantine session', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('first.txt'),
      fakeQuarantineEntry('second.txt', sequence: 2),
    ]);

    await pumpPage(tester, service);

    expect(find.textContaining('隔离区暂存了'), findsOneWidget);
    expect(find.textContaining('磁盘可用'), findsOneWidget);
    expect(find.text('查看文件'), findsOneWidget);

    await tester.tap(find.text('查看文件'));
    await tester.pumpAndSettle();

    expect(find.text('隔离区文件'), findsOneWidget);
    expect(find.text('first.txt'), findsOneWidget);
    expect(find.text('second.txt'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.text('恢复选中'));
    await tester.pumpAndSettle();

    expect(find.text('已恢复 1 个文件'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(service.restoreRequests.single, {'000001_first.txt'});
    expect(find.text('已恢复'), findsOneWidget);
    expect(find.text('可恢复'), findsOneWidget);

    await tester.tap(find.byTooltip('返回').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('恢复全部'));
    await tester.pumpAndSettle();

    expect(find.text('隔离区是空的'), findsOneWidget);
    expect(service.restoreRequests, [
      {'000001_first.txt'},
      null,
    ]);
    expect(service.isEmpty, isTrue);
  });

  testWidgets('requires acknowledgment before permanent release', (
    tester,
  ) async {
    final service = FakeQuarantineService([fakeQuarantineEntry('only.txt')]);

    await pumpPage(tester, service);

    await tester.tap(find.text('永久释放'));
    await tester.pumpAndSettle();

    expect(find.text('永久释放这次清理？'), findsOneWidget);
    final confirm = find.byKey(const ValueKey('purge-confirm-button'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('purge-confirm-checkbox')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(find.text('隔离区是空的'), findsOneWidget);
    expect(service.isEmpty, isTrue);
  });

  testWidgets('shows an empty state and free space', (tester) async {
    final service = FakeQuarantineService();

    await pumpPage(tester, service);

    expect(find.text('隔离区是空的'), findsOneWidget);
    expect(find.text('没有待处理的清理'), findsOneWidget);
    expect(find.textContaining('磁盘可用'), findsOneWidget);
    expect(find.text('全部永久释放'), findsNothing);
  });
}
