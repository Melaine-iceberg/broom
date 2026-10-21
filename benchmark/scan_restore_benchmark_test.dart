// Restore-side A/B benchmark for docs/perf-review.md (candidate optimization
// after P0-2).
//
// Current restore parses `items.jsonl` on the calling isolate; on desktop that
// is the UI isolate. This benchmark writes a real result file through
// `ScanResultWriter`, warms the OS cache, and compares:
//
//   main    - `ScanResultStore.load()` as shipped
//   isolate - the same schema decoded in a background isolate, streamed back
//             in batches so the main isolate only pays message handling
//
// Run manually; `flutter test` only scans `test/`, so this never runs in CI:
//
//   flutter test benchmark/scan_restore_benchmark_test.dart
//
// The generated result files live under the system temporary directory and are
// removed afterwards.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/scan/scan_result_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _sizes = [100000, 1000000];
const _rounds = 3;
const _writeBatchSize = 2048;
const _isolateBatchSize = 4096;
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

void main() {
  test('restore parse A/B', () async {
    final base = await Directory.systemTemp.createTemp('broom_restore_bench_');
    try {
      for (final count in _sizes) {
        final store = ScanResultStore(
          rootDirectory: p.windows.join(base.path, 's$count'),
          semantics: const WindowsPathSemantics(),
        );
        final setup = Stopwatch()..start();
        final summary = await _writeResult(store, count);
        setup.stop();
        final file = File(
          p.windows.join(store.rootDirectory, summary.id, 'items.jsonl'),
        );
        final mib = file.lengthSync() / (1024 * 1024);
        stdout.writeln('');
        stdout.writeln(
          'RESTORE [$count items, ${mib.toStringAsFixed(1)} MiB, '
          'setup ${setup.elapsedMilliseconds} ms]',
        );

        // Measure parsing, not first-touch disk reads.
        await file.openRead().drain<void>();

        final main = <Duration>[];
        final isolate = <Duration>[];
        final isolateMain = <Duration>[];
        final isolateWorker = <Duration>[];
        for (var round = 0; round < _rounds; round++) {
          final mainsFirst = round.isEven;
          for (final kind
              in mainsFirst ? ['main', 'isolate'] : ['isolate', 'main']) {
            final stopwatch = Stopwatch()..start();
            if (kind == 'main') {
              final data = await store.load(summary);
              stopwatch.stop();
              _expectCount(data?.items.length, count, 'main');
              main.add(stopwatch.elapsed);
            } else {
              final result = await _parseInIsolate(file.path);
              stopwatch.stop();
              _expectCount(result.items, count, 'isolate');
              isolate.add(stopwatch.elapsed);
              isolateMain.add(result.mainReceive);
              isolateWorker.add(result.workerParse);
            }
          }
        }

        final mainMedian = _median(main);
        final isolateMedian = _median(isolate);
        final isolateMainMedian = _median(isolateMain);
        final workerMedian = _median(isolateWorker);
        final outsideWorker = isolateMedian - workerMedian;
        stdout.writeln('  main isolate load : ${_ms(mainMedian)} (current)');
        stdout.writeln(
          '  isolate parse     : ${_ms(isolateMedian)} total '
          '(${(isolateMedian.inMicroseconds / mainMedian.inMicroseconds * 100).toStringAsFixed(0)}% '
          'of current)',
        );
        stdout.writeln('    worker read+decode : ${_ms(workerMedian)}');
        stdout.writeln(
          '    outside worker     : ${_ms(outsideWorker)} '
          '(transfer, deserialize, scheduling)',
        );
        stdout.writeln(
          '    main receive callback: ${_ms(isolateMainMedian)} '
          '(list append only; deserialization happens before the callback)',
        );
        final transferOnly = _median([
          await _measureReceiveOnly(count),
          await _measureReceiveOnly(count),
        ]);
        stdout.writeln(
          '    receive-only upper bound: ${_ms(transferOnly)} '
          '(send + deserialize + append, no parsing)',
        );
      }
    } finally {
      try {
        await base.delete(recursive: true);
      } on FileSystemException {
        // Leaving a temp directory behind is harmless.
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}

Future<StoredScanSummary> _writeResult(ScanResultStore store, int count) async {
  final roots = ScanRoots([
    for (final ruleId in _ruleIds)
      ScanRoot(
        ruleId: ruleId,
        rootPath: p.windows.join(
          r'C:\Users\Bench\AppData\Local\Temp\cache',
          ruleId.replaceAll('.', '_'),
        ),
      ),
  ]);
  final writer = await store.begin(
    ruleIds: _ruleIds,
    rulesVersion: 'bench',
    roots: roots,
  );
  final baseTime = DateTime.utc(2026, 10, 1);
  var foundBytes = 0;
  final batch = <JunkItem>[];
  for (var index = 0; index < count; index++) {
    final rootIndex = index % roots.length;
    final root = roots.at(rootIndex);
    final size = (index * 7919) % 1048576 + 128;
    foundBytes += size;
    batch.add(
      JunkItem(
        rootIndex: rootIndex,
        path: p.windows.join(
          root.rootPath,
          'd${(index ~/ 4096) % 64}',
          'file${index.toString().padLeft(10, '0')}.tmp',
        ),
        size: size,
        modifiedMicros: baseTime
            .add(Duration(seconds: index % 86400))
            .microsecondsSinceEpoch,
      ),
    );
    if (batch.length < _writeBatchSize) continue;
    await writer.addItems(batch);
    batch.clear();
  }
  if (batch.isNotEmpty) await writer.addItems(batch);
  return writer.complete(
    scannedFiles: count * 2,
    foundFiles: count,
    foundBytes: foundBytes,
    issueCount: 0,
    errorCounts: const {},
    truncated: false,
  );
}

Future<({int items, Duration mainReceive, Duration workerParse})>
_parseInIsolate(String path) async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn(_restoreWorker, ready.sendPort);
  final control = await ready.first as SendPort;
  ready.close();

  final replies = ReceivePort();
  final done = Completer<int>();
  final items = <JunkItem>[];
  var mainMicros = 0;
  var workerMicros = 0;
  final subscription = replies.listen((message) {
    final stopwatch = Stopwatch()..start();
    switch (message) {
      case _Batch(:final batch):
        items.addAll(batch);
      case _Done(:final itemCount, :final parseMicros):
        workerMicros = parseMicros;
        if (!done.isCompleted) done.complete(itemCount);
      case _WorkerError(:final message):
        if (!done.isCompleted) done.completeError(StateError(message));
    }
    mainMicros += stopwatch.elapsedMicroseconds;
  });

  try {
    control.send(_Request(path, replies.sendPort));
    final itemCount = await done.future;
    if (itemCount != items.length) {
      throw StateError('worker=$itemCount received=${items.length}');
    }
    return (
      items: items.length,
      mainReceive: Duration(microseconds: mainMicros),
      workerParse: Duration(microseconds: workerMicros),
    );
  } finally {
    await subscription.cancel();
    replies.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

/// Upper bound on what the main isolate pays when items come back from a
/// worker: the worker only serializes prebuilt items, so the time is transfer
/// + deserialization + the receiving list append.
Future<Duration> _measureReceiveOnly(int count) async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn(_sendOnlyWorker, ready.sendPort);
  final control = await ready.first as SendPort;
  ready.close();

  final replies = ReceivePort();
  final done = Completer<void>();
  final items = <JunkItem>[];
  final subscription = replies.listen((message) {
    switch (message) {
      case _Batch(:final batch):
        items.addAll(batch);
      case _Done():
        if (!done.isCompleted) done.complete();
      case _WorkerError(:final message):
        if (!done.isCompleted) done.completeError(StateError(message));
    }
  });
  final stopwatch = Stopwatch()..start();
  try {
    control.send(_SendOnly(count, replies.sendPort));
    await done.future;
    stopwatch.stop();
    if (items.length != count) {
      throw StateError('received=${items.length} expected=$count');
    }
    return stopwatch.elapsed;
  } finally {
    await subscription.cancel();
    replies.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _sendOnlyWorker(SendPort ready) async {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  await for (final message in inbox) {
    if (message is! _SendOnly) continue;
    try {
      final sample = [
        for (var index = 0; index < _isolateBatchSize; index++)
          JunkItem(
            rootIndex: 0,
            path:
                'C:\\Users\\Bench\\AppData\\Local\\Temp\\cache\\'
                'file${index.toString().padLeft(10, '0')}.tmp',
            size: 4096,
            modifiedMicros: 1759276800000000,
          ),
      ];
      var sent = 0;
      while (sent < message.count) {
        final remaining = message.count - sent;
        final take = remaining < sample.length ? remaining : sample.length;
        message.reply.send(
          _Batch(take == sample.length ? sample : sample.sublist(0, take)),
        );
        sent += take;
      }
      message.reply.send(_Done(message.count, 0));
    } catch (error) {
      message.reply.send(_WorkerError('$error'));
    }
  }
}

Future<void> _restoreWorker(SendPort ready) async {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  await for (final message in inbox) {
    if (message is! _Request) continue;
    try {
      final roots = <ScanRoot>[];
      final rootIndexes = <String, int>{};
      var count = 0;
      var batch = <JunkItem>[];
      final parse = Stopwatch()..start();
      await for (final line in File(
        message.path,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
        final item = _decodeItem(line, roots, rootIndexes);
        if (item == null) continue;
        count++;
        batch.add(item);
        if (batch.length < _isolateBatchSize) continue;
        message.reply.send(_Batch(batch));
        batch = <JunkItem>[];
      }
      if (batch.isNotEmpty) message.reply.send(_Batch(batch));
      parse.stop();
      message.reply.send(_Done(count, parse.elapsedMicroseconds));
    } catch (error) {
      message.reply.send(_WorkerError('$error'));
    }
  }
}

/// Mirrors `ScanResultStore._decodeItem`; keep the two in sync.
JunkItem? _decodeItem(
  String line,
  List<ScanRoot> roots,
  Map<String, int> rootIndexes,
) {
  if (line.trim().isEmpty) return null;
  try {
    final value = jsonDecode(line);
    if (value is! Map<String, dynamic>) return null;
    final path = value['path'];
    final rootPath = value['rootPath'];
    final ruleId = value['ruleId'];
    final size = value['size'];
    final modified = value['modified'];
    if (path is! String ||
        rootPath is! String ||
        ruleId is! String ||
        size is! int ||
        modified is! String) {
      return null;
    }
    final time = DateTime.tryParse(modified);
    if (time == null) return null;
    final rootIndex = rootIndexes.putIfAbsent('$ruleId\u0000$rootPath', () {
      roots.add(ScanRoot(ruleId: ruleId, rootPath: rootPath));
      return roots.length - 1;
    });
    return JunkItem(
      rootIndex: rootIndex,
      path: path,
      size: size,
      modifiedMicros: time.microsecondsSinceEpoch,
    );
  } on FormatException {
    return null;
  }
}

void _expectCount(int? actual, int expected, String label) {
  if (actual != expected) {
    throw StateError('$label parsed=$actual expected=$expected');
  }
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

String _ms(Duration value) => '${value.inMilliseconds} ms';

class _Request {
  _Request(this.path, this.reply);

  final String path;
  final SendPort reply;
}

class _SendOnly {
  _SendOnly(this.count, this.reply);

  final int count;
  final SendPort reply;
}

class _Batch {
  _Batch(this.batch);

  final List<JunkItem> batch;
}

class _Done {
  _Done(this.itemCount, this.parseMicros);

  final int itemCount;
  final int parseMicros;
}

class _WorkerError {
  _WorkerError(this.message);

  final String message;
}
