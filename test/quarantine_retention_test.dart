import 'dart:io';

import 'package:broom/core/clean/quarantine_retention_service.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/quarantine_policy_models.dart';
import 'package:broom/core/settings/quarantine_policy_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RetentionSession {
  _RetentionSession({
    required this.id,
    required this.createdAt,
    required this.bytes,
    this.fileCount = 1,
    this.failPurge = false,
  });

  final String id;
  final DateTime createdAt;
  final int bytes;
  final int fileCount;
  final bool failPurge;
}

class _FakeRetentionQuarantine implements QuarantineService {
  _FakeRetentionQuarantine(Iterable<_RetentionSession> sessions)
    : sessions = List.of(sessions)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  final List<_RetentionSession> sessions;
  final List<String> purged = [];

  @override
  String get quarantineRoot => r'C:\Users\Alice\AppData\Local\Broom\quarantine';

  @override
  Future<List<QuarantineSessionInfo>> listSessions() async => [
    for (final session in sessions)
      QuarantineSessionInfo(
        id: session.id,
        createdAt: session.createdAt,
        status: QuarantineStatus.ready,
        entryCount: session.fileCount,
        totalBytes: session.bytes,
        pendingCount: session.fileCount,
        pendingBytes: session.bytes,
      ),
  ];

  @override
  Future<QuarantinePurgeReport> purgeSession(String sessionId) async {
    final session = sessions.firstWhere((session) => session.id == sessionId);
    if (session.failPurge) {
      throw FileSystemException('文件被占用', sessionId);
    }
    sessions.remove(session);
    purged.add(sessionId);
    return QuarantinePurgeReport(
      removedCount: session.fileCount,
      removedBytes: session.bytes,
      failureCount: 0,
      failures: const [],
      sessionRemoved: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const mib = 1024 * 1024;
  final now = DateTime(2026, 10, 18, 12);
  const enabledPolicy = QuarantineRetentionPolicy(
    enabled: true,
    retentionDays: 30,
    maxBytes: 1024 * mib,
  );

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_retention_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  QuarantinePolicyStore createStore() => QuarantinePolicyStore(
    filePath: p.windows.join(temp.path, 'quarantine_policy.json'),
  );

  QuarantineRetentionService createRetention(
    _FakeRetentionQuarantine quarantine, {
    DateTime? clock,
  }) => QuarantineRetentionService(
    quarantine: quarantine,
    store: createStore(),
    clock: () => clock ?? now,
  );

  test('does nothing when the policy is disabled', () async {
    final quarantine = _FakeRetentionQuarantine([
      _RetentionSession(
        id: 'old',
        createdAt: now.subtract(const Duration(days: 90)),
        bytes: 2 * mib,
      ),
    ]);
    final retention = createRetention(quarantine);

    final report = await retention.apply(QuarantineRetentionPolicy.defaults);

    expect(report.didPurge, isFalse);
    expect(report.evaluatedSessionCount, 0);
    expect(quarantine.purged, isEmpty);
  });

  test('purges sessions older than the retention window', () async {
    final quarantine = _FakeRetentionQuarantine([
      _RetentionSession(
        id: 'old',
        createdAt: now.subtract(const Duration(days: 31)),
        bytes: 2 * mib,
        fileCount: 3,
      ),
      _RetentionSession(
        id: 'recent',
        createdAt: now.subtract(const Duration(days: 5)),
        bytes: 3 * mib,
      ),
    ]);
    final retention = createRetention(quarantine);

    final report = await retention.apply(enabledPolicy);

    expect(quarantine.purged, ['old']);
    expect(report.evaluatedSessionCount, 2);
    expect(report.selectedSessionCount, 1);
    expect(report.removedSessionCount, 1);
    expect(report.removedFileCount, 3);
    expect(report.removedBytes, 2 * mib);
    expect(report.failureCount, 0);
    expect(report.didPurge, isTrue);
  });

  test('purges oldest sessions first until under the size cap', () async {
    final quarantine = _FakeRetentionQuarantine([
      _RetentionSession(
        id: 'newest',
        createdAt: now.subtract(const Duration(days: 1)),
        bytes: 4 * mib,
      ),
      _RetentionSession(
        id: 'middle',
        createdAt: now.subtract(const Duration(days: 2)),
        bytes: 4 * mib,
      ),
      _RetentionSession(
        id: 'oldest',
        createdAt: now.subtract(const Duration(days: 3)),
        bytes: 4 * mib,
      ),
    ]);
    final retention = createRetention(quarantine);

    final report = await retention.apply(
      const QuarantineRetentionPolicy(
        enabled: true,
        retentionDays: 3650,
        maxBytes: 5 * mib,
      ),
    );

    expect(quarantine.purged, ['oldest', 'middle']);
    expect(report.selectedSessionCount, 2);
    expect(report.removedSessionCount, 2);
    expect(report.removedBytes, 8 * mib);
    expect(quarantine.sessions.single.id, 'newest');
  });

  test('can purge the newest session when it alone exceeds the cap', () async {
    final quarantine = _FakeRetentionQuarantine([
      _RetentionSession(
        id: 'only',
        createdAt: now.subtract(const Duration(days: 1)),
        bytes: 6 * mib,
      ),
    ]);
    final retention = createRetention(quarantine);

    final report = await retention.apply(
      const QuarantineRetentionPolicy(
        enabled: true,
        retentionDays: 3650,
        maxBytes: 5 * mib,
      ),
    );

    expect(quarantine.purged, ['only']);
    expect(report.removedSessionCount, 1);
    expect(report.removedBytes, 6 * mib);
  });

  test('reports purge failures and continues with later sessions', () async {
    final quarantine = _FakeRetentionQuarantine([
      _RetentionSession(
        id: 'locked',
        createdAt: now.subtract(const Duration(days: 40)),
        bytes: 2 * mib,
        failPurge: true,
      ),
      _RetentionSession(
        id: 'free',
        createdAt: now.subtract(const Duration(days: 35)),
        bytes: 2 * mib,
      ),
    ]);
    final retention = createRetention(quarantine);

    final report = await retention.apply(enabledPolicy);

    expect(quarantine.purged, ['free']);
    expect(report.selectedSessionCount, 2);
    expect(report.removedSessionCount, 1);
    expect(report.removedFileCount, 1);
    expect(report.failureCount, 1);
    expect(report.failures.single.reason, contains('文件被占用'));
    expect(report.didPurge, isTrue);
  });

  test('loads an enabled policy and applies it once', () async {
    await createStore().save(enabledPolicy);
    final quarantine = _FakeRetentionQuarantine([
      _RetentionSession(
        id: 'old',
        createdAt: now.subtract(const Duration(days: 60)),
        bytes: 2 * mib,
      ),
    ]);
    final retention = createRetention(quarantine);

    await retention.ensureInitialized();
    await retention.ensureInitialized();

    expect(retention.policy?.enabled, isTrue);
    expect(retention.loadError, isNull);
    expect(retention.lastReport?.removedSessionCount, 1);
    expect(quarantine.purged, ['old']);
  });

  test('fails closed when the policy file is corrupted', () async {
    final store = createStore();
    await File(store.filePath).parent.create(recursive: true);
    await File(store.filePath).writeAsString('{not-json');

    final quarantine = _FakeRetentionQuarantine([
      _RetentionSession(
        id: 'old',
        createdAt: now.subtract(const Duration(days: 60)),
        bytes: 2 * mib,
      ),
    ]);
    final retention = QuarantineRetentionService(
      quarantine: quarantine,
      store: store,
      clock: () => now,
    );

    await retention.ensureInitialized();

    expect(retention.policy?.enabled, isFalse);
    expect(retention.loadError, contains('保留策略数据无效'));
    expect(retention.lastReport, isNull);
    expect(quarantine.purged, isEmpty);
  });

  test(
    'saves a policy, applies it immediately, and clears disabled reports',
    () async {
      final quarantine = _FakeRetentionQuarantine([
        _RetentionSession(
          id: 'old',
          createdAt: now.subtract(const Duration(days: 60)),
          bytes: 2 * mib,
        ),
      ]);
      final store = createStore();
      final retention = QuarantineRetentionService(
        quarantine: quarantine,
        store: store,
        clock: () => now,
      );

      final report = await retention.save(enabledPolicy);

      expect(report?.removedSessionCount, 1);
      expect(retention.policy, enabledPolicy);
      expect(retention.loadError, isNull);
      expect(retention.lastReport?.removedSessionCount, 1);
      expect((await store.load()).enabled, isTrue);
      expect(quarantine.purged, ['old']);

      final disabled = enabledPolicy.copyWith(enabled: false);
      expect(await retention.save(disabled), isNull);
      expect(retention.policy?.enabled, isFalse);
      expect(retention.lastReport, isNull);
      expect((await store.load()).enabled, isFalse);
    },
  );
}
