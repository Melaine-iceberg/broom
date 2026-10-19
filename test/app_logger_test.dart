import 'dart:io';

import 'package:broom/core/diagnostics/app_logger.dart';
import 'package:broom/core/platform/file_system.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const logsRoot = r'C:\BroomTest\logs';
  late MemoryFileSystem fs;

  AppLogger createLogger({
    AppLogLevel level = AppLogLevel.info,
    int maxFileBytes = 512 * 1024,
    int retainedFiles = 3,
    FsOperationHook? hook,
  }) {
    fs.onOperation = hook;
    return AppLogger(
      directoryPath: logsRoot,
      level: level,
      maxFileBytes: maxFileBytes,
      retainedFiles: retainedFiles,
      fileSystem: fs,
      clock: () => DateTime.utc(2026, 10, 19, 12, 0, 0),
    );
  }

  setUp(() {
    fs = MemoryFileSystem();
  });

  test('parses levels and orders them from off to debug', () {
    expect(AppLogLevel.parse('warning'), AppLogLevel.warning);
    expect(AppLogLevel.parse('WARN'), AppLogLevel.warning);
    expect(AppLogLevel.parse('debug'), AppLogLevel.debug);
    expect(AppLogLevel.parse('nonsense'), AppLogLevel.off);
    expect(AppLogLevel.parse(null), AppLogLevel.off);
    expect(AppLogLevel.off.allows(AppLogLevel.error), isFalse);
    expect(AppLogLevel.info.allows(AppLogLevel.error), isTrue);
    expect(AppLogLevel.info.allows(AppLogLevel.debug), isFalse);
    expect(AppLogLevel.debug.allows(AppLogLevel.debug), isTrue);
  });

  test('is off by default and writes nothing', () async {
    final logger = createLogger(level: AppLogLevel.off);
    logger.error('app', 'should not be written');
    logger.info('app', 'still invisible');
    await logger.flush();

    expect(await fs.type(logger.currentLogPath), FsEntityType.notFound);
    expect(logger.enabled, isFalse);
  });

  test('writes enabled entries and filters lower levels', () async {
    final logger = createLogger();
    logger.debug('scan', 'verbose detail');
    logger.info('scan', '开始扫描');
    logger.warning('clean', 'skipped one file');
    logger.error(
      'undo',
      'failed',
      error: StateError('boom\nsecond line'),
      stackTrace: StackTrace.fromString('#0 first\n#1 second'),
    );
    await logger.flush();

    final text = await fs.readString(logger.currentLogPath);
    final lines = await fs.readLines(logger.currentLogPath);
    expect(lines, hasLength(3));
    expect(text, contains('INFO'));
    expect(text, contains('WARNING'));
    expect(text, contains('ERROR'));
    expect(text, isNot(contains('DEBUG')));
    expect(text, isNot(contains('verbose detail')));
    expect(text, contains(r'boom\nsecond line'));
    expect(text, contains(r'#0 first | #1 second'));
    expect(lines.every((line) => !line.contains('\n')), isTrue);
    expect(text, startsWith('2026-10-19T12:00:00.000Z'));
  });

  test('rotates files and deletes the oldest archive', () async {
    final logger = createLogger(maxFileBytes: 1024, retainedFiles: 3);
    for (var index = 0; index < 12; index++) {
      logger.info('rotation', 'entry $index ${'x' * 200}');
    }
    await logger.flush();

    expect(await fs.type(logger.currentLogPath), FsEntityType.file);
    expect(await fs.type(logger.archiveLogPath(1)), FsEntityType.file);
    expect(await fs.type(logger.archiveLogPath(2)), FsEntityType.file);
    expect(await fs.type(logger.archiveLogPath(3)), FsEntityType.notFound);

    final all = [
      await fs.readString(logger.archiveLogPath(2)),
      await fs.readString(logger.archiveLogPath(1)),
      await fs.readString(logger.currentLogPath),
    ].join();
    expect(all, contains('entry 11'));
    expect(all, contains('entry 0'));
  });

  test('builds a JSON-compatible bundle with environment metadata', () async {
    final logger = createLogger();
    logger.info('app', 'ready');
    final bundle = await logger.buildBundle(
      appVersion: '0.4.0',
      environment: {'os': 'windows', 'locale': 'zh'},
    );

    expect(bundle['kind'], 'broom.diagnostics');
    expect(bundle['schemaVersion'], 1);
    expect(bundle['appVersion'], '0.4.0');
    expect(bundle['loggingEnabled'], isTrue);
    expect(bundle['logLevel'], 'info');
    expect(bundle['environment'], {'os': 'windows', 'locale': 'zh'});
    expect(bundle['logs'], contains('ready'));
  });

  test('exports environment information when logging is off', () async {
    final logger = createLogger(level: AppLogLevel.off);
    final bundle = await logger.buildBundle(
      appVersion: '0.4.0',
      environment: {'os': 'windows'},
    );

    expect(bundle['loggingEnabled'], isFalse);
    expect(bundle['logs'], isEmpty);
    expect(bundle['environment'], {'os': 'windows'});
  });

  test('swallows write failures and records the last error', () async {
    final logger = createLogger(
      hook: (operation, path) {
        if (operation == 'writeString') {
          throw const FileSystemException('disk full');
        }
      },
    );
    logger.info('app', 'ready');
    await logger.flush();

    expect(logger.lastWriteError, contains('disk full'));
    final bundle = await logger.buildBundle(appVersion: '0.4.0');
    expect(bundle['lastWriteError'], contains('disk full'));
  });

  test('truncates oversized lines and escapes line breaks', () async {
    final logger = createLogger();
    logger.info('big', 'a\n${'b' * 20000}');
    await logger.flush();

    final lines = await fs.readLines(logger.currentLogPath);
    expect(lines.single.length, lessThanOrEqualTo(AppLogger.maxLineLength + 1));
    expect(lines.single, contains(r'a\n'));
  });

  test('rejects relative or tiny log configurations', () {
    expect(
      () => AppLogger(directoryPath: r'relative\logs'),
      throwsArgumentError,
    );
    expect(
      () => AppLogger(directoryPath: logsRoot, maxFileBytes: 10),
      throwsArgumentError,
    );
    expect(
      () => AppLogger(directoryPath: logsRoot, retainedFiles: 0),
      throwsArgumentError,
    );
  });

  test('close waits for pending writes and stops new entries', () async {
    final logger = createLogger();
    logger.info('app', 'before close');
    await logger.close();
    logger.info('app', 'after close');
    await logger.flush();

    final text = await fs.readString(logger.currentLogPath);
    expect(text, contains('before close'));
    expect(text, isNot(contains('after close')));
  });
}
