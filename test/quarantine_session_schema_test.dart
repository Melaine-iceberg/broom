import 'package:broom/core/clean/quarantine_session_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrates a v1 session to the current schema', () {
    final raw = <String, dynamic>{
      'schemaVersion': 1,
      'id': '20261018_120000_abcd',
      'createdAt': '2026-10-18T12:00:00.000Z',
      'status': 'ready',
    };

    final migrated = migrateQuarantineSessionJson(raw);

    expect(migrated['schemaVersion'], currentQuarantineSessionSchemaVersion);
    expect(migrated['skippedCount'], 0);
    expect(migrated['updatedAt'], '2026-10-18T12:00:00.000Z');
    // The input map is never modified in place.
    expect(raw['schemaVersion'], 1);
    expect(raw.containsKey('skippedCount'), isFalse);
  });

  test('treats a missing version as the legacy v1 layout', () {
    final migrated = migrateQuarantineSessionJson({
      'id': 'legacy',
      'createdAt': '2026-10-18T12:00:00.000Z',
      'status': 'partial',
      'skippedCount': 4,
    });

    expect(migrated['schemaVersion'], currentQuarantineSessionSchemaVersion);
    // Existing values are preserved rather than overwritten.
    expect(migrated['skippedCount'], 4);
  });

  test('keeps a current version session unchanged', () {
    final migrated = migrateQuarantineSessionJson({
      'schemaVersion': currentQuarantineSessionSchemaVersion,
      'id': 'current',
      'createdAt': '2026-10-18T12:00:00.000Z',
      'updatedAt': '2026-10-18T13:00:00.000Z',
      'skippedCount': 2,
    });

    expect(migrated['skippedCount'], 2);
    expect(migrated['updatedAt'], '2026-10-18T13:00:00.000Z');
  });

  test('rejects a newer session version instead of guessing', () {
    expect(
      () => migrateQuarantineSessionJson({
        'schemaVersion': currentQuarantineSessionSchemaVersion + 1,
      }),
      throwsA(isA<QuarantineSessionFormatException>()),
    );
  });

  test('rejects malformed and out-of-range versions', () {
    for (final version in <Object>['2', 1.0, true, 0, -1]) {
      expect(
        () => migrateQuarantineSessionJson({'schemaVersion': version}),
        throwsA(isA<QuarantineSessionFormatException>()),
        reason: 'version: $version',
      );
    }
  });
}
