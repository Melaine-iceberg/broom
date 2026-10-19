import 'dart:io';

import 'package:broom/app.dart';
import 'package:broom/core/clean/clean_history_store.dart';
import 'package:broom/core/clean/quarantine_retention_service.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_history_models.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/quarantine_policy_models.dart';
import 'package:broom/core/settings/quarantine_policy_store.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/quarantine_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/quarantine_fakes.dart';

class _MemoryHistoryStore extends CleanHistoryStore {
  _MemoryHistoryStore(this.records)
    : super(filePath: r'C:\Broom\clean_history.json');

  final List<CleanHistoryRecord> records;

  @override
  Future<List<CleanHistoryRecord>> load() async => records;
}

class _FakeSystemShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

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
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_retention_page_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  QuarantinePolicyStore createPolicyStore() => QuarantinePolicyStore(
    filePath: p.windows.join(temp.path, 'quarantine_policy.json'),
  );

  QuarantineRetentionService createRetention(
    QuarantineService service, {
    DateTime? clock,
  }) => QuarantineRetentionService(
    quarantine: service,
    store: createPolicyStore(),
    clock: () => clock ?? DateTime(2026, 10, 18, 12),
  );

  Future<void> pumpPage(
    WidgetTester tester,
    QuarantineService service, {
    QuarantineRetentionService? retention,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildBroomTheme(Brightness.light),
        home: QuarantinePage(
          service: service,
          shell: _FakeSystemShell(),
          retention: retention,
        ),
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
    final firstRequest = service.restoreRequests.single;
    expect(firstRequest.storedNames, {'000001_first.txt'});
    expect(firstRequest.policy, UndoConflictPolicy.skip);
    expect(find.text('已恢复'), findsOneWidget);
    expect(find.text('可恢复'), findsOneWidget);

    await tester.tap(find.byTooltip('返回').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('恢复全部'));
    await tester.pumpAndSettle();

    expect(find.text('隔离区是空的'), findsOneWidget);
    expect(
      service.restoreRequests.map((request) => request.storedNames).toList(),
      [
        {'000001_first.txt'},
        null,
      ],
    );
    expect(service.isEmpty, isTrue);
  });

  testWidgets('resumes an interrupted cleanup from the session list', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('moved.txt'),
    ], 2);

    await pumpPage(tester, service);

    expect(find.text('待继续清理'), findsOneWidget);
    expect(find.textContaining('还有 2 个未处理'), findsOneWidget);
    expect(find.textContaining('可继续清理'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('resume-clean-button')));
    await tester.pumpAndSettle();

    expect(find.text('继续清理剩余文件？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '继续清理'));
    await tester.pumpAndSettle();

    expect(service.resumeRequests, [FakeQuarantineService.sessionId]);
    expect(find.text('待继续清理'), findsNothing);
    expect(find.text('可恢复'), findsOneWidget);
  });

  testWidgets('resumes an interrupted cleanup from the session details', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('moved.txt'),
    ], 1);

    await pumpPage(tester, service);
    await tester.tap(find.text('查看文件'));
    await tester.pumpAndSettle();

    expect(find.textContaining('还有 1 个文件未处理'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('resume-clean-detail-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '继续清理'),
      ),
    );
    await tester.pumpAndSettle();

    expect(service.resumeRequests, [FakeQuarantineService.sessionId]);
    expect(
      find.byKey(const ValueKey('resume-clean-detail-button')),
      findsNothing,
    );
  });

  testWidgets('reports metadata restoration warnings', (tester) async {
    final service = FakeQuarantineService([fakeQuarantineEntry('meta.txt')]);
    service.undoMetadataFailures = 1;

    await pumpPage(tester, service);
    await tester.tap(find.text('查看文件'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('恢复全部'));
    await tester.pumpAndSettle();

    expect(find.textContaining('时间戳、只读属性或 ACL 未能完全还原'), findsOneWidget);
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

  testWidgets('offers conflict handling and keeps both copies', (tester) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('conflict.txt', originalExists: true),
    ]);

    await pumpPage(tester, service);
    await tester.tap(find.text('查看文件'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('conflict-policy-000001_conflict.txt')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留两者').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('恢复全部'));
    await tester.pumpAndSettle();

    final request = service.restoreRequests.single;
    expect(request.policies, {
      '000001_conflict.txt': UndoConflictPolicy.keepBoth,
    });
    expect(request.storedNames, isNull);
    expect(find.textContaining('以新名称恢复'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('隔离区是空的'), findsOneWidget);
  });

  testWidgets('requires acknowledgment before overwriting conflicts', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('conflict.txt', originalExists: true),
    ]);

    await pumpPage(tester, service);
    await tester.tap(find.text('查看文件'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('conflict-policy-000001_conflict.txt')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('覆盖').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('恢复全部'));
    await tester.pumpAndSettle();

    expect(find.text('覆盖 1 个原位置文件？'), findsOneWidget);
    final confirm = find.byKey(const ValueKey('conflict-confirm-button'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('overwrite-confirm-checkbox')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(service.restoreRequests.single.policies, {
      '000001_conflict.txt': UndoConflictPolicy.overwrite,
    });
    expect(find.textContaining('覆盖原位置内容'), findsOneWidget);
  });

  testWidgets('applies conflict choices independently per file', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('first.txt', originalExists: true),
      fakeQuarantineEntry('second.txt', sequence: 2, originalExists: true),
    ]);

    await pumpPage(tester, service);
    await tester.tap(find.text('查看文件'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('conflict-policy-000001_first.txt')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留两者').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('恢复全部'));
    await tester.pumpAndSettle();

    expect(service.restoreRequests.single.policies, {
      '000001_first.txt': UndoConflictPolicy.keepBoth,
      '000002_second.txt': UndoConflictPolicy.skip,
    });
    expect(find.textContaining('以新名称恢复'), findsOneWidget);
    expect(find.textContaining('本次已跳过'), findsOneWidget);
  });

  testWidgets('opens cleaning history from the quarantine summary', (
    tester,
  ) async {
    final service = FakeQuarantineService();
    service.history = _MemoryHistoryStore([
      CleanHistoryRecord(
        sessionId: 'history-session',
        startedAt: DateTime.utc(2026, 10, 18, 10),
        completedAt: DateTime.utc(2026, 10, 18, 10, 1),
        outcome: CleanHistoryOutcome.completed,
        plannedCount: 2,
        plannedBytes: 2048,
        movedCount: 2,
        movedBytes: 2048,
        skippedCount: 0,
        failureCount: 0,
        remainingCount: 0,
        rules: const [
          CleanHistoryRule(ruleId: 'test.rule', fileCount: 2, bytes: 2048),
        ],
      ),
    ]);

    await pumpPage(tester, service);
    await tester.tap(find.byKey(const ValueKey('clean-history-button')));
    await tester.pumpAndSettle();

    expect(find.text('清理历史'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('计划 2 个文件'), findsOneWidget);
    expect(find.textContaining('规则 test.rule'), findsOneWidget);
  });

  testWidgets('asks for a conflict policy from the session list', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('conflict.txt', originalExists: true),
    ]);

    await pumpPage(tester, service);
    await tester.tap(find.text('恢复全部'));
    await tester.pumpAndSettle();

    expect(find.text('1 个文件的原位置已有内容'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conflict-confirm-button')));
    await tester.pumpAndSettle();

    expect(service.restoreRequests.single.policy, UndoConflictPolicy.skip);
    expect(find.textContaining('已跳过冲突'), findsOneWidget);
  });

  testWidgets('blocks restoring integrity failures and allows purging them', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('corrupt.txt', integrityFailure: '隔离文件大小与清理记录不一致'),
    ]);

    await pumpPage(tester, service);
    await tester.tap(find.text('查看文件'));
    await tester.pumpAndSettle();

    expect(find.text('完整性异常'), findsOneWidget);
    expect(find.textContaining('未通过完整性校验'), findsOneWidget);

    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox).first);
    expect(checkbox.onChanged, isNull);

    final restoreAll = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '恢复全部'),
    );
    expect(restoreAll.onPressed, isNull);

    await tester.tap(find.text('永久删除剩余'));
    await tester.pumpAndSettle();

    expect(find.text('永久释放剩余文件？'), findsOneWidget);
    expect(find.textContaining('将永久删除 1 个文件'), findsOneWidget);
  });

  testWidgets('shows an empty state and free space', (tester) async {
    final service = FakeQuarantineService();

    await pumpPage(tester, service);

    expect(find.text('隔离区是空的'), findsOneWidget);
    expect(find.text('没有待处理的清理'), findsOneWidget);
    expect(find.textContaining('磁盘可用'), findsOneWidget);
    expect(find.text('全部永久释放'), findsNothing);
  });

  testWidgets('enables automatic retention only after acknowledgment', (
    tester,
  ) async {
    final service = FakeQuarantineService([fakeQuarantineEntry('old.txt')]);
    final retention = createRetention(service);
    await retention.ensureInitialized();

    await pumpPage(tester, service, retention: retention);

    expect(find.text('自动永久释放未开启'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retention-policy-button')));
    await tester.pumpAndSettle();

    expect(find.text('隔离区保留策略'), findsOneWidget);
    final save = find.byKey(const ValueKey('retention-save-button'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('retention-enabled-switch')));
    await tester.pumpAndSettle();

    expect(find.textContaining('不进入回收站'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tap(
      find.byKey(const ValueKey('retention-acknowledge-checkbox')),
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('自动永久释放未开启'), findsOneWidget);
    expect(retention.policy?.enabled, isFalse);
    expect(service.isEmpty, isFalse);
  });

  testWidgets('shows a persisted enabled retention policy', (tester) async {
    final service = FakeQuarantineService([fakeQuarantineEntry('kept.txt')]);
    final store = createPolicyStore();
    await store.save(
      const QuarantineRetentionPolicy(
        enabled: true,
        retentionDays: 14,
        maxBytes: 2 * 1024 * 1024 * 1024,
      ),
    );
    final retention = QuarantineRetentionService(
      quarantine: service,
      store: store,
      clock: () => DateTime(2026, 10, 18, 12),
    );
    await retention.ensureInitialized();

    await pumpPage(tester, service, retention: retention);

    expect(find.textContaining('自动永久释放：保留 14 天'), findsOneWidget);
    expect(find.textContaining('上限 2.0 GB'), findsOneWidget);
    expect(find.text('调整策略'), findsOneWidget);
    expect(service.isEmpty, isFalse);
  });

  testWidgets('reports sessions purged by the startup retention policy', (
    tester,
  ) async {
    final service = FakeQuarantineService([
      fakeQuarantineEntry('old.txt'),
      fakeQuarantineEntry('old-2.txt', sequence: 2),
    ]);
    final store = createPolicyStore();
    await store.save(
      const QuarantineRetentionPolicy(
        enabled: true,
        retentionDays: 30,
        maxBytes: 1024 * 1024 * 1024,
      ),
    );
    final retention = QuarantineRetentionService(
      quarantine: service,
      store: store,
      clock: () => DateTime(2026, 12, 1),
    );
    await retention.ensureInitialized();

    await pumpPage(tester, service, retention: retention);

    expect(find.textContaining('自动保留策略已永久释放 1 个旧会话'), findsOneWidget);
    expect(find.textContaining('共 2 个文件'), findsOneWidget);
    expect(find.text('隔离区是空的'), findsOneWidget);
    expect(service.isEmpty, isTrue);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('自动保留策略已永久释放'), findsNothing);
    expect(retention.lastReport, isNull);
  });

  testWidgets('surfaces a fail-closed retention policy error', (tester) async {
    final service = FakeQuarantineService([fakeQuarantineEntry('old.txt')]);
    final store = createPolicyStore();
    File(store.filePath).parent.createSync(recursive: true);
    File(store.filePath).writeAsStringSync('{broken');
    final retention = QuarantineRetentionService(
      quarantine: service,
      store: store,
      clock: () => DateTime(2026, 12, 1),
    );
    await retention.ensureInitialized();

    await pumpPage(tester, service, retention: retention);

    expect(find.textContaining('保留策略读取失败，自动永久释放已停用'), findsOneWidget);
    expect(find.text('自动永久释放未开启'), findsOneWidget);
    expect(service.isEmpty, isFalse);
  });
}
