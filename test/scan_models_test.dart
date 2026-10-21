import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/rules/windows_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyScanError', () {
    test('maps common Windows error codes', () {
      expect(_kind(5), ScanErrorKind.accessDenied);
      expect(_kind(206), ScanErrorKind.pathTooLong);
      expect(_kind(3), ScanErrorKind.notFound);
      expect(_kind(21), ScanErrorKind.deviceNotReady);
      expect(_kind(53), ScanErrorKind.networkUnavailable);
      expect(_kind(19), ScanErrorKind.writeProtected);
      expect(_kind(112), ScanErrorKind.diskFull);
      expect(_kind(50), ScanErrorKind.unsupported);
      expect(_kind(32), ScanErrorKind.sharingViolation);
      expect(_kind(123), ScanErrorKind.invalidName);
      expect(_kind(99999), ScanErrorKind.ioError);
    });

    test('falls back to messages when there is no OS code', () {
      expect(
        classifyScanError(const FileSystemException('Access is denied.')),
        ScanErrorKind.accessDenied,
      );
      expect(
        classifyScanError(const FileSystemException('random failure')),
        ScanErrorKind.ioError,
      );
      expect(classifyScanError(StateError('other')), ScanErrorKind.other);
    });
  });

  test('scan options can clear a configured item limit', () {
    const options = ScanOptions(maxItems: 100, parallelism: 2);
    final cleared = options.copyWith(clearMaxItems: true);
    expect(cleared.maxItems, isNull);
    expect(cleared.parallelism, 2);
    expect(const ScanOptions().maxItems, isNull);
  });

  test('each built-in category has one stable scan category key', () {
    final keysByCategory = <String, Set<String>>{};
    for (final rule in windowsCleanupRules) {
      keysByCategory
          .putIfAbsent(rule.category, () => <String>{})
          .add(ruleCategoryKey(rule));
    }
    for (final entry in keysByCategory.entries) {
      expect(entry.value, hasLength(1), reason: entry.key);
    }
    final allKeys = [for (final keys in keysByCategory.values) keys.single];
    expect(allKeys.toSet(), hasLength(allKeys.length));
  });

  test('leftover rules use the leftover category key', () {
    final rule = CleanerRule(
      id: 'leftover.slack',
      title: 'Slack 卸载残留',
      category: '卸载残留',
      description: '测试规则',
      pathPatterns: const [r'%APPDATA%\Slack'],
    );

    expect(ruleCategoryKey(rule), 'leftover');
  });

  test('scan settings map to scan options', () {
    const settings = ScanSettings(
      disabledCategoryIds: {'browser'},
      parallelism: 0,
      lowPriority: false,
      useNtfsIndex: true,
      itemLimit: 5000,
    );
    final options = settings.toOptions(batchSize: 64);
    expect(settings.isCategoryEnabled('browser'), isFalse);
    expect(settings.isCategoryEnabled('dev'), isTrue);
    expect(options.maxItems, 5000);
    expect(options.parallelism, 0);
    expect(options.lowPriority, isFalse);
    expect(options.useNtfsIndex, isTrue);
    expect(options.batchSize, 64);
  });
}

ScanErrorKind _kind(int code) => classifyScanError(
  FileSystemException('failure', r'C:\cache\file', OSError('failure', code)),
);
