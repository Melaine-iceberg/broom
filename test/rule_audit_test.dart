import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/windows_rule_resolver.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:broom/core/rules/windows_system_rules.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _windowsOnly = !Platform.isWindows ? 'Windows only' : false;

const _environmentKeys = <String>[
  'TEMP',
  'LOCALAPPDATA',
  'APPDATA',
  'USERPROFILE',
  'WINDIR',
  'ProgramData',
  'SystemDrive',
];

void main() {
  test('every production rule declares complete audit metadata', () {
    final ids = <String>{};

    for (final rule in windowsSafeRules) {
      expect(ids.add(rule.id), isTrue, reason: 'duplicate rule id ${rule.id}');
      expect(rule.risk, CleanRisk.safe, reason: '${rule.id} must stay safe');
      _expectCompleteAudit(rule.id, rule.audit, rule.pathPatterns);
    }

    for (final rule in windowsReviewRules) {
      expect(ids.add(rule.id), isTrue, reason: 'duplicate rule id ${rule.id}');
      expect(
        rule.risk,
        CleanRisk.review,
        reason: '${rule.id} must stay review level',
      );
      _expectCompleteAudit(rule.id, rule.audit, rule.pathPatterns);
    }

    for (final rule in windowsSystemCacheRules) {
      expect(ids.add(rule.id), isTrue, reason: 'duplicate rule id ${rule.id}');
      expect(
        rule.risk,
        CleanRisk.review,
        reason: '${rule.id} must stay review level',
      );
      _expectCompleteAudit(rule.id, rule.audit, [rule.displayPath]);
    }
  });

  group('audit regression samples', () {
    late Directory base;
    late Map<String, String> environment;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('broom_rule_audit_');
      environment = {
        for (final key in _environmentKeys)
          key: p.windows.join(base.path, key.toLowerCase()),
      };
    });

    tearDown(() async {
      if (await base.exists()) {
        await base.delete(recursive: true);
      }
    });

    test('cleanup rules scan exactly their audited files', () async {
      final rules = [...windowsSafeRules, ...windowsReviewRules];
      final created = <String>{};
      for (final rule in rules) {
        await _materialize(rule.audit!.samples, environment, created);
      }

      for (final rule in rules) {
        final roots = await WindowsRuleResolver(environment: environment)
            .resolve(rule);
        expect(
          roots,
          isNotEmpty,
          reason: '${rule.id} should resolve roots from its audit samples',
        );

        final scan = await JunkScanner(
          jobs: [
            ScanJob(
              ruleId: rule.id,
              roots: roots,
              minAge: rule.minAge,
              extensions: rule.extensions,
            ),
          ],
        ).scan();
        expect(scan.cancelled, isFalse, reason: rule.id);

        final found = {for (final item in scan.items) _key(item.path)};
        for (final sample in rule.audit!.samples) {
          final path = _key(_expandSample(sample.path, environment));
          expect(
            found.contains(path),
            sample.inScope,
            reason:
                '${rule.id}: ${sample.reason ?? 'unexpected scan result'} '
                '(${sample.path})',
          );
        }
      }
    }, skip: _windowsOnly);

    test('system rules scan exactly their audited files', () async {
      final created = <String>{};
      for (final rule in windowsSystemCacheRules) {
        await _materialize(rule.audit!.samples, environment, created);
      }

      for (final rule in windowsSystemCacheRules) {
        final root = _expandSample(rule.displayPath, environment);
        expect(
          await Directory(root).exists(),
          isTrue,
          reason: '${rule.id} audit samples must create its root',
        );

        final scan = await JunkScanner(
          jobs: [
            ScanJob(ruleId: rule.id, roots: [root]),
          ],
        ).scan();
        expect(scan.cancelled, isFalse, reason: rule.id);

        final found = {for (final item in scan.items) _key(item.path)};
        for (final sample in rule.audit!.samples) {
          final path = _key(_expandSample(sample.path, environment));
          expect(
            found.contains(path),
            sample.inScope,
            reason:
                '${rule.id}: ${sample.reason ?? 'unexpected scan result'} '
                '(${sample.path})',
          );
        }
      }
    }, skip: _windowsOnly);
  });
}

void _expectCompleteAudit(
  String ruleId,
  RuleAudit? audit,
  List<String> patterns,
) {
  expect(audit, isNotNull, reason: '$ruleId must declare a RuleAudit');
  final data = audit!;
  expect(data.reviewNotes.trim(), isNotEmpty, reason: '$ruleId review notes');
  expect(
    data.reviewNotesEn?.trim(),
    isNotEmpty,
    reason: '$ruleId English review notes',
  );
  expect(
    data.reverseEvidence.trim(),
    isNotEmpty,
    reason: '$ruleId reverse evidence',
  );
  expect(
    data.reverseEvidenceEn?.trim(),
    isNotEmpty,
    reason: '$ruleId English reverse evidence',
  );
  expect(data.samples, isNotEmpty, reason: '$ruleId regression samples');

  final paths = <String>{};
  for (final sample in data.samples) {
    expect(
      patterns,
      contains(sample.pattern),
      reason:
          '$ruleId sample references an undeclared pattern: ${sample.pattern}',
    );
    expect(
      sample.path,
      contains('%'),
      reason: '$ruleId samples must use environment placeholders',
    );
    expect(
      paths.add(sample.path.toLowerCase()),
      isTrue,
      reason: '$ruleId has a duplicate sample path: ${sample.path}',
    );
  }

  for (final pattern in patterns) {
    final matching = data.samples.where((sample) => sample.pattern == pattern);
    expect(
      matching.where((sample) => sample.inScope),
      isNotEmpty,
      reason: '$ruleId pattern has no positive sample: $pattern',
    );
    expect(
      matching.where((sample) => !sample.inScope),
      isNotEmpty,
      reason: '$ruleId pattern has no negative sample: $pattern',
    );
  }
}

Future<void> _materialize(
  List<RuleAuditSample> samples,
  Map<String, String> environment,
  Set<String> created,
) async {
  for (final sample in samples) {
    final path = _expandSample(sample.path, environment);
    expect(
      created.add(_key(path)),
      isTrue,
      reason: 'duplicate audit fixture path: $path',
    );
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(sample.content ?? 'broom-audit');
    await file.setLastModified(DateTime.now().subtract(sample.age));
  }
}

String _expandSample(String samplePath, Map<String, String> environment) {
  final byName = {
    for (final entry in environment.entries)
      entry.key.toLowerCase(): entry.value,
  };
  final missing = <String>[];
  final expanded = samplePath.replaceAllMapped(RegExp(r'%([^%]+)%'), (match) {
    final name = match.group(1)!.toLowerCase();
    final value = byName[name];
    if (value == null || value.isEmpty) {
      missing.add(name);
      return '';
    }
    return value;
  });
  expect(
    missing,
    isEmpty,
    reason: 'audit sample uses unknown environment variables: $missing',
  );
  return PathGuard.normalize(p.windows.absolute(expanded));
}

String _key(String path) => PathGuard.normalize(path).toLowerCase();
