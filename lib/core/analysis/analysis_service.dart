import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/analysis_models.dart';
import '../platform/directory_enum.dart';
import '../platform/path_semantics.dart';
import 'duplicate_finder.dart';
import 'file_tree_walker.dart';
import 'large_file_scanner.dart';

/// Abstract boundary so pages can be driven by fakes in tests.
abstract interface class AnalysisRunner {
  bool get isRunning;

  Future<DuplicateScanReport> findDuplicates({
    required String root,
    required int minFileSize,
    required List<String> excludedPaths,
    void Function(DuplicateProgress progress)? onProgress,
  });

  Future<LargeFileScanReport> findLargeFiles({
    required String root,
    required int minFileSize,
    required int maxResults,
    required List<String> excludedPaths,
    void Function(LargeFileProgress progress)? onProgress,
  });

  void cancel();

  void dispose();
}

class AnalysisService implements AnalysisRunner {
  AnalysisService({PathSemantics? semantics})
    : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform();

  final PathSemantics semantics;

  Isolate? _isolate;
  ReceivePort? _eventPort;
  ReceivePort? _errorPort;
  ReceivePort? _exitPort;
  ReceivePort? _controlPort;
  SendPort? _controlSendPort;
  StreamSubscription<dynamic>? _eventSubscription;
  StreamSubscription<dynamic>? _errorSubscription;
  StreamSubscription<dynamic>? _exitSubscription;
  Completer<Object>? _completer;
  bool _finished = false;
  bool _cancelRequested = false;

  @override
  bool get isRunning => _completer != null && !_finished;

  @override
  Future<DuplicateScanReport> findDuplicates({
    required String root,
    required int minFileSize,
    required List<String> excludedPaths,
    void Function(DuplicateProgress progress)? onProgress,
  }) async {
    final result = await _run(
      mode: _AnalysisMode.duplicates,
      root: root,
      minFileSize: minFileSize,
      maxResults: 0,
      excludedPaths: excludedPaths,
      onProgress: (progress) {
        if (progress is DuplicateProgress) onProgress?.call(progress);
      },
    );
    return result as DuplicateScanReport;
  }

  @override
  Future<LargeFileScanReport> findLargeFiles({
    required String root,
    required int minFileSize,
    required int maxResults,
    required List<String> excludedPaths,
    void Function(LargeFileProgress progress)? onProgress,
  }) async {
    final result = await _run(
      mode: _AnalysisMode.largeFiles,
      root: root,
      minFileSize: minFileSize,
      maxResults: maxResults,
      excludedPaths: excludedPaths,
      onProgress: (progress) {
        if (progress is LargeFileProgress) onProgress?.call(progress);
      },
    );
    return result as LargeFileScanReport;
  }

  Future<Object> _run({
    required _AnalysisMode mode,
    required String root,
    required int minFileSize,
    required int maxResults,
    required List<String> excludedPaths,
    required void Function(Object progress) onProgress,
  }) async {
    if (isRunning) {
      throw StateError('已有分析正在进行。');
    }

    final events = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final control = ReceivePort();
    _eventPort = events;
    _errorPort = errors;
    _exitPort = exits;
    _controlPort = control;
    _controlSendPort = control.sendPort;
    _finished = false;
    _cancelRequested = false;

    final completer = Completer<Object>();
    _completer = completer;

    var detailedListing = false;
    try {
      detailedListing = await probeDetailedListingFromRoot();
      _isolate = await Isolate.spawn(
        _analysisEntry,
        _AnalysisRequest(
          mode: mode,
          root: root,
          minFileSize: minFileSize,
          maxResults: maxResults,
          excludedPaths: excludedPaths,
          events: events.sendPort,
          control: control.sendPort,
          rootIsolateToken: detailedListing ? RootIsolateToken.instance : null,
          useDetailedListing: detailedListing,
          semantics: semantics,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
        debugName: 'broom-analysis',
      );
    } catch (error) {
      _finish(error: error);
      return completer.future;
    }

    _eventSubscription = events.listen((message) {
      switch (message) {
        case DuplicateProgress():
          onProgress(message);
        case LargeFileProgress():
          onProgress(message);
        case _AnalysisDone():
          _finish(result: message.report);
        case _AnalysisFailed():
          _finish(error: StateError(message.message));
      }
    });

    _errorSubscription = errors.listen((message) {
      final text = switch (message) {
        List() when message.isNotEmpty => '${message.first}',
        _ => '$message',
      };
      _finish(error: StateError(text));
    });

    _exitSubscription = exits.listen((_) {
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (!_finished) {
          _finish(error: StateError(_cancelRequested ? '分析已取消' : '分析进程意外退出'));
        }
      });
    });

    return completer.future;
  }

  @override
  void cancel() {
    if (!isRunning) return;
    _cancelRequested = true;
    _controlSendPort?.send(_AnalysisControl.cancel);
  }

  @override
  void dispose() {
    if (_finished) return;
    _finished = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    final completer = _completer;
    _completer = null;
    _release();
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('分析已中止'));
    }
  }

  void _finish({Object? result, Object? error}) {
    if (_finished) return;
    _finished = true;
    final completer = _completer;
    _completer = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _release();
    if (completer == null || completer.isCompleted) return;
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(result!);
    }
  }

  void _release() {
    _eventSubscription?.cancel();
    _errorSubscription?.cancel();
    _exitSubscription?.cancel();
    _eventSubscription = null;
    _errorSubscription = null;
    _exitSubscription = null;
    _eventPort?.close();
    _errorPort?.close();
    _exitPort?.close();
    _controlPort?.close();
    _eventPort = null;
    _errorPort = null;
    _exitPort = null;
    _controlPort = null;
    _controlSendPort = null;
  }
}

void _analysisEntry(_AnalysisRequest request) async {
  var cancelled = false;
  var useDetailedListing = request.useDetailedListing;
  final token = request.rootIsolateToken;
  if (token != null) {
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    } catch (_) {
      useDetailedListing = false;
    }
  }
  final control = ReceivePort();
  final subscription = control.listen((message) {
    if (message == _AnalysisControl.cancel) cancelled = true;
  });

  try {
    if (request.mode == _AnalysisMode.duplicates) {
      final result =
          await DuplicateFinder(
            root: request.root,
            minFileSize: request.minFileSize,
            maxFiles: defaultAnalysisMaxFiles,
            excludedPaths: request.excludedPaths,
            useDetailedListing: useDetailedListing,
            semantics: request.semantics,
          ).scan(
            onProgress: (progress) => request.events.send(progress),
            isCancelled: () => cancelled,
          );
      Isolate.exit(request.events, _AnalysisDone(result));
    }

    final result =
        await LargeFileScanner(
          root: request.root,
          minFileSize: request.minFileSize,
          maxResults: request.maxResults,
          maxFiles: defaultAnalysisMaxFiles,
          excludedPaths: request.excludedPaths,
          useDetailedListing: useDetailedListing,
          semantics: request.semantics,
        ).scan(
          onProgress: (progress) => request.events.send(progress),
          isCancelled: () => cancelled,
        );
    Isolate.exit(request.events, _AnalysisDone(result));
  } catch (error, stackTrace) {
    request.events.send(_AnalysisFailed('$error\n$stackTrace'));
  } finally {
    subscription.cancel();
    control.close();
  }
}

enum _AnalysisMode { duplicates, largeFiles }

enum _AnalysisControl { cancel }

class _AnalysisRequest {
  const _AnalysisRequest({
    required this.mode,
    required this.root,
    required this.minFileSize,
    required this.maxResults,
    required this.excludedPaths,
    required this.events,
    required this.control,
    this.rootIsolateToken,
    this.useDetailedListing = false,
    required this.semantics,
  });

  final _AnalysisMode mode;
  final String root;
  final int minFileSize;
  final int maxResults;
  final List<String> excludedPaths;
  final SendPort events;
  final SendPort control;
  final RootIsolateToken? rootIsolateToken;
  final bool useDetailedListing;
  final PathSemantics semantics;
}

class _AnalysisDone {
  const _AnalysisDone(this.report);

  final Object report;
}

class _AnalysisFailed {
  const _AnalysisFailed(this.message);

  final String message;
}
