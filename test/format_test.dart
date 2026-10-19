import 'package:broom/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  tearDown(() => Intl.defaultLocale = null);

  test('formats numbers and dates for Chinese', () {
    Intl.defaultLocale = 'zh';

    expect(formatCount(25000), '25,000');
    expect(formatCount(150000), '15.0 万');
    expect(formatDate(DateTime(2026, 10, 18)), '2026-10-18');
    expect(formatDateTime(DateTime(2026, 10, 18, 15, 5)), '2026-10-18 15:05');
    expect(formatDuration(const Duration(seconds: 45)), '45 秒');
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '2 分 5 秒');
    expect(formatDuration(const Duration(hours: 1, minutes: 12)), '1 小时 12 分');
  });

  test('formats numbers and dates for English', () {
    Intl.defaultLocale = 'en';

    expect(formatCount(25000), '25,000');
    expect(formatCount(150000), '150K');
    expect(formatDate(DateTime(2026, 10, 18)), 'Oct 18, 2026');
    expect(
      formatDateTime(DateTime(2026, 10, 18, 15, 5)),
      'Oct 18, 2026 3:05 PM',
    );
    expect(formatDuration(const Duration(seconds: 45)), '45s');
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '2m 5s');
    expect(formatDuration(const Duration(hours: 1, minutes: 12)), '1h 12m');
  });
}
