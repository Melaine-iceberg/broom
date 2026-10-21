// System cache cleaner metadata benchmark (P2-10 in docs/perf-review.md).
//
// The cleaner used to await `FileSystemEntity.type(followLinks: false)` and
// then `File.length()` for every file. `FileStat.stat` would return type and
// size in one call, but it resolves links before reporting the type, so it
// cannot preserve the "skip links and junctions" check. The cleaner therefore
// starts the no-follow type query and the length query together and awaits
// them one after the other; the two metadata calls overlap instead of
// serialising. This benchmark measures that overlap on real files.
//
// Run manually; `flutter test` only scans `test/`, so this never runs in CI:
//
//   dart run benchmark/system_cache_metadata_benchmark.dart
//   dart run benchmark/system_cache_metadata_benchmark.dart --files=1000
//
// Files are created under the system temporary directory and removed
// afterwards.

import 'dart:io';
import 'dart:math';

const _defaultFileCount = 500;
const _rounds = 5;

Future<void> main(List<String> args) async {
  final fileCount = _intArg(args, '--files') ?? _defaultFileCount;
  stdout.writeln('Broom system cache metadata benchmark');
  stdout.writeln(
    'Dart ${Platform.version.split(' ').first}, '
    '${Platform.numberOfProcessors} logical processors, $fileCount files',
  );

  final temp = Directory.systemTemp.createTempSync('broom_metadata_bench_');
  try {
    final paths = _createFiles(temp, fileCount);
    // Warm the filesystem cache before measuring.
    await _runOnce(paths, _sequential);
    await _runOnce(paths, _overlapped);

    final sequential = await _medianMicrosPerFile(
      '串行 type + length（旧）',
      paths,
      _sequential,
    );
    final overlapped = await _medianMicrosPerFile(
      '并发 type + length（新）',
      paths,
      _overlapped,
    );
    final stat = await _medianMicrosPerFile(
      'FileStat.stat（参考：会解析链接）',
      paths,
      _stat,
    );
    final typeOnly = await _medianMicrosPerFile(
      '仅 type(followLinks: false)（参考）',
      paths,
      _typeOnly,
    );

    stdout.writeln('');
    stdout.writeln(
      '  └ 每文件节省 '
      '${(sequential - overlapped).toStringAsFixed(1)} µs；'
      'stat 单次查询为 ${stat.toStringAsFixed(1)} µs，'
      'type 单次查询为 ${typeOnly.toStringAsFixed(1)} µs'
      '（校验和 $_sink，仅用于阻止查询结果被消除）。',
    );
  } finally {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Leaving a temp directory behind is harmless.
    }
  }
}

List<String> _createFiles(Directory directory, int count) {
  final random = Random(23);
  return [
    for (var index = 0; index < count; index++)
      () {
        final file = File(
          '${directory.path}${Platform.pathSeparator}f$index.bin',
        );
        file.writeAsBytesSync(List.filled(64 + random.nextInt(4096), 1));
        return file.path;
      }(),
  ];
}

int _sink = 0;

Future<int> _sequential(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type != FileSystemEntityType.file) return 0;
  return File(path).length();
}

Future<int> _overlapped(String path) async {
  final typeFuture = FileSystemEntity.type(path, followLinks: false);
  final lengthFuture = File(path).length();
  final type = await typeFuture;
  if (type != FileSystemEntityType.file) return 0;
  return lengthFuture;
}

Future<int> _stat(String path) async {
  final stat = await FileStat.stat(path);
  return stat.type == FileSystemEntityType.file ? stat.size : 0;
}

Future<int> _typeOnly(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  return type == FileSystemEntityType.file ? 1 : 0;
}

Future<double> _medianMicrosPerFile(
  String label,
  List<String> paths,
  Future<int> Function(String path) query,
) async {
  final samples = <double>[];
  for (var round = 0; round < _rounds; round++) {
    final watch = Stopwatch()..start();
    var bytes = 0;
    for (final path in paths) {
      bytes += await query(path);
    }
    watch.stop();
    _sink += bytes;
    samples.add(watch.elapsedMicroseconds / paths.length);
  }
  samples.sort();
  final median = samples[samples.length ~/ 2];
  stdout.writeln(
    '  ${label.padRight(40)}${median.toStringAsFixed(1).padLeft(8)} µs/file',
  );
  return median;
}

Future<int> _runOnce(
  List<String> paths,
  Future<int> Function(String path) query,
) async {
  var bytes = 0;
  for (final path in paths) {
    bytes += await query(path);
  }
  return bytes;
}

int? _intArg(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) {
      return int.tryParse(arg.substring(name.length + 1));
    }
  }
  return null;
}
