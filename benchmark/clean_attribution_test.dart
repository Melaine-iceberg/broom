// Per-file attribution of the quarantine clean loop (P0-5 in
// docs/perf-review.md).
//
// Runs `QuarantineService.clean()` against real files on the local volume with
// a timing decorator around the filesystem. Every system call the loop makes is
// attributed to the operation that issued it and to the phase it happened in
// (setup + plan, the per-file loop, finalize), so the end-to-end per-file cost
// has no unattributed remainder left.
//
// Run manually; `flutter test` only scans `test/`, so this never runs in CI:
//
//   flutter test benchmark/clean_attribution_test.dart
//
// Nothing here touches the user's caches: files are created under the system
// temporary directory and removed afterwards.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:broom/core/clean/file_metadata.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/safety/path_exclusions.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _fileCount = 400;
const _fileSize = 1024;
const _rounds = 3;

void main() {
  test('clean loop attribution', () async {
    final base = Directory(
      p.windows.join(
        Directory.systemTemp.path,
        'broom_attr_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await base.create(recursive: true);
    stdout.writeln('base: ${base.path}');

    final rounds = <_Round>[];
    for (var round = 0; round < _rounds; round++) {
      rounds.add(await _runCleanRound(base, 'round$round'));
    }

    _printPerRound(rounds);
    _printPhases(rounds);
    _printOps(rounds);
    stdout.writeln('');
    _measureCpuWork(base.path);
    stdout.writeln('');
    await _measureIoPrimitives(base.path);
    stdout.writeln('');
    _measureWrapperOverhead();

    for (final round in rounds) {
      await round.dispose();
    }
    try {
      await base.delete(recursive: true);
    } on FileSystemException {
      // Leaving a temp directory behind is harmless.
    }
    // Read the sink so the replayed CPU work above is not optimised away.
    stdout.writeln('sink: $_sink');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// One measured `clean()` run over [_fileCount] files of [_fileSize] bytes.
class _Round {
  _Round(this.label, this.items, this.timing);

  final String label;
  final int items;
  final _TimingFileSystem timing;

  Future<void> dispose() async {
    try {
      await Directory(timing.dataDir).delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }
}

Future<_Round> _runCleanRound(Directory base, String label) async {
  final dataDir = p.windows.join(base.path, label, 'data');
  await Directory(dataDir).create(recursive: true);
  final quarantineRoot = p.windows.join(base.path, label, 'quarantine');

  final random = Random(7);
  final payload = List<int>.generate(_fileSize, (_) => random.nextInt(256));
  final items = <JunkItem>[];
  for (var index = 0; index < _fileCount; index++) {
    final path = p.windows.join(dataDir, 'cache_entry_$index.tmp');
    final file = File(path);
    await file.writeAsBytes(payload, flush: false);
    final stat = await file.stat();
    items.add(
      JunkItem(
        ruleId: 'attr-rule',
        rootPath: PathGuard.normalize(dataDir),
        path: path,
        size: _fileSize,
        modified: stat.modified,
      ),
    );
  }

  final timing = _TimingFileSystem(const IoFileSystem(), dataDir);
  final service = QuarantineService(
    quarantineRoot: quarantineRoot,
    guard: PathGuard.forWindows(),
    metadataAccess: const LocalFileMetadataAccess(),
    exclusions: const EmptyPathExclusionSource(),
    fileSystem: timing,
  );

  // Let the runtime settle after creating the files.
  await Future<void>.delayed(const Duration(milliseconds: 150));

  var progressCalls = 0;
  timing.begin();
  final report = await service.clean(items, onProgress: (_) => progressCalls++);
  timing.end();

  expect(report.movedCount, _fileCount);
  expect(report.failureCount, 0);
  timing.progressCalls = progressCalls;
  stdout.writeln(
    '$label: ${(timing.totalMicros / _fileCount).toStringAsFixed(1)} µs/file '
    '(${timing.totalMicros} µs total, '
    '${(progressCalls / _fileCount).toStringAsFixed(3)} progress/file)',
  );
  return _Round(label, _fileCount, timing);
}

void _printPerRound(List<_Round> rounds) {
  final micros = [
    for (final round in rounds) round.timing.totalMicros / round.items,
  ];
  final mean = micros.reduce((a, b) => a + b) / micros.length;
  final low = micros.reduce((a, b) => a < b ? a : b);
  final high = micros.reduce((a, b) => a > b ? a : b);
  stdout.writeln('');
  stdout.writeln(
    '=== 端到端：均值 ${mean.toStringAsFixed(1)} µs/file'
    '（最小 ${low.toStringAsFixed(1)} / 最大 ${high.toStringAsFixed(1)}）===',
  );
}

void _printPhases(List<_Round> rounds) {
  stdout.writeln('');
  stdout.writeln('=== 分阶段（均值 µs/file）===');
  stdout.writeln(
    '${'phase'.padRight(18)}${'wall'.padLeft(10)}'
    '${'syscalls'.padLeft(11)}${'residual'.padLeft(11)}',
  );
  var total = 0.0;
  for (final phase in _TimingFileSystem.phaseNames) {
    var wall = 0.0;
    var ops = 0.0;
    for (final round in rounds) {
      final timing = round.timing;
      wall += timing.phaseWallMicros(phase) / round.items;
      ops += timing.phaseOpsMicros(phase) / round.items;
    }
    wall /= rounds.length;
    ops /= rounds.length;
    total += wall;
    stdout.writeln(
      '${phase.padRight(18)}${wall.toStringAsFixed(1).padLeft(10)}'
      '${ops.toStringAsFixed(1).padLeft(11)}'
      '${(wall - ops).toStringAsFixed(1).padLeft(11)}',
    );
  }
  stdout.writeln(
    '${'total'.padRight(18)}${total.toStringAsFixed(1).padLeft(10)}',
  );
}

void _printOps(List<_Round> rounds) {
  stdout.writeln('');
  stdout.writeln('=== 系统调用明细（均值 µs/file，按成本排序）===');
  stdout.writeln(
    '${'operation'.padRight(26)}${'calls'.padLeft(9)}'
    '${'µs/file'.padLeft(10)}${'of total'.padLeft(11)}',
  );
  final totals = <String, ({int calls, double micros})>{};
  var totalMicros = 0.0;
  for (final round in rounds) {
    totalMicros += round.timing.totalMicros / round.items;
    for (final entry in round.timing.opTotals().entries) {
      final previous = totals[entry.key];
      totals[entry.key] = (
        calls: (previous?.calls ?? 0) + entry.value.calls,
        micros: (previous?.micros ?? 0) + entry.value.micros / round.items,
      );
    }
  }
  totalMicros /= rounds.length;
  final rows = totals.entries.toList()
    ..sort((a, b) => b.value.micros.compareTo(a.value.micros));
  var accounted = 0.0;
  for (final row in rows) {
    final micros = row.value.micros / rounds.length;
    accounted += micros;
    stdout.writeln(
      '${row.key.padRight(26)}'
      '${(row.value.calls / (rounds.length * _fileCount)).toStringAsFixed(2).padLeft(9)}'
      '${micros.toStringAsFixed(1).padLeft(10)}'
      '${'${(micros / totalMicros * 100).toStringAsFixed(1)}%'.padLeft(11)}',
    );
  }
  stdout.writeln(
    '${'非系统调用（CPU/分配/调度）'.padRight(26)}${''.padLeft(9)}'
    '${(totalMicros - accounted).toStringAsFixed(1).padLeft(10)}'
    '${'${((totalMicros - accounted) / totalMicros * 100).toStringAsFixed(1)}%'.padLeft(11)}',
  );
  stdout.writeln(
    '${'total'.padRight(26)}${''.padLeft(9)}'
    '${totalMicros.toStringAsFixed(1).padLeft(10)}${'100.0%'.padLeft(11)}',
  );
}

/// Replays the loop's non-filesystem work to split the residual.
void _measureCpuWork(String base) {
  final root = p.windows.join(base, 'cpu', 'data');
  final path = p.windows.join(root, 'cache_entry_0.tmp');
  final rootKey = PathGuard.normalize(root);
  final guard = PathGuard.forWindows();
  final quarantineRoot = p.windows.join(base, 'cpu', 'quarantine');
  final filesDir = p.windows.join(quarantineRoot, 'session', 'files');
  final bytes = List<int>.generate(_fileSize, (i) => i & 0xff);
  final modified = DateTime.now();

  stdout.writeln('=== 残余部分的 CPU 归因（单次操作，热缓存）===');
  _bench('guard.allows', 20000, () {
    _sink = guard.allows(path: path, root: rootKey) ? 1 : 0;
  });
  _bench('exclusions.excludes', 20000, () {
    _sink = const EmptyPathExclusionSource().excludes(path) ? 1 : 0;
  });
  _bench('shouldCaptureAcl', 20000, () {
    _sink = shouldCaptureAcl(path, quarantineRoot) ? 1 : 0;
  });
  _bench('PathGuard.normalize x2', 20000, () {
    _sink = (PathGuard.normalize(path) + PathGuard.normalize(quarantineRoot))
        .length;
  });
  _bench('_storedName (RegExp per call)', 20000, () {
    var name = p.windows.basename(path);
    name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    if (name.length > 80) name = name.substring(0, 80);
    _sink = '${'123456'.padLeft(6, '0')}_$name'.length;
  });
  _bench('p.windows.join(dest)', 20000, () {
    _sink = p.windows.join(filesDir, '123456_cache_entry_0.tmp').length;
  });
  _bench('DateTime ISO x3', 20000, () {
    _sink =
        modified.toUtc().toIso8601String().length +
        modified.toUtc().toIso8601String().length +
        modified.toUtc().toIso8601String().length;
  });
  final entry = <String, Object?>{
    'originalPath': path,
    'rootPath': root,
    'storedName': '123456_cache_entry_0.tmp',
    'size': _fileSize,
    'sha256': 'a' * 64,
    'modified': modified.toUtc().toIso8601String(),
    'ruleId': 'attr-rule',
    'created': modified.toUtc().toIso8601String(),
    'accessed': modified.toUtc().toIso8601String(),
    'readOnly': false,
    'aclUnavailable': false,
  };
  _bench('map + jsonEncode (undo entry)', 20000, () {
    final copy = <String, Object?>{
      'originalPath': entry['originalPath'],
      'rootPath': entry['rootPath'],
      'storedName': entry['storedName'],
      'size': entry['size'],
      'sha256': entry['sha256'],
      'modified': entry['modified'],
      'ruleId': entry['ruleId'],
      'created': entry['created'],
      'accessed': entry['accessed'],
      'readOnly': entry['readOnly'],
      'aclUnavailable': entry['aclUnavailable'],
    };
    _sink = jsonEncode(copy).length;
  });
  _bench('map + jsonEncode (plan line)', 20000, () {
    final line = {
      'originalPath': path,
      'rootPath': root,
      'ruleId': 'attr-rule',
      'size': _fileSize,
      'modified': modified.toUtc().toIso8601String(),
    };
    _sink = jsonEncode(line).length;
  });
  final encoded = jsonEncode(entry);
  _bench('utf8.encode(json)', 20000, () {
    _sink = utf8.encode(encoded).length;
  });
  _bench('sha256(1024 B)', 20000, () {
    _sink = sha256.convert(bytes).bytes.length;
  });
  _bench('progress + DateTime.now', 20000, () {
    // Mirrors report(): a clock read plus an outbound callback.
    final now = DateTime.now();
    _sink = now.microsecondsSinceEpoch & 1;
  });
}

/// Decomposes the two dominant file operations the loop performs.
Future<void> _measureIoPrimitives(String base) async {
  stdout.writeln('=== 文件操作拆解（真实 I/O，$_fileSize B 文件）===');
  final probeDir = Directory(p.windows.join(base, 'probe'));
  await probeDir.create(recursive: true);
  final probe = File(p.windows.join(probeDir.path, 'probe.bin'));
  await probe.writeAsBytes(
    List<int>.generate(_fileSize, (i) => i & 0xff),
    flush: false,
  );

  await _measureAsync('stat', 300, () async {
    _sink = (await FileStat.stat(probe.path)).size;
  });
  await _measureAsync('readAsBytes (open+read+close)', 300, () async {
    _sink = (await probe.readAsBytes()).length;
  });
  await _measureAsync('open + close (no read)', 300, () async {
    final handle = await probe.open();
    await handle.close();
    _sink = 1;
  });
  await _measureAsync('open + read + close', 300, () async {
    final handle = await probe.open();
    final bytes = await handle.read(_fileSize);
    await handle.close();
    _sink = bytes.length;
  });
  await _measureAsync('openRead().fold (stream)', 300, () async {
    _sink = await probe.openRead().fold<int>(
      0,
      (sum, chunk) => sum + chunk.length,
    );
  });
  await _measureAsync('type(followLinks: false)', 300, () async {
    _sink =
        (await FileSystemEntity.type(probe.path, followLinks: false)) ==
            FileSystemEntityType.file
        ? 1
        : 0;
  });

  // Repeated after the first pass so a cache or ordering effect shows up as a
  // difference between two readings of the same call, rather than being read
  // as a real gap between two APIs.
  stdout.writeln('--- 复测（与首轮顺序相反）---');
  await _measureAsync('readAsBytes (repeat)', 300, () async {
    _sink = (await probe.readAsBytes()).length;
  });
  await _measureAsync('open + read + close (repeat)', 300, () async {
    final handle = await probe.open();
    final bytes = await handle.read(_fileSize);
    await handle.close();
    _sink = bytes.length;
  });

  // Journal writer primitives: is position() an extra system call?
  final journalPath = p.windows.join(probeDir.path, 'journal.jsonl');
  final journalHandle = await File(journalPath).open(mode: FileMode.append);
  await _measureAsync('journal position()', 300, () async {
    _sink = await journalHandle.position();
  });
  await _measureAsync('journal writeString(260 B)', 300, () async {
    await journalHandle.writeString('${'x' * 260}\n');
    _sink = 1;
  });
  await _measureAsync('journal flush()', 300, () async {
    await journalHandle.flush();
    _sink = 1;
  });
  await journalHandle.close();

  // Same-volume rename of a real payload file.
  final renameDir = Directory(p.windows.join(base, 'rename'));
  await renameDir.create(recursive: true);
  final payload = List<int>.generate(_fileSize, (i) => i & 0xff);
  const total = 200;
  final pending = <(String, String)>[];
  for (var index = 0; index < total; index++) {
    final source = p.windows.join(renameDir.path, 'src_$index.tmp');
    File(source).writeAsBytesSync(payload);
    pending.add((source, p.windows.join(renameDir.path, 'dst_$index.tmp')));
  }
  final renameWatch = Stopwatch()..start();
  for (final pair in pending) {
    File(pair.$1).renameSync(pair.$2);
  }
  renameWatch.stop();
  stdout.writeln(
    '${'rename (tight loop, sync)'.padRight(34)}'
    '${(renameWatch.elapsedMicroseconds / total).toStringAsFixed(1).padLeft(10)}'
    ' µs',
  );
}

Future<void> _measureAsync(
  String label,
  int iterations,
  Future<void> Function() body,
) async {
  for (var index = 0; index < 20; index++) {
    await body();
  }
  final stopwatch = Stopwatch()..start();
  for (var index = 0; index < iterations; index++) {
    await body();
  }
  stopwatch.stop();
  stdout.writeln(
    '${label.padRight(34)}'
    '${(stopwatch.elapsedMicroseconds / iterations).toStringAsFixed(1).padLeft(10)}'
    ' µs',
  );
}

var _sink = 0;

void _bench(String label, int iterations, void Function() body) {
  for (var index = 0; index < 200; index++) {
    body();
  }
  final stopwatch = Stopwatch()..start();
  for (var index = 0; index < iterations; index++) {
    body();
  }
  stopwatch.stop();
  final micros = stopwatch.elapsedMicroseconds / iterations;
  stdout.writeln(
    '${label.padRight(34)}${micros.toStringAsFixed(2).padLeft(10)} µs',
  );
}

/// Cost of the timing decorator itself, so the tables can be read honestly.
void _measureWrapperOverhead() {
  final timing = _TimingFileSystem(const IoFileSystem(), '');
  final stopwatch = Stopwatch()..start();
  for (var index = 0; index < 20000; index++) {
    timing.bookkeepingProbe();
  }
  stopwatch.stop();
  final micros = stopwatch.elapsedMicroseconds / 20000;
  stdout.writeln('=== 装饰器自身开销 ===');
  stdout.writeln(
    '${'Stopwatch + record bookkeeping'.padRight(34)}'
    '${micros.toStringAsFixed(2).padLeft(10)} µs/call',
  );
  stdout.writeln(
    '每文件约 8 次系统调用，装饰器合计约 '
    '${(micros * 8).toStringAsFixed(1)} µs/file',
  );
  _sink = timing.opTotals().length;
}

class _OpCall {
  _OpCall(this.name, this.startTicks, this.ticks);

  final String name;
  final int startTicks;
  final int ticks;
}

class _TimingFileSystem implements BroomFileSystem {
  _TimingFileSystem(this.inner, this.dataDir);

  final BroomFileSystem inner;
  final String dataDir;
  final List<_OpCall> calls = [];
  final Stopwatch watch = Stopwatch();
  int progressCalls = 0;
  int totalMicros = 0;

  int _firstMoveTicks = -1;
  int _lastMoveEndTicks = -1;

  static const phaseNames = <String>[
    'setup + plan',
    'per-file loop',
    'finalize',
  ];

  void begin() {
    calls.clear();
    _firstMoveTicks = -1;
    _lastMoveEndTicks = -1;
    watch
      ..reset()
      ..start();
  }

  void end() {
    watch.stop();
    totalMicros = watch.elapsedMicroseconds;
  }

  int get frequency => watch.frequency;

  Future<T> _time<T>(String name, Future<T> Function() body) async {
    final start = watch.elapsedTicks;
    final stopwatch = Stopwatch()..start();
    try {
      return await body();
    } finally {
      stopwatch.stop();
      calls.add(_OpCall(name, start, stopwatch.elapsedTicks));
    }
  }

  void bookkeepingProbe() {
    final start = watch.elapsedTicks;
    final stopwatch = Stopwatch()..start();
    stopwatch.stop();
    calls.add(_OpCall('probe', start, stopwatch.elapsedTicks));
  }

  /// Wall time of a phase in µs: setup runs to the first payload move, the
  /// loop spans the payload moves, finalize is everything after the last one.
  double phaseWallMicros(String phase) {
    final total = watch.elapsedTicks;
    final boundaries = _boundaries;
    final (from, to) = switch (phase) {
      'setup + plan' => (0, boundaries.$1),
      'per-file loop' => (boundaries.$1, boundaries.$2),
      _ => (boundaries.$2, total),
    };
    return (to - from) * 1000000 / frequency;
  }

  double phaseOpsMicros(String phase) {
    final boundaries = _boundaries;
    var ticks = 0;
    for (final call in calls) {
      final isSetup = call.startTicks < boundaries.$1;
      final isLoop =
          call.startTicks >= boundaries.$1 && call.startTicks < boundaries.$2;
      final match = phase == 'setup + plan'
          ? isSetup
          : phase == 'per-file loop'
          ? isLoop
          : !isSetup && !isLoop;
      if (match) ticks += call.ticks;
    }
    return ticks * 1000000 / frequency;
  }

  (int, int) get _boundaries {
    final first = _firstMoveTicks < 0 ? watch.elapsedTicks : _firstMoveTicks;
    final last = _lastMoveEndTicks < 0 ? watch.elapsedTicks : _lastMoveEndTicks;
    return (first, last);
  }

  Map<String, ({int calls, double micros})> opTotals() {
    final totals = <String, ({int calls, double micros})>{};
    for (final call in calls) {
      final previous = totals[call.name];
      totals[call.name] = (
        calls: (previous?.calls ?? 0) + 1,
        micros: (previous?.micros ?? 0) + call.ticks * 1000000 / frequency,
      );
    }
    return totals;
  }

  @override
  Future<FsEntityType> type(String path) =>
      _time('type (metadata probe)', () => inner.type(path));

  @override
  Future<FsStat> stat(String path) => _time('stat', () => inner.stat(path));

  @override
  Stream<FsEntry> list(String path) => inner.list(path);

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) => _time(
    'createDirectory',
    () => inner.createDirectory(path, recursive: recursive),
  );

  @override
  Future<String> readString(String path) =>
      _time('readString (session json)', () => inner.readString(path));

  @override
  Future<List<String>> readLines(String path) =>
      _time('readLines (plan/journal)', () => inner.readLines(path));

  @override
  Future<List<int>> readBytes(String path) =>
      _time('readBytes (integrity hash)', () => inner.readBytes(path));

  @override
  Future<void> writeString(
    String path,
    String contents, {
    bool append = false,
    bool flush = true,
  }) => _time(
    'writeString (session json)',
    () => inner.writeString(path, contents, append: append, flush: flush),
  );

  @override
  Future<FsFileWriter> openAppend(String path) async {
    final writer = await _time('openAppend', () => inner.openAppend(path));
    return _TimingWriter(writer, this);
  }

  @override
  Future<FsFileWriter> openWrite(String path) async {
    final writer = await _time('openWrite (plan)', () => inner.openWrite(path));
    return _TimingWriter(writer, this);
  }

  @override
  Future<void> rename(String from, String to) async {
    final isPayload = _isMoveTarget(to);
    if (isPayload && _firstMoveTicks < 0) _firstMoveTicks = watch.elapsedTicks;
    await _time(
      isPayload ? 'rename (move to quarantine)' : 'rename (session json)',
      () => inner.rename(from, to),
    );
    if (isPayload) _lastMoveEndTicks = watch.elapsedTicks;
  }

  bool _isMoveTarget(String path) => path.contains(r'\files\');

  @override
  Future<void> copy(String from, String to) =>
      _time('copy (cross-volume)', () => inner.copy(from, to));

  @override
  Future<void> deleteFile(String path) =>
      _time('deleteFile', () => inner.deleteFile(path));

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) => _time(
    'deleteDirectory',
    () => inner.deleteDirectory(path, recursive: recursive),
  );

  @override
  Future<int> length(String path) => _time('length', () => inner.length(path));
}

class _TimingWriter implements FsFileWriter {
  _TimingWriter(this.inner, this.owner);

  final FsFileWriter inner;
  final _TimingFileSystem owner;

  @override
  Future<int> position() => owner._time('journal position()', inner.position);

  @override
  Future<void> setPosition(int position) =>
      owner._time('journal setPosition', () => inner.setPosition(position));

  @override
  Future<void> writeString(String contents) => owner._time(
    'journal/plan writeString',
    () => inner.writeString(contents),
  );

  @override
  Future<void> flush() => owner._time('journal/plan flush', inner.flush);

  @override
  Future<void> truncate(int length) =>
      owner._time('journal truncate', () => inner.truncate(length));

  @override
  Future<void> close() => owner._time('writer close', inner.close);
}
