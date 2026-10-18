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

String formatCount(int count) {
  if (count >= 100000) {
    return '${(count / 10000).toStringAsFixed(count >= 1000000 ? 0 : 1)} 万';
  }
  return '$count';
}

String formatDate(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

String formatDateTime(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${formatDate(date)} ${two(date.hour)}:${two(date.minute)}';
}

String fileNameOf(String path) => p.windows.basename(path);
