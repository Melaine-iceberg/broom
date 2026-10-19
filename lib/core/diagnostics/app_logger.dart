import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../platform/file_system.dart';

/// Severity of a diagnostic log entry.
///
/// Ordering is intentional: a configured [AppLogLevel.info] accepts errors,
/// warnings and info, while [AppLogLevel.off] disables writing entirely.
enum AppLogLevel {
  off,
  error,
  warning,
  info,
  debug;

  bool allows(AppLogLevel entry) =>
      this != AppLogLevel.off && index >= entry.index;

  static AppLogLevel parse(String? value, {AppLogLevel fallback = .off}) {
    final normalized = value?.trim().toLowerCase();
    return switch (normalized) {
      'off' || 'none' => AppLogLevel.off,
      'error' => AppLogLevel.error,
      'warn' || 'warning' => AppLogLevel.warning,
      'info' => AppLogLevel.info,
      'debug' || 'trace' => AppLogLevel.debug,
      _ => fallback,
    };
  }
}

/// Local, rolling diagnostics log.
///
/// Logging is disabled by default; enabling it never records file contents.
/// Callers pass short event descriptions, counts, paths and error messages. The
/// writer is intentionally fire-and-forget: a failing or slow disk must never
/// make a cleanup operation fail.
class AppLogger {
  AppLogger({
    required this.directoryPath,
    this.level = AppLogLevel.off,
    this.maxFileBytes = 512 * 1024,
    this.retainedFiles = 3,
    this.fileSystem = const IoFileSystem(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (!p.windows.isAbsolute(directoryPath)) {
      throw ArgumentError.value(directoryPath, 'directoryPath', '日志目录必须是绝对路径');
    }
    if (maxFileBytes < 1024) {
      throw ArgumentError.value(maxFileBytes, 'maxFileBytes', '日志上限过小');
    }
    if (retainedFiles < 1) {
      throw ArgumentError.value(retainedFiles, 'retainedFiles', '至少保留一个文件');
    }
  }

  static const int maxLineLength = 8192;
  static const int maxExportCharacters = 5 * 1024 * 1024;

  /// Set by `main` so UI code can offer the export action without threading a
  /// logger through every page. Tests use their own instance.
  static AppLogger? instance;

  static const String fileName = 'broom.log';

  final String directoryPath;
  final int maxFileBytes;
  final int retainedFiles;
  final BroomFileSystem fileSystem;
  final DateTime Function() _clock;

  /// Current verbosity. Prefer [configureLevel] so enabling is itself logged.
  AppLogLevel level;
  Future<void> _queue = Future<void>.value();
  String? _lastWriteError;
  bool _closed = false;

  bool get enabled => level != AppLogLevel.off;

  /// Last background write error, exposed for diagnostics UI and tests.
  String? get lastWriteError => _lastWriteError;

  String get currentLogPath => p.windows.join(directoryPath, fileName);

  String archiveLogPath(int index) {
    if (index < 1) {
      throw ArgumentError.value(index, 'index', '归档序号从 1 开始');
    }
    return p.windows.join(directoryPath, 'broom.$index.log');
  }

  void configureLevel(AppLogLevel level) {
    if (this.level == level) return;
    this.level = level;
    if (level != AppLogLevel.off) {
      info('diagnostics', '诊断日志已启用，级别 ${level.name}');
    }
  }

  void error(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _log(
      AppLogLevel.error,
      category,
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void warning(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _log(
      AppLogLevel.warning,
      category,
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void info(String category, String message) {
    _log(AppLogLevel.info, category, message);
  }

  void debug(String category, String message) {
    _log(AppLogLevel.debug, category, message);
  }

  void _log(
    AppLogLevel entryLevel,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_closed || !level.allows(entryLevel)) return;
    var line = _format(entryLevel, category, message);
    if (error != null) {
      final detail = _oneLine(error.toString());
      line = '$line error=$detail';
    }
    final stack = stackTrace;
    if (stack != null) {
      final frames = stack.toString().trim().split('\n');
      final limited = frames.take(20).join(' | ');
      line = '$line stack=${_oneLine(limited)}';
    }
    if (line.length > maxLineLength) {
      line = '${line.substring(0, maxLineLength)}…';
    }
    _queue = _queue.then((_) => _append(line)).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _lastWriteError = error.toString();
    });
  }

  String _format(AppLogLevel level, String category, String message) {
    final timestamp = _clock().toUtc().toIso8601String();
    final safeCategory = _oneLine(category)
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return '$timestamp ${level.name.toUpperCase().padRight(7)} '
        '[$safeCategory] ${_oneLine(message)}';
  }

  static String _oneLine(String value) =>
      value.replaceAll('\r', ' ').replaceAll('\n', r'\n');

  Future<void> _append(String line) async {
    if (_closed) return;
    try {
      await _rotateIfNeeded(utf8.encode(line).length + 1);
      await fileSystem.writeString(currentLogPath, '$line\n', append: true);
    } on Object catch (error) {
      // Logging must never break a user operation.
      _lastWriteError = error.toString();
    }
  }

  Future<void> _rotateIfNeeded(int incomingBytes) async {
    final path = currentLogPath;
    final type = await fileSystem.type(path);
    if (type == FsEntityType.notFound) {
      await fileSystem.createDirectory(directoryPath);
      return;
    }
    final length = await fileSystem.length(path);
    if (length + incomingBytes <= maxFileBytes) return;

    if (retainedFiles <= 1) {
      await fileSystem.deleteFile(path);
      return;
    }

    final oldest = archiveLogPath(retainedFiles - 1);
    if (await fileSystem.type(oldest) != FsEntityType.notFound) {
      await fileSystem.deleteFile(oldest);
    }
    for (var index = retainedFiles - 2; index >= 1; index--) {
      final from = archiveLogPath(index);
      if (await fileSystem.type(from) == FsEntityType.notFound) continue;
      await fileSystem.rename(from, archiveLogPath(index + 1));
    }
    await fileSystem.rename(path, archiveLogPath(1));
  }

  Future<void> flush() async {
    try {
      await _queue;
    } on Object {
      // Errors are recorded by the append task.
    }
  }

  /// Builds a JSON-serializable diagnostic bundle. Only log lines and the
  /// provided environment metadata are included; file contents never enter the
  /// log in the first place.
  Future<Map<String, Object?>> buildBundle({
    required String appVersion,
    Map<String, String> environment = const {},
  }) async {
    await flush();
    final logs = <String>[];
    for (var index = retainedFiles - 1; index >= 1; index--) {
      final archive = archiveLogPath(index);
      try {
        if (await fileSystem.type(archive) == FsEntityType.file) {
          logs.add(await fileSystem.readString(archive));
        }
      } on Object {
        // Skip unreadable archives; the bundle stays usable.
      }
    }
    try {
      if (await fileSystem.type(currentLogPath) == FsEntityType.file) {
        logs.add(await fileSystem.readString(currentLogPath));
      }
    } on Object {
      // Same as above.
    }
    var text = logs.join();
    if (text.length > maxExportCharacters) {
      text = text.substring(text.length - maxExportCharacters);
    }
    return {
      'kind': 'broom.diagnostics',
      'schemaVersion': 1,
      'appVersion': appVersion,
      'generatedAt': _clock().toUtc().toIso8601String(),
      'loggingEnabled': enabled,
      'logLevel': level.name,
      'lastWriteError': ?_lastWriteError,
      'environment': environment,
      'logs': text,
    };
  }

  /// Stops accepting entries and waits for queued writes.
  Future<void> close() async {
    if (_closed) return;
    await flush();
    _closed = true;
  }
}
