import 'package:broom/app.dart';
import 'package:broom/core/clean/clean_history_store.dart';
import 'package:broom/core/models/clean_history_models.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/ui/clean_history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHistoryStore extends CleanHistoryStore {
  _FakeHistoryStore({this.records = const [], this.error})
    : super(
        filePath: r'C:\Broom\clean_history.json',
        semantics: const WindowsPathSemantics(),
      );

  final List<CleanHistoryRecord> records;
  final Object? error;

  @override
  Future<List<CleanHistoryRecord>> load() async {
    if (error != null) throw error!;
    return records;
  }
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester,
    CleanHistoryStore store, {
    Map<String, String> ruleTitles = const {},
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildBroomTheme(Brightness.light),
        home: CleanHistoryPage(store: store, ruleTitles: ruleTitles),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows an empty state', (tester) async {
    await pumpPage(tester, _FakeHistoryStore());

    expect(find.text('清理历史'), findsOneWidget);
    expect(find.text('还没有清理历史'), findsOneWidget);
    expect(find.textContaining('不会删除历史'), findsOneWidget);
  });

  testWidgets('shows result, counts and resolved rule titles', (tester) async {
    final record = CleanHistoryRecord(
      sessionId: 'session-1',
      startedAt: DateTime.utc(2026, 10, 18, 10),
      completedAt: DateTime.utc(2026, 10, 18, 10, 2),
      outcome: CleanHistoryOutcome.partial,
      plannedCount: 6,
      plannedBytes: 6 * 1024,
      movedCount: 3,
      movedBytes: 3 * 1024,
      skippedCount: 1,
      failureCount: 1,
      remainingCount: 2,
      rules: const [
        CleanHistoryRule(ruleId: 'browser.cache', fileCount: 4, bytes: 4096),
        CleanHistoryRule(ruleId: 'temp.files', fileCount: 2, bytes: 2048),
      ],
    );

    await pumpPage(
      tester,
      _FakeHistoryStore(records: [record]),
      ruleTitles: const {'browser.cache': '浏览器缓存'},
    );

    expect(find.text('部分完成'), findsOneWidget);
    expect(find.textContaining('计划 6 个文件'), findsOneWidget);
    expect(find.textContaining('暂存 3 个文件'), findsOneWidget);
    expect(find.text('跳过 1 个'), findsOneWidget);
    expect(find.text('失败 1 个'), findsOneWidget);
    expect(find.text('未处理 2 个'), findsOneWidget);
    expect(find.textContaining('浏览器缓存 · 4'), findsOneWidget);
    expect(find.textContaining('规则 temp.files · 2'), findsOneWidget);
  });

  testWidgets('surfaces a load error', (tester) async {
    await pumpPage(
      tester,
      _FakeHistoryStore(error: const CleanHistoryException('历史文件损坏')),
    );

    expect(find.textContaining('无法读取清理历史'), findsOneWidget);
    expect(find.text('还没有清理历史'), findsOneWidget);
  });
}
