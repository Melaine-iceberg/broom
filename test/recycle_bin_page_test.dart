import 'package:broom/app.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/recycle_bin_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSystemShell implements SystemShell {
  _FakeSystemShell({
    this.snapshot = const RecycleBinSnapshot(itemCount: 3, totalBytes: 1572864),
  });

  RecycleBinSnapshot snapshot;
  int emptyCalls = 0;
  Object? queryError;

  @override
  Future<void> emptyRecycleBin() async {
    emptyCalls++;
    snapshot = const RecycleBinSnapshot(itemCount: 0, totalBytes: 0);
  }

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async {
    if (queryError case final error?) throw error;
    return snapshot;
  }

  @override
  Future<void> revealPath(String path) async {}
}

Future<void> _pumpPage(WidgetTester tester, SystemShell shell) async {
  tester.view.physicalSize = const Size(1000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildBroomTheme(Brightness.light),
      home: RecycleBinPage(shell: shell),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows recycle bin stats and requires acknowledgment to empty', (
    tester,
  ) async {
    final shell = _FakeSystemShell();
    await _pumpPage(tester, shell);

    expect(find.text('REVIEW · 需确认'), findsOneWidget);
    expect(find.text('回收站中有 3 个项目'), findsOneWidget);
    expect(find.textContaining('1.5 MB'), findsWidgets);

    await tester.tap(find.text('清空回收站'));
    await tester.pumpAndSettle();

    expect(find.text('永久清空回收站？'), findsOneWidget);
    expect(find.textContaining('无法撤销'), findsWidgets);

    final confirm = find.widgetWithText(FilledButton, '永久清空');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.text('我明白清空后无法恢复'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(shell.emptyCalls, 1);
    expect(find.text('回收站已清空。'), findsOneWidget);
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('cancelling the dialog leaves the recycle bin untouched', (
    tester,
  ) async {
    final shell = _FakeSystemShell();
    await _pumpPage(tester, shell);

    await tester.tap(find.text('清空回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(shell.emptyCalls, 0);
    expect(find.text('回收站中有 3 个项目'), findsOneWidget);
  });

  testWidgets('disables emptying when the recycle bin is empty', (
    tester,
  ) async {
    final shell = _FakeSystemShell(
      snapshot: const RecycleBinSnapshot(itemCount: 0, totalBytes: 0),
    );
    await _pumpPage(tester, shell);

    expect(find.text('回收站是空的'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, '清空回收站');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });

  testWidgets('shows the shell error without enabling emptying', (
    tester,
  ) async {
    final shell = _FakeSystemShell()
      ..queryError = const SystemShellException('无法访问回收站。');
    await _pumpPage(tester, shell);

    expect(find.text('无法访问回收站。'), findsOneWidget);
    expect(find.text('无法读取回收站'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, '清空回收站');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });
}
