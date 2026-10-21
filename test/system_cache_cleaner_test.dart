import 'dart:io';

import 'package:broom/core/clean/system_cache_cleaner.dart';
import 'package:broom/core/clean/system_services.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/models/system_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeServiceControl implements ServiceControl {
  final List<String> stopCalls = [];
  final List<String> startCalls = [];
  Set<String> stopResult = {};
  List<String> startIssues = [];
  Object? stopError;

  @override
  Future<Set<String>> stopServices(Iterable<String> names) async {
    stopCalls.addAll(names);
    if (stopError case final error?) throw error;
    return stopResult;
  }

  @override
  Future<List<String>> startServices(Iterable<String> names) async {
    startCalls.addAll(names);
    return startIssues;
  }
}

void main() {
  late Directory temp;
  late Directory root;
  late Directory outside;
  late _FakeServiceControl services;
  late FileSystemCacheCleaner cleaner;
  late ScanRoots roots;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_system_cleaner_');
    root = Directory(
      p.join(temp.path, 'Windows', 'SoftwareDistribution', 'Download'),
    );
    await root.create(recursive: true);
    outside = Directory(p.join(temp.path, 'outside'));
    await outside.create(recursive: true);
    roots = ScanRoots([
      ScanRoot(ruleId: 'windows.update_cache', rootPath: root.path),
    ]);
    services = _FakeServiceControl();
    cleaner = FileSystemCacheCleaner(services: services);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<File> createFile(Directory directory, String name) async {
    final file = File(p.join(directory.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(name);
    return file;
  }

  Future<JunkItem> itemFor(File file, {String? path, int rootIndex = 0}) async {
    final stat = await file.stat();
    return JunkItem(
      rootIndex: rootIndex,
      path: path ?? file.path,
      size: stat.size,
      modifiedMicros: stat.modified.microsecondsSinceEpoch,
    );
  }

  test('permanently deletes files inside the trusted root', () async {
    final first = await createFile(root, 'first.cab');
    final nested = Directory(p.join(root.path, 'nested'));
    final second = await createFile(nested, 'second.cab');
    final stages = <SystemCleanStage>[];
    final progress = <SystemCleanProgress>[];
    services.stopResult = {'wuauserv'};

    final report = await cleaner.clean(
      items: [await itemFor(first), await itemFor(second)],
      roots: roots,
      rootsByRule: {
        'windows.update_cache': [root.path],
      },
      serviceNames: ['wuauserv', 'bits', 'wuauserv'],
      onStage: stages.add,
      onProgress: progress.add,
    );

    expect(report.deletedCount, 2);
    expect(report.deletedBytes, 'first.cab'.length + 'second.cab'.length);
    expect(report.failureCount, 0);
    expect(report.cancelled, isFalse);
    expect(report.serviceIssues, isEmpty);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);
    expect(services.stopCalls, ['wuauserv', 'bits']);
    expect(services.startCalls, ['wuauserv']);
    expect(stages, [
      SystemCleanStage.stoppingServices,
      SystemCleanStage.deleting,
      SystemCleanStage.restartingServices,
    ]);
    expect(progress.last.processed, 2);
    expect(progress.last.total, 2);
    expect(progress.last.deleted, 2);
    expect(progress.last.deletedBytes, report.deletedBytes);
  });

  test('rejects paths outside the rule root, the root itself, and '
      'untrusted items', () async {
    final inside = await createFile(root, 'keep.txt');
    final outsideFile = await createFile(outside, 'outside.txt');
    final rootItem = JunkItem(
      rootIndex: 0,
      path: root.path,
      size: 0,
      modifiedMicros: DateTime.now().microsecondsSinceEpoch,
    );
    final wrongRootItem = await itemFor(inside, rootIndex: 1);

    final report = await cleaner.clean(
      items: [await itemFor(outsideFile), rootItem, wrongRootItem],
      roots: ScanRoots([
        ScanRoot(ruleId: 'windows.update_cache', rootPath: root.path),
        ScanRoot(ruleId: 'windows.update_cache', rootPath: outside.path),
      ]),
      rootsByRule: {
        'windows.update_cache': [root.path],
      },
      serviceNames: const [],
    );

    expect(report.deletedCount, 0);
    expect(report.failureCount, 3);
    expect(
      report.failures.map((failure) => failure.reason),
      containsAll(['文件不在声明的缓存目录内', '不会删除缓存根目录本身', '规则根目录未通过安全检查']),
    );
    expect(await outsideFile.exists(), isTrue);
    expect(await inside.exists(), isTrue);
  });

  test('rejects rules without a trusted or safe root', () async {
    final file = await createFile(outside, 'candidate.txt');
    final item = await itemFor(file);

    final noRoot = await cleaner.clean(
      items: [item],
      roots: roots,
      rootsByRule: const {},
      serviceNames: const [],
    );
    expect(noRoot.failures.single.reason, '规则没有可信的缓存根目录');

    final driveRoot = await cleaner.clean(
      items: [
        JunkItem(
          rootIndex: 0,
          path: r'C:\Windows\not-a-real-cache-file.tmp',
          size: 0,
          modifiedMicros: DateTime.now().microsecondsSinceEpoch,
        ),
      ],
      roots: roots,
      rootsByRule: const {
        'windows.update_cache': [r'C:\'],
      },
      serviceNames: const [],
    );
    expect(driveRoot.failures.single.reason, '规则没有可信的缓存根目录');
    expect(await file.exists(), isTrue);
  });

  test('reports files that already disappeared', () async {
    final missing = File(p.join(root.path, 'missing.cab'));
    final report = await cleaner.clean(
      items: [
        JunkItem(
          rootIndex: 0,
          path: missing.path,
          size: 12,
          modifiedMicros: DateTime.now().microsecondsSinceEpoch,
        ),
      ],
      roots: roots,
      rootsByRule: {
        'windows.update_cache': [root.path],
      },
      serviceNames: const [],
    );

    expect(report.deletedCount, 0);
    expect(report.skippedCount, 1);
    expect(report.skips.single.reason, '文件已不存在或不是普通文件');
    expect(report.failureCount, 0);
  });

  test('classifies a locked file as skipped without deleting it', () async {
    final file = await createFile(root, 'locked.cab');
    final script = File(p.join(temp.path, 'hold_lock.ps1'));
    final ready = File(p.join(temp.path, 'lock.ready'));
    const scriptText = r'''
$ErrorActionPreference = 'Stop'
$target = $args[0]
$ready = $args[1]
$stream = [System.IO.File]::Open($target, 'Open', 'Read', 'None')
try {
  Set-Content -LiteralPath $ready -Value 'ready' -NoNewline
  Start-Sleep -Seconds 60
} finally {
  $stream.Close()
}
''';
    await script.writeAsString(scriptText);
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      file.path,
      ready.path,
    ]);

    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await ready.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('文件锁辅助进程未能在超时前启动');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final report = await cleaner.clean(
        items: [await itemFor(file)],
        roots: roots,
        rootsByRule: {
          'windows.update_cache': [root.path],
        },
        serviceNames: const [],
      );

      expect(report.deletedCount, 0);
      expect(report.skippedCount, 1);
      expect(report.skips.single.reason, contains('占用'));
      expect(report.failureCount, 0);
      expect(await file.exists(), isTrue);
    } finally {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
    }
    expect(await file.readAsString(), 'locked.cab');
  }, skip: Platform.isWindows ? false : 'Windows only');

  test('stops after cancellation and restarts services', () async {
    final files = [
      await createFile(root, 'one.tmp'),
      await createFile(root, 'two.tmp'),
      await createFile(root, 'three.tmp'),
    ];
    final items = <JunkItem>[];
    for (final file in files) {
      items.add(await itemFor(file));
    }
    services.stopResult = {'wuauserv'};
    var checks = 0;
    final stages = <SystemCleanStage>[];

    final report = await cleaner.clean(
      items: items,
      roots: roots,
      rootsByRule: {
        'windows.update_cache': [root.path],
      },
      serviceNames: ['wuauserv'],
      onStage: stages.add,
      isCancelled: () => checks++ > 0,
    );

    expect(report.cancelled, isTrue);
    expect(report.deletedCount, 1);
    expect(report.failureCount, 0);
    expect(await files[0].exists(), isFalse);
    expect(await files[1].exists(), isTrue);
    expect(await files[2].exists(), isTrue);
    expect(services.startCalls, ['wuauserv']);
    expect(stages.last, SystemCleanStage.restartingServices);
  });

  test('does not touch services when there is nothing to delete', () async {
    final report = await cleaner.clean(
      items: const [],
      roots: roots,
      rootsByRule: const {},
      serviceNames: ['wuauserv', 'bits'],
    );

    expect(report.deletedCount, 0);
    expect(report.failureCount, 0);
    expect(services.stopCalls, isEmpty);
    expect(services.startCalls, isEmpty);
  });

  test('caps stored failure details while counting every failure', () async {
    cleaner = FileSystemCacheCleaner(services: services, maxFailureDetails: 2);
    final outsideFiles = [
      await createFile(outside, 'a.txt'),
      await createFile(outside, 'b.txt'),
      await createFile(outside, 'c.txt'),
    ];
    final items = <JunkItem>[];
    for (final file in outsideFiles) {
      items.add(await itemFor(file));
    }

    final report = await cleaner.clean(
      items: items,
      roots: roots,
      rootsByRule: {
        'windows.update_cache': [root.path],
      },
      serviceNames: const [],
    );

    expect(report.failureCount, 3);
    expect(report.failures, hasLength(2));
  });

  test('surfaces service restart issues in the report', () async {
    final file = await createFile(root, 'data.bin');
    services.stopResult = {'wuauserv'};
    services.startIssues = ['wuauserv：服务已被禁用'];

    final report = await cleaner.clean(
      items: [await itemFor(file)],
      roots: roots,
      rootsByRule: {
        'windows.update_cache': [root.path],
      },
      serviceNames: ['wuauserv'],
    );

    expect(report.deletedCount, 1);
    expect(report.serviceIssues.single, contains('服务已被禁用'));
  });

  test('skips links without deleting their targets', () async {
    final target = await createFile(outside, 'target.txt');
    final link = Link(p.join(root.path, 'link.txt'));
    try {
      await link.create(target.path);
    } on FileSystemException {
      // Creating symlinks needs developer mode or elevation on Windows.
      return;
    }

    final report = await cleaner.clean(
      items: [
        JunkItem(
          rootIndex: 0,
          path: link.path,
          size: 0,
          modifiedMicros: DateTime.now().microsecondsSinceEpoch,
        ),
      ],
      roots: roots,
      rootsByRule: {
        'windows.update_cache': [root.path],
      },
      serviceNames: const [],
    );

    expect(report.skippedCount, 1);
    expect(report.skips.single.reason, contains('符号链接'));
    expect(report.failureCount, 0);
    expect(await target.exists(), isTrue);
  });
}
