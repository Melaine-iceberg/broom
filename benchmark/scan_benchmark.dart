import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/scan/junk_scanner.dart';

import 'support/synthetic_tree_file_system.dart';

/// Scan, memory and isolate-transfer benchmarks.
///
/// Run from the project root:
///   dart run benchmark/scan_benchmark.dart
///   dart run benchmark/scan_benchmark.dart --million
///
/// The million-file scenario is opt-in because it deliberately stresses the
/// same in-memory path set the product keeps for de-duplication.
Future<void> main(List<String> args) async {
  final million = args.contains('--million');
  stdout.writeln('Broom performance benchmark');
  stdout.writeln(
    'Dart ${Platform.version.split(' ').first}, '
    '${Platform.numberOfProcessors} logical processors',
  );
  stdout.writeln('');

  await _benchmarkIsolateTransfer();
  stdout.writeln('');
  await _benchmarkScan(
    fileCount: 100000,
    retainItems: false,
    label: '100k streaming',
  );
  await _benchmarkScan(
    fileCount: 100000,
    retainItems: true,
    label: '100k retained',
  );
  if (million) {
    await _benchmarkScan(
      fileCount: 1000000,
      retainItems: false,
      label: '1M streaming',
    );
  } else {
    stdout.writeln(
      '1M scan skipped; pass --million to include it (expect a larger RSS).',
    );
  }
}

Future<void> _benchmarkScan({
  required int fileCount,
  required bool retainItems,
  required String label,
}) async {
  const fileSize = 4096;
  final directories = (fileCount / 1000).ceil();
  final fs = SyntheticTreeFileSystem(
    directoryCount: directories,
    filesPerDirectory: 1000,
    fileSize: fileSize,
  );
  final scanner = JunkScanner(
    jobs: [
      ScanJob(
        ruleId: 'bench.cache',
        roots: [fs.root],
        extensions: const {'tmp'},
      ),
    ],
    fileSystem: fs,
  );

  final rssBefore = ProcessInfo.currentRss;
  final stopwatch = Stopwatch()..start();
  var found = 0;
  var foundBytes = 0;
  final result = await scanner.scan(
    retainItems: retainItems,
    onItems: (items) {
      found += items.length;
      for (final item in items) {
        foundBytes += item.size;
      }
    },
  );
  stopwatch.stop();
  final rssAfter = ProcessInfo.currentRss;
  final seconds = stopwatch.elapsedMicroseconds / 1000000;
  final filesPerSecond = (result.scannedFiles / seconds).round();
  final mbPerSecond = (result.scannedFiles * fileSize / (1024 * 1024) / seconds)
      .toStringAsFixed(0);

  stdout.writeln('SCAN [$label]');
  stdout.writeln(
    '  scanned=${result.scannedFiles} found=$found '
    'elapsed=${stopwatch.elapsedMilliseconds}ms '
    'rate=$filesPerSecond files/s $mbPerSecond MiB/s',
  );
  stdout.writeln(
    '  rss=${_mb(rssBefore)}MiB -> ${_mb(rssAfter)}MiB '
    '(delta ${_mb(rssAfter - rssBefore)}MiB), '
    'foundBytes=$foundBytes retained=${retainItems ? result.items.length : 0}',
  );
}

Future<void> _benchmarkIsolateTransfer() async {
  const fileCount = 100000;
  const batchSize = 256;
  final items = List.generate(
    fileCount,
    (index) => JunkItem(
      ruleId: 'bench.cache',
      rootPath: r'C:\Bench\Cache',
      path: r'C:\Bench\Cache\d0000\f0000.tmp$index',
      size: 4096,
      modified: DateTime.utc(2026, 10, 1),
    ),
  );

  final setup = ReceivePort();
  final isolate = await Isolate.spawn(_echoWorker, setup.sendPort);
  final workerPort = await setup.first as SendPort;
  setup.close();
  final echo = ReceivePort();
  Completer<void>? pending;
  echo.listen((_) => pending?.complete());

  final stopwatch = Stopwatch()..start();
  var sent = 0;
  for (var offset = 0; offset < items.length; offset += batchSize) {
    final end = offset + batchSize > items.length
        ? items.length
        : offset + batchSize;
    final batch = items.sublist(offset, end);
    pending = Completer<void>();
    workerPort.send([batch, echo.sendPort]);
    await pending.future;
    sent += batch.length;
  }
  stopwatch.stop();
  isolate.kill(priority: Isolate.immediate);
  echo.close();

  final microsPerFile = stopwatch.elapsedMicroseconds / sent;
  stdout.writeln('ISOLATE TRANSFER (round trip, $batchSize per batch)');
  stdout.writeln(
    '  files=$sent elapsed=${stopwatch.elapsedMilliseconds}ms '
    '${microsPerFile.toStringAsFixed(2)}µs/file',
  );
}

void _echoWorker(SendPort mainSendPort) {
  final inbox = ReceivePort();
  mainSendPort.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! List) return;
    final batch = message[0];
    final reply = message[1] as SendPort;
    reply.send(batch);
  });
}

int _mb(int bytes) => (bytes / (1024 * 1024)).round();
