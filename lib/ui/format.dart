import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final decimals = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

final _decimalFormats = <String, NumberFormat>{};
final _compactFormats = <String, NumberFormat>{};

String formatCount(int count) {
  final locale = Intl.defaultLocale ?? 'zh';
  if (locale.startsWith('zh')) {
    if (count >= 100000) {
      final value = count / 10000;
      return '${value.toStringAsFixed(count >= 1000000 ? 0 : 1)} 万';
    }
  } else if (count >= 100000) {
    // Constructing a NumberFormat parses its pattern and symbols, so keep one
    // per locale instead of rebuilding it on every live-updating label.
    return _compactFormats
        .putIfAbsent(locale, () => NumberFormat.compact(locale: locale))
        .format(count);
  }
  return _decimalFormats
      .putIfAbsent(locale, () => NumberFormat.decimalPattern(locale))
      .format(count);
}

String formatDate(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  final locale = Intl.defaultLocale ?? 'zh';
  if (locale.startsWith('zh')) {
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }
  return '${_months[date.month - 1]} ${date.day}, ${date.year}';
}

String formatDuration(Duration duration) {
  final locale = Intl.defaultLocale ?? 'zh';
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (locale.startsWith('zh')) {
    if (minutes >= 60) {
      return '${minutes ~/ 60} 小时 ${minutes % 60} 分';
    }
    if (minutes > 0) return '$minutes 分 $seconds 秒';
    return '$totalSeconds 秒';
  }
  if (minutes >= 60) {
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${totalSeconds}s';
}

String formatDateTime(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  final locale = Intl.defaultLocale ?? 'zh';
  if (locale.startsWith('zh')) {
    return '${formatDate(date)} ${two(date.hour)}:${two(date.minute)}';
  }
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final suffix = date.hour < 12 ? 'AM' : 'PM';
  return '${formatDate(date)} $hour:${two(date.minute)} $suffix';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String fileNameOf(String path) => p.windows.basename(path);
