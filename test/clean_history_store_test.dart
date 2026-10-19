import 'dart:convert';
import 'dart:io';

import 'package:broom/core/clean/clean_history_store.dart';
import 'package:broom/core/models/clean_history_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

CleanHistoryRecord _record(
  String sessionId, {
  DateTime? completedAt,
  CleanHistoryOutcome outcome = CleanHistoryOutcome.completed,
  int movedCount = 1,
  int movedBytes = 5,
  int skippedCount = 0,
  int failureCount = 0,
  int remainingCount = 0,
  List<CleanHistoryRule> rules = const [
    CleanHistoryRule(ruleId: 'test.rule', fileCount: 1, bytes: 5),
  ],
}) => CleanHistoryRecord(
  sessionId: sessionId,
  startedAt:
      completedAt?.subtract(const Duration(minutes: 1)) ??
      DateTime.utc(2026, 10, 18, 12),
  completedAt: completedAt ?? DateTime.utc(2026, 10, 18, 12),
  outcome: outcome,
  plannedCount: movedCount + skippedCount + failureCount + remainingCount,
  plannedBytes: movedBytes + 1024,
  movedCount: movedCount,
  movedBytes: movedBytes,
  skippedCount: skippedCount,
  failureCount: failureCount,
  remainingCount: remainingCount,
  rules: rules,
);

void main() {
  late Directory temp;
  late CleanHistoryStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_history_');
    store = CleanHistoryStore(
      filePath: p.windows.join(temp.path, 'clean_history.json'),
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('round-trips records newest first', () async {
    final earlier = _record(
      'earlier',
      completedAt: DateTime.utc(2026, 10, 17, 8),
      skippedCount: 2,
    );
    final later = _record(
      'later',
      completedAt: DateTime.utc(2026, 10, 18, 9),
      outcome: CleanHistoryOutcome.partial,
      remainingCount: 3,
    );

    await store.upsert(earlier);
    await store.upsert(later);

    final records = await store.load();
    expect(records, hasLength(2));
    expect(records.first.sessionId, 'later');
    expect(records.first.outcome, CleanHistoryOutcome.partial);
    expect(records.first.remainingCount, 3);
    expect(records.last.sessionId, 'earlier');
    expect(records.last.skippedCount, 2);
    expect(records.first.rules.single.ruleId, 'test.rule');
    expect(records.first.plannedBytes, greaterThan(records.first.movedBytes));
  });

  test('upsert replaces the record for the same session', () async {
    await store.upsert(_record('one', movedCount: 1));
    await store.upsert(
      _record(
        'one',
        completedAt: DateTime.utc(2026, 10, 18, 13),
        movedCount: 4,
        movedBytes: 20,
      ),
    );

    final records = await store.load();
    expect(records, hasLength(1));
    expect(records.single.sessionId, 'one');
    expect(records.single.movedCount, 4);
  });

  test('keeps only the most recent records', () async {
    for (var index = 0; index < CleanHistoryStore.maxRecords + 5; index++) {
      await store.upsert(
        _record(
          'session-$index',
          completedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
        ),
      );
    }

    final records = await store.load();
    expect(records, hasLength(CleanHistoryStore.maxRecords));
    expect(records.first.sessionId, 'session-204');
    expect(records.last.sessionId, 'session-5');
  });

  test('archives a corrupt history file and accepts new records', () async {
    final file = File(store.filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');

    await expectLater(store.load(), throwsA(isA<CleanHistoryException>()));

    await store.upsert(_record('fresh'));

    final records = await store.load();
    expect(records.single.sessionId, 'fresh');
    final backups = await temp
        .list()
        .where(
          (entity) =>
              p.basename(entity.path).startsWith('clean_history.json.corrupt-'),
        )
        .toList();
    expect(backups, hasLength(1));
  });

  test('skips invalid records without discarding valid ones', () async {
    final file = File(store.filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'records': [
          _record(
            'valid-1',
            completedAt: DateTime.utc(2026, 10, 17, 12),
          ).toJson(),
          {'sessionId': '', 'outcome': 'completed'},
          _record(
            'valid-2',
            completedAt: DateTime.utc(2026, 10, 18, 12),
          ).toJson(),
        ],
      }),
    );

    final records = await store.load();
    expect(records.map((record) => record.sessionId), ['valid-2', 'valid-1']);
  });

  test('rejects an unsupported history schema version', () async {
    final file = File(store.filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'schemaVersion': 9, 'records': <Object>[]}),
    );

    await expectLater(
      store.load(),
      throwsA(
        isA<CleanHistoryException>().having(
          (error) => error.corrupt,
          'corrupt',
          isTrue,
        ),
      ),
    );
  });

  test('requires an absolute history path', () {
    expect(
      () => CleanHistoryStore(filePath: 'relative/clean_history.json'),
      throwsArgumentError,
    );
  });
}
