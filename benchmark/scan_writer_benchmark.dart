// Scan writer benchmark (P2-12 in docs/perf-review.md).
//
// Drives the real `ScanResultStore` / `ScanResultWriter` pipeline: every
// append is encoded and written inside its writer isolate.
//
// Before P2-12 the worker flushed the IOSink once per append, so the append
// batch size directly controlled flush frequency. Comparing the production
// 256-item boundary with a much larger batch isolates the cost of those
// flushes; after P2-12 the worker batches flushes by bytes and both rows
// should converge.
//
// The second table writes pre-encoded lines straight to an IOSink. It
// separates sink and flush cost from JSON encoding and isolate transfer,
// which dominate the end-to-end writer on a local disk.
//
// Run from the project root:
//   dart run benchmark/scan_writer_benchmark.dart
//   dart run benchmark/scan_writer_benchmark.dart --items=1000000
//
// Result files are created under the system temporary directory and removed
// afterwards.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/scan/scan_result_store.dart';
import 'package:path/path.dart' as p;

const _defaultItems = 100000;
const _rounds = 3;
// 256 is `ScanOptions.batchSize`, the batch handed from the scan pipeline to
// the writer. 8192 approximates a writer that only flushes on bytes.
const _batchSizes = [256, 8192];
const _ruleIds = [
  'browser.chrome',
  'browser.edge',
  'dev.dart',
  'app.temp',
  'system.cache',
  'logs.app',
  'thumbnails.cache',
  'gpu.shader',
];

void main(List<String> args) async {
  final itemCount = _intArg(args, '--items') ?? _defaultItems;
  final base = await Directory.systemTemp.createTemp('broom_writer_bench_');
  stdout.writeln('Broom scan writer benchmark');
  stdout.writeln(
    'Dart ${Platform.version.split(' ').first}, '
    '${Platform.numberOfProcessors} logical processors, '
    '$itemCount items',
  );
  stdout.writeln('');

  try {
    final samples = <int, List<_Sample>>{
      for (final batchSize in _batchSizes) batchSize: <_Sample>[],
    };
    for (var round = 0; round < _rounds; round++) {
      final order = round.isEven ? _batchSizes : _batchSizes.reversed.toList();
      for (final batchSize in order) {
        final sample = await _write(
          base: base,
          runName: 'r${round}_b$batchSize',
          itemCount: itemCount,
          batchSize: batchSize,
        );
        samples[batchSize]!.add(sample);
      }
    }

    stdout.writeln(
      '${'append batch'.padLeft(13)} '
      '${'median'.padLeft(10)} '
      '${'µs/item'.padLeft(8)} '
      '${'MiB/s'.padLeft(8)} '
      '${'appends'.padLeft(8)}',
    );
    for (final batchSize in _batchSizes) {
      final values = samples[batchSize]!;
      final median = _median(values.map((sample) => sample.elapsed).toList());
      final bytes = values.first.fileBytes;
      final appends = (itemCount + batchSize - 1) ~/ batchSize;
      final microsecondsPerItem =
          median.inMicroseconds / values.first.itemsWritten;
      final mibPerSecond =
          bytes / (1024 * 1024) / (median.inMicroseconds / 1000000);
      stdout.writeln(
        '${'$batchSize items'.padLeft(13)} '
        '${'${median.inMilliseconds} ms'.padLeft(10)} '
        '${microsecondsPerItem.toStringAsFixed(2).padLeft(8)} '
        '${mibPerSecond.toStringAsFixed(0).padLeft(8)} '
        '${appends.toString().padLeft(8)}',
      );
    }

    stdout.writeln('');
    await _flushProbe(base: base, lineCount: itemCount);
  } finally {
    try {
      await base.delete(recursive: true);
    } on FileSystemException {
      // Leaving a temp directory behind is harmless.
    }
  }
}

Future<_Sample> _write({
  required Directory base,
  required String runName,
  required int itemCount,
  required int batchSize,
}) async {
  final store = ScanResultStore(
    rootDirectory: p.join(base.path, runName),
    semantics: const WindowsPathSemantics(),
  );
  final roots = ScanRoots([
    for (final ruleId in _ruleIds)
      ScanRoot(
        ruleId: ruleId,
        rootPath: p.join(
          r'C:\Users\Bench\AppData\Local\Temp\cache',
          ruleId.replaceAll('.', '_'),
        ),
      ),
  ]);
  final baseTime = DateTime.utc(2026, 10, 1);
  final stopwatch = Stopwatch()..start();
  final writer = await store.begin(
    ruleIds: _ruleIds,
    rulesVersion: 'bench',
    roots: roots,
  );
  final batch = <JunkItem>[];
  var foundBytes = 0;
  for (var index = 0; index < itemCount; index++) {
    final rootIndex = index % roots.length;
    final size = (index * 7919) % 1048576 + 128;
    foundBytes += size;
    batch.add(
      JunkItem(
        rootIndex: rootIndex,
        path: p.join(
          roots.at(rootIndex).rootPath,
          'd${(index ~/ 4096) % 64}',
          'file${index.toString().padLeft(10, '0')}.tmp',
        ),
        size: size,
        modifiedMicros: baseTime
            .add(Duration(seconds: index % 86400))
            .microsecondsSinceEpoch,
      ),
    );
    if (batch.length < batchSize) continue;
    await writer.addItems(batch);
    batch.clear();
  }
  if (batch.isNotEmpty) await writer.addItems(batch);
  final summary = await writer.complete(
    scannedFiles: itemCount * 2,
    foundFiles: itemCount,
    foundBytes: foundBytes,
    issueCount: 0,
    errorCounts: const {},
    truncated: false,
  );
  stopwatch.stop();
  final file = File(
    p.join(store.rootDirectory, summary.id, 'items.jsonl'),
  );
  final sample = _Sample(
    elapsed: stopwatch.elapsed,
    fileBytes: await file.length(),
    itemsWritten: summary.persistedItemCount,
  );
  await Directory(store.rootDirectory).delete(recursive: true);
  return sample;
}

Future<void> _flushProbe({
  required Directory base,
  required int lineCount,
}) async {
  final line = _encodedLine(0);
  final lineBytes = utf8.encode(line);
  final chunk256 = utf8.encode(List.filled(256, line).join());
  final chunk8192 = utf8.encode(List.filled(8192, line).join());
  const bufferBytes = 4 * 1024 * 1024;
  final configs = [
    _FlushConfig(
      label: '256/write+flush',
      linesPerWrite: 256,
      chunk: chunk256,
      flushEach: true,
      copyEachChunk: true,
    ),
    _FlushConfig(
      label: '256/4 MiB coalesced',
      linesPerWrite: 256,
      chunk: chunk256,
      coalesceBytes: bufferBytes,
    ),
    _FlushConfig(label: '256/one flush', linesPerWrite: 256, chunk: chunk256),
    _FlushConfig(
      label: '8192/write+flush',
      linesPerWrite: 8192,
      chunk: chunk8192,
      flushEach: true,
    ),
    _FlushConfig(
      label: '8192/one flush',
      linesPerWrite: 8192,
      chunk: chunk8192,
    ),
  ];
  final samples = <String, List<_RawSample>>{
    for (final config in configs) config.label: <_RawSample>[],
  };
  for (var round = 0; round < _rounds; round++) {
    for (final config in configs) {
      samples[config.label]!.add(
        await _writeRaw(
          base: base,
          round: round,
          config: config,
          lineCount: lineCount,
          line: line,
        ),
      );
    }
  }

  stdout.writeln(
    'raw IOSink, $lineCount lines × ${lineBytes.length} B '
    '($_rounds runs median)',
  );
  stdout.writeln(
    '${'policy'.padLeft(18)} '
    '${'wall'.padLeft(10)} '
    '${'flush'.padLeft(10)} '
    '${'calls'.padLeft(8)}',
  );
  for (final config in configs) {
    final values = samples[config.label]!;
    final wall = _median(values.map((sample) => sample.wall).toList());
    final flush = _median(values.map((sample) => sample.flush).toList());
    final calls = _medianInt(values.map((sample) => sample.flushes).toList());
    stdout.writeln(
      '${config.label.padLeft(18)} '
      '${'${wall.inMilliseconds} ms'.padLeft(10)} '
      '${'${flush.inMilliseconds} ms'.padLeft(10)} '
      '${calls.toString().padLeft(8)}',
    );
  }
  stdout.writeln(
    '${'encode only'.padLeft(18)} '
    '${'${_measureEncode(lineCount).inMilliseconds} ms'.padLeft(10)}',
  );
}

Future<_RawSample> _writeRaw({
  required Directory base,
  required int round,
  required _FlushConfig config,
  required int lineCount,
  required String line,
}) async {
  final file = File(
    p.join(
      base.path,
      'raw_${round}_${config.label.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.dat',
    ),
  );
  final sink = file.openWrite();
  final stopwatch = Stopwatch()..start();
  final flushWatch = Stopwatch();
  var flushMicros = 0;
  var flushes = 0;
  final coalesced = BytesBuilder(copy: false);
  Future<void> flushSink() async {
    flushWatch.reset();
    flushWatch.start();
    await sink.flush();
    flushWatch.stop();
    flushMicros += flushWatch.elapsedMicroseconds;
    flushes++;
  }

  for (var written = 0; written < lineCount;) {
    final count = math.min(lineCount - written, config.linesPerWrite);
    final bytes = count == config.linesPerWrite
        ? config.chunk
        : utf8.encode(List.filled(count, line).join());
    written += count;
    if (config.coalesceBytes > 0) {
      coalesced.add(bytes);
      if (coalesced.length < config.coalesceBytes) continue;
      sink.add(coalesced.takeBytes());
      await flushSink();
      continue;
    }
    if (config.copyEachChunk) {
      sink.add((BytesBuilder(copy: false)..add(bytes)).takeBytes());
    } else {
      sink.add(bytes);
    }
    if (!config.flushEach) continue;
    await flushSink();
  }
  if (coalesced.isNotEmpty) sink.add(coalesced.takeBytes());
  await flushSink();
  await sink.close();
  stopwatch.stop();
  await file.delete();
  return _RawSample(
    wall: stopwatch.elapsed,
    flush: Duration(microseconds: flushMicros),
    flushes: flushes,
  );
}

Duration _measureEncode(int lineCount) {
  final stopwatch = Stopwatch()..start();
  for (var index = 0; index < lineCount; index++) {
    utf8.encode(_encodedLine(index));
  }
  stopwatch.stop();
  return stopwatch.elapsed;
}

String _encodedLine(int index) {
  final rootIndex = index % _ruleIds.length;
  final ruleId = _ruleIds[rootIndex];
  final rootPath = p.join(
    r'C:\Users\Bench\AppData\Local\Temp\cache',
    ruleId.replaceAll('.', '_'),
  );
  final line = jsonEncode({
    'ruleId': ruleId,
    'rootPath': rootPath,
    'path': p.join(
      rootPath,
      'd${(index ~/ 4096) % 64}',
      'file${index.toString().padLeft(10, '0')}.tmp',
    ),
    'size': (index * 7919) % 1048576 + 128,
    'modified': DateTime.utc(
      2026,
      10,
      1,
    ).add(Duration(seconds: index % 86400)).toIso8601String(),
  });
  return '$line\n';
}

class _FlushConfig {
  const _FlushConfig({
    required this.label,
    required this.linesPerWrite,
    required this.chunk,
    this.flushEach = false,
    this.coalesceBytes = 0,
    this.copyEachChunk = false,
  });

  final String label;
  final int linesPerWrite;
  final List<int> chunk;
  final bool flushEach;
  final int coalesceBytes;
  final bool copyEachChunk;
}

class _RawSample {
  const _RawSample({
    required this.wall,
    required this.flush,
    required this.flushes,
  });

  final Duration wall;
  final Duration flush;
  final int flushes;
}

class _Sample {
  const _Sample({
    required this.elapsed,
    required this.fileBytes,
    required this.itemsWritten,
  });

  final Duration elapsed;
  final int fileBytes;
  final int itemsWritten;
}

int? _intArg(List<String> args, String name) {
  for (final arg in args) {
    if (!arg.startsWith('$name=')) continue;
    return int.tryParse(arg.substring(name.length + 1));
  }
  return null;
}

Duration _median(List<Duration> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return Duration(
    microseconds:
        (sorted[middle - 1].inMicroseconds + sorted[middle].inMicroseconds) ~/
        2,
  );
}

int _medianInt(List<int> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) ~/ 2;
}
