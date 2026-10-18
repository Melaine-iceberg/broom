import 'package:flutter/foundation.dart';

import '../core/analysis/analysis_service.dart';
import '../core/analysis/duplicate_finder.dart';
import '../core/analysis/large_file_scanner.dart';
import '../core/models/analysis_models.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';

enum AnalysisToolPhase { idle, running, results }

const duplicateMinSizeOptions = <int>[
  100 * 1024,
  1024 * 1024,
  10 * 1024 * 1024,
  100 * 1024 * 1024,
];

const largeFileThresholdOptions = <int>[
  50 * 1024 * 1024,
  100 * 1024 * 1024,
  500 * 1024 * 1024,
  1024 * 1024 * 1024,
  5 * 1024 * 1024 * 1024,
];

String analysisErrorMessage(Object error) {
  if (error is StateError) return error.message;
  if (error is SystemShellException) return error.message;
  return '$error';
}

class DuplicateFinderController extends ChangeNotifier {
  DuplicateFinderController({
    required this.shell,
    required this.runnerFactory,
    required this.excludedPaths,
    String? initialDirectory,
    int? minFileSize,
  }) : _directory = initialDirectory,
       _minFileSize = minFileSize ?? defaultDuplicateMinFileSize;

  final SystemShell shell;
  final AnalysisRunner Function() runnerFactory;
  final List<String> excludedPaths;

  AnalysisToolPhase _phase = AnalysisToolPhase.idle;
  String? _directory;
  int _minFileSize;
  DuplicateProgress? _progress;
  DuplicateScanReport? _report;
  String? _error;
  String? _notice;
  AnalysisRunner? _runner;
  bool _cancelRequested = false;
  bool _disposed = false;

  AnalysisToolPhase get phase => _phase;
  String? get directory => _directory;
  int get minFileSize => _minFileSize;
  DuplicateProgress? get progress => _progress;
  DuplicateScanReport? get report => _report;
  String? get error => _error;
  String? get notice => _notice;
  bool get isRunning => _phase == AnalysisToolPhase.running;
  bool get cancelRequested => _cancelRequested;

  Future<void> chooseDirectory() async {
    if (isRunning) return;
    try {
      final selected = await shell.pickFolder(initialDirectory: _directory);
      if (_disposed || selected == null) return;
      _directory = selected;
      _resetResults();
      _error = null;
      _notice = null;
      _notify();
    } on SystemShellException catch (error) {
      if (_disposed) return;
      _error = error.message;
      _notify();
    }
  }

  void setMinFileSize(int bytes) {
    if (isRunning || bytes == _minFileSize) return;
    _minFileSize = bytes;
    _resetResults();
    _notify();
  }

  Future<void> scan() async {
    if (isRunning) return;
    final directory = _directory;
    if (directory == null) {
      _notice = tr('请先选择要分析的文件夹。');
      _notify();
      return;
    }

    _phase = AnalysisToolPhase.running;
    _progress = null;
    _report = null;
    _error = null;
    _notice = null;
    _cancelRequested = false;
    final runner = runnerFactory();
    _runner = runner;
    _notify();

    try {
      final report = await runner.findDuplicates(
        root: directory,
        minFileSize: _minFileSize,
        excludedPaths: excludedPaths,
        onProgress: (progress) {
          if (_disposed) return;
          _progress = progress;
          _notify();
        },
      );
      if (_disposed) return;
      if (report.cancelled) {
        _phase = AnalysisToolPhase.idle;
        _notice = tr('分析已取消。');
      } else {
        _report = report;
        _phase = AnalysisToolPhase.results;
      }
    } catch (error) {
      if (_disposed) return;
      _phase = AnalysisToolPhase.idle;
      _error = trf('分析失败：{error}', {'error': analysisErrorMessage(error)});
    } finally {
      runner.dispose();
      if (identical(_runner, runner)) _runner = null;
      _cancelRequested = false;
      _notify();
    }
  }

  void cancel() {
    if (!isRunning) return;
    _cancelRequested = true;
    _runner?.cancel();
    _notify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  void _resetResults() {
    _phase = AnalysisToolPhase.idle;
    _progress = null;
    _report = null;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _runner?.dispose();
    _runner = null;
    super.dispose();
  }
}

class LargeFileController extends ChangeNotifier {
  LargeFileController({
    required this.shell,
    required this.runnerFactory,
    required this.excludedPaths,
    String? initialDirectory,
    int? minFileSize,
    this.maxResults = defaultLargeFileMaxResults,
  }) : _directory = initialDirectory,
       _minFileSize = minFileSize ?? defaultLargeFileMinSize;

  final SystemShell shell;
  final AnalysisRunner Function() runnerFactory;
  final List<String> excludedPaths;
  final int maxResults;

  AnalysisToolPhase _phase = AnalysisToolPhase.idle;
  String? _directory;
  int _minFileSize;
  LargeFileProgress? _progress;
  LargeFileScanReport? _report;
  String? _error;
  String? _notice;
  AnalysisRunner? _runner;
  bool _cancelRequested = false;
  bool _disposed = false;

  AnalysisToolPhase get phase => _phase;
  String? get directory => _directory;
  int get minFileSize => _minFileSize;
  LargeFileProgress? get progress => _progress;
  LargeFileScanReport? get report => _report;
  String? get error => _error;
  String? get notice => _notice;
  bool get isRunning => _phase == AnalysisToolPhase.running;
  bool get cancelRequested => _cancelRequested;

  Future<void> chooseDirectory() async {
    if (isRunning) return;
    try {
      final selected = await shell.pickFolder(initialDirectory: _directory);
      if (_disposed || selected == null) return;
      _directory = selected;
      _resetResults();
      _error = null;
      _notice = null;
      _notify();
    } on SystemShellException catch (error) {
      if (_disposed) return;
      _error = error.message;
      _notify();
    }
  }

  void setMinFileSize(int bytes) {
    if (isRunning || bytes == _minFileSize) return;
    _minFileSize = bytes;
    _resetResults();
    _notify();
  }

  Future<void> scan() async {
    if (isRunning) return;
    final directory = _directory;
    if (directory == null) {
      _notice = tr('请先选择要分析的文件夹。');
      _notify();
      return;
    }

    _phase = AnalysisToolPhase.running;
    _progress = null;
    _report = null;
    _error = null;
    _notice = null;
    _cancelRequested = false;
    final runner = runnerFactory();
    _runner = runner;
    _notify();

    try {
      final report = await runner.findLargeFiles(
        root: directory,
        minFileSize: _minFileSize,
        maxResults: maxResults,
        excludedPaths: excludedPaths,
        onProgress: (progress) {
          if (_disposed) return;
          _progress = progress;
          _notify();
        },
      );
      if (_disposed) return;
      if (report.cancelled) {
        _phase = AnalysisToolPhase.idle;
        _notice = tr('分析已取消。');
      } else {
        _report = report;
        _phase = AnalysisToolPhase.results;
      }
    } catch (error) {
      if (_disposed) return;
      _phase = AnalysisToolPhase.idle;
      _error = trf('分析失败：{error}', {'error': analysisErrorMessage(error)});
    } finally {
      runner.dispose();
      if (identical(_runner, runner)) _runner = null;
      _cancelRequested = false;
      _notify();
    }
  }

  void cancel() {
    if (!isRunning) return;
    _cancelRequested = true;
    _runner?.cancel();
    _notify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  void _resetResults() {
    _phase = AnalysisToolPhase.idle;
    _progress = null;
    _report = null;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _runner?.dispose();
    _runner = null;
    super.dispose();
  }
}
