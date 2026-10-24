import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/platform/windows_rule_resolver.dart';
import 'package:broom/core/rules/linux_rules.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

final _linuxOnly = !Platform.isLinux ? 'Linux only' : false;

const _semantics = PosixPathSemantics();

void main() {
  test('every Linux rule declares complete audit metadata', () {
    final ids = <String>{};

    for (final rule in linuxSafeRules) {
      expect(ids.add(rule.id), isTrue, reason: 'duplicate rule id ${rule.id}');
      expect(rule.risk, CleanRisk.safe, reason: '${rule.id} must stay safe');
      _expectCompleteAudit(rule.id, rule.audit, rule.pathPatterns);
    }

    for (final rule in linuxReviewRules) {
      expect(ids.add(rule.id), isTrue, reason: 'duplicate rule id ${rule.id}');
      expect(
        rule.risk,
        CleanRisk.review,
        reason: '${rule.id} must stay review level',
      );
      _expectCompleteAudit(rule.id, rule.audit, rule.pathPatterns);
    }
  });

  group('Linux audit regression samples', () {
    late Directory base;
    late Map<String, String> environment;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('broom_linux_audit_');
      environment = {
        'HOME': _semantics.join(base.path, 'home'),
        'XDG_CACHE_HOME': _semantics.join(base.path, 'cache'),
        'XDG_CONFIG_HOME': _semantics.join(base.path, 'config'),
        'XDG_DATA_HOME': _semantics.join(base.path, 'data'),
        'VCPKG_ROOT': _semantics.join(base.path, 'vcpkg-root'),
        'VCPKG_DOWNLOADS': _semantics.join(base.path, 'vcpkg-downloads'),
        'VCPKG_DEFAULT_BINARY_CACHE': _semantics.join(
          base.path,
          'vcpkg-binary-cache',
        ),
      };
    });

    tearDown(() async {
      if (await base.exists()) {
        await base.delete(recursive: true);
      }
    });

    test('cleanup rules scan exactly their audited files', () async {
      final rules = [...linuxSafeRules, ...linuxReviewRules];
      final created = <String>{};
      for (final rule in rules) {
        await _materialize(rule.audit!.samples, environment, created);
      }

      for (final rule in rules) {
        final roots = await PosixRuleResolver(environment: environment)
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
          semantics: _semantics,
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
    }, skip: _linuxOnly);
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
      matches(RegExp(r'^(\$|~)')),
      reason: '$ruleId samples must use POSIX placeholders',
    );
    expect(
      paths.add(sample.path),
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
  var expanded = samplePath;
  final home = environment['HOME'];
  if (expanded == '~') {
    expect(home, isNotNull, reason: 'audit sample needs HOME');
    expanded = home!;
  } else if (expanded.startsWith('~/')) {
    expect(home, isNotNull, reason: 'audit sample needs HOME');
    expanded = '$home/${expanded.substring(2)}';
  }

  final missing = <String>[];
  expanded = expanded.replaceAllMapped(RegExp(r'\$\{([^}]+)\}'), (match) {
    final value = environment[match.group(1)!];
    if (value == null || value.isEmpty) {
      missing.add(match.group(1)!);
      return '';
    }
    return value;
  });
  expanded = expanded.replaceAllMapped(RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)'), (
    match,
  ) {
    final value = environment[match.group(1)!];
    if (value == null || value.isEmpty) {
      missing.add(match.group(1)!);
      return '';
    }
    return value;
  });
  expect(
    missing,
    isEmpty,
    reason: 'audit sample uses unknown environment variables: $missing',
  );
  return _semantics.normalize(_semantics.absolute(expanded));
}

String _key(String path) => _semantics.key(path);
