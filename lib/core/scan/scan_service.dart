import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/scan_models.dart';
import '../platform/directory_enum.dart';
import '../platform/path_semantics.dart';
import '../platform/scan_priority.dart';
import 'junk_scanner.dart';
import 'ntfs_index.dart';

/// Runs scans in worker isolates and streams results back to the caller.
///
/// NTFS-indexed scans cannot use `ntfsIndex` inside a spawned isolate because
/// the native index stream is bound to the root isolate. When every root is
/// index-capable the coordinator runs the indexed scanner itself and yields
/// between asynchronous file stats; otherwise it falls back to parallel
/// directory workers.
class ScanService {
  ScanService({
    this.semantics = const WindowsPathSemantics(),
    this.priorityController = const MethodChannelScanPriorityController(),
  });

  final PathSemantics semantics;
  final ScanPriorityController priorityController;

  final List<_WorkerHandle> _workers = [];
  ReceivePort? _inProcessControl;
  bool _inProcessCancel = false;
  Completer<ScanResult>? _completer;
  bool _finished = false;
  bool _userCancelled = false;
  bool _limitReached = false;
  bool _workersReady = false;
  bool _priorityActive = false;
  bool _retainItems = true;
  ScanOptions _options = const ScanOptions();
  List<ScanJob> _jobs = const [];
  final Stopwatch _stopwatch = Stopwatch();

  final Set<String> _seenPaths = <String>{};
  final List<JunkItem> _resultItems = <JunkItem>[];
  final List<ScanIssue> _issues = <ScanIssue>[];
  int _uniqueFound = 0;
  int _uniqueBytes = 0;
  String? _activeRuleId;
  int _activeJobIndex = 0;

  void Function(ScanProgress progress)? _onProgress;
  void Function(List<JunkItem> items)? _onItems;
  void Function(ScanIssue issue)? _onIssue;

  bool get isRunning => _completer != null && !_finished;

  Future<ScanResult> scan({
    required List<ScanJob> jobs,
    required List<String> excludedPaths,
    ScanOptions options = const ScanOptions(),
    NtfsIndex? ntfsIndex,
    void Function(ScanProgress progress)? onProgress,
    void Function(List<JunkItem> items)? onItems,
    void Function(ScanIssue issue)? onIssue,
    bool retainItems = true,
  }) async {
    if (isRunning) {
      throw StateError('A scan is already running.');
    }

    final completer = Completer<ScanResult>();
    _completer = completer;
    _finished = false;
    _userCancelled = false;
    _limitReached = false;
    _workersReady = false;
    _priorityActive = false;
    _retainItems = retainItems;
    _options = options;
    _jobs = jobs;
    _onProgress = onProgress;
    _onItems = onItems;
    _onIssue = onIssue;
    _seenPaths.clear();
    _resultItems.clear();
    _issues.clear();
    _uniqueFound = 0;
    _uniqueBytes = 0;
    _activeRuleId = null;
    _activeJobIndex = 0;
    _workers.clear();
    _stopwatch
      ..reset()
      ..start();

    if (options.lowPriority) {
      try {
        await priorityController.beginLowPriority();
        _priorityActive = true;
      } catch (_) {
        // Priority is best effort. An unavailable native channel must not stop
        // the scan.
      }
    }
    if (_finished) return completer.future;

    if (jobs.isEmpty) {
      _finish(
        result: ScanResult(
          items: const [],
          scannedFiles: 0,
          directoryErrors: 0,
          truncated: false,
          cancelled: false,
          elapsed: _stopwatch.elapsed,
        ),
      );
      return completer.future;
    }

    var useIndexedPath = false;
    if (options.useNtfsIndex && ntfsIndex != null) {
      useIndexedPath = await _allRootsIndexable(jobs, ntfsIndex);
    }
    if (_finished) return completer.future;
    if (_userCancelled) {
      _finish(result: _composeResult(scannedFiles: 0, cancelled: true));
      return completer.future;
    }

    if (useIndexedPath) {
      unawaited(_runIndexed(jobs, excludedPaths, options, ntfsIndex!));
    } else {
      final detailedListing = await _probeDetailedListing();
      if (_finished) return completer.future;
      await _startWorkers(
        jobs,
        excludedPaths,
        options,
        detailedListing: detailedListing,
      );
    }

    return completer.future;
  }

  void cancel() {
    if (!isRunning) return;
    _userCancelled = true;
    _inProcessCancel = true;
    for (final worker in _workers) {
      worker.controlSendPort?.send(_ScanControl.cancel);
    }
  }

  void dispose() {
    if (_finished) return;
    _finish(error: StateError('扫描已中止'));
  }

  /// Decides once, from the root isolate, whether worker isolates may use the
  /// native directory enumerator.
  ///
  /// Probing here also covers builds whose runner predates the channel: they
  /// keep the `list` + `stat` path.
  Future<bool> _probeDetailedListing() => probeDetailedListingFromRoot();

  Future<bool> _allRootsIndexable(List<ScanJob> jobs, NtfsIndex index) async {
    try {
      for (final job in jobs) {
        for (final root in job.roots) {
          final availability = await index.probe(root);
          if (!availability.isAvailable) return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _runIndexed(
    List<ScanJob> jobs,
    List<String> excludedPaths,
    ScanOptions options,
    NtfsIndex index,
  ) async {
    final control = ReceivePort();
    _inProcessControl = control;
    final subscription = control.listen((message) {
      if (message == _ScanControl.cancel) _inProcessCancel = true;
    });

    try {
      final scanner = JunkScanner(
        jobs: jobs,
        excludedPaths: excludedPaths,
        batchSize: options.batchSize,
        semantics: semantics,
        ntfsIndex: index,
        useNtfsIndex: true,
      );
      final result = await scanner.scan(
        retainItems: false,
        onProgress: _handleProgress,
        onItems: _acceptItems,
        onIssue: _acceptIssue,
        isCancelled: () => _inProcessCancel || _limitReached,
      );
      if (_finished) return;
      _finish(
        result: _composeResult(
          scannedFiles: result.scannedFiles,
          cancelled: _userCancelled,
          elapsed: result.elapsed,
        ),
      );
    } catch (error, stackTrace) {
      if (!_finished) {
        _finish(error: StateError('$error\n$stackTrace'));
      }
    } finally {
      await subscription.cancel();
      control.close();
      _inProcessControl = null;
    }
  }

  Future<void> _startWorkers(
    List<ScanJob> jobs,
    List<String> excludedPaths,
    ScanOptions options, {
    required bool detailedListing,
  }) async {
    final workerCount = _resolveWorkerCount(jobs.length, options.parallelism);
    final sliceSize = (jobs.length / workerCount).ceil();
    for (var workerId = 0; workerId < workerCount; workerId++) {
      final start = workerId * sliceSize;
      if (start >= jobs.length) break;
      final end = (start + sliceSize).clamp(0, jobs.length);
      final workerJobs = jobs.sublist(start, end);
      final handle = _WorkerHandle();
      _workers.add(handle);

      final events = ReceivePort();
      final errors = ReceivePort();
      final exits = ReceivePort();
      final control = ReceivePort();
      handle
        ..events = events
        ..errors = errors
        ..exits = exits
        ..control = control
        ..controlSendPort = control.sendPort;

      try {
        handle.isolate = await Isolate.spawn(
          _scanWorkerEntry,
          _WorkerRequest(
            jobs: workerJobs,
            jobIndexBase: start,
            jobCount: jobs.length,
            excludedPaths: excludedPaths,
            batchSize: options.batchSize,
            semantics: semantics,
            events: events.sendPort,
            control: control.sendPort,
            // Lets the worker reach the platform channel for directory
            // enumeration; null when the caller has no engine (tests).
            rootIsolateToken: detailedListing
                ? RootIsolateToken.instance
                : null,
            useDetailedListing: detailedListing,
          ),
          onError: errors.sendPort,
          onExit: exits.sendPort,
          errorsAreFatal: true,
          debugName: 'broom-scan-$workerId',
        );
      } catch (error) {
        _fail(error);
        return;
      }

      if (_userCancelled) {
        control.sendPort.send(_ScanControl.cancel);
      }
      handle.eventSubscription = events.listen((message) {
        switch (message) {
          case _WorkerProgress(:final progress):
            _handleWorkerProgress(handle, progress);
          case _WorkerItems(:final items):
            _acceptItems(items);
          case _WorkerIssue(:final issue):
            _acceptIssue(issue);
          case _WorkerDone(:final summary):
            _handleWorkerDone(handle, summary);
          case _WorkerFailed(:final message):
            _fail(StateError(message));
        }
      });
      handle.errorSubscription = errors.listen((message) {
        final text = switch (message) {
          List() when message.isNotEmpty => '${message.first}',
          _ => '$message',
        };
        _fail(StateError(text));
      });
      handle.exitSubscription = exits.listen((_) {
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          if (!_finished && !handle.done) {
            _fail(StateError(_userCancelled ? '扫描已取消' : '扫描进程意外退出'));
          }
        });
      });
    }

    _workersReady = true;
    _maybeFinish();
  }

  int _resolveWorkerCount(int jobCount, int parallelism) {
    if (jobCount <= 1) return 1;
    if (parallelism > 0) return parallelism.clamp(1, jobCount);
    final processors = Platform.numberOfProcessors;
    return processors.clamp(1, 4).clamp(1, jobCount);
  }

  void _handleWorkerProgress(_WorkerHandle worker, ScanProgress progress) {
    if (_finished) return;
    worker.progress = progress;
    _activeRuleId = progress.ruleId;
    _activeJobIndex = progress.jobIndex;
    _emitProgress();
  }

  void _handleProgress(ScanProgress progress) {
    if (_finished) return;
    _activeRuleId = progress.ruleId;
    _activeJobIndex = progress.jobIndex;
    _emitProgress(scannedOverride: progress.scannedFiles);
  }

  void _emitProgress({int? scannedOverride}) {
    var scanned = scannedOverride ?? 0;
    if (scannedOverride == null) {
      for (final worker in _workers) {
        scanned += worker.progress?.scannedFiles ?? 0;
      }
    }
    _onProgress?.call(
      ScanProgress(
        jobIndex: _activeJobIndex,
        jobCount: _jobs.length,
        ruleId: _activeRuleId,
        scannedFiles: scanned,
        foundFiles: _uniqueFound,
        foundBytes: _uniqueBytes,
        errorCount: _issues.length,
        elapsed: _stopwatch.elapsed,
        workerCount: scannedOverride != null
            ? 1
            : _workers.where((worker) => !worker.done).length,
      ),
    );
  }

  void _acceptItems(List<JunkItem> items) {
    if (_finished || _limitReached) return;
    final accepted = <JunkItem>[];
    for (final item in items) {
      if (!_seenPaths.add(semantics.key(item.path))) continue;
      if (_options.maxItems != null && _uniqueFound >= _options.maxItems!) {
        _limitReached = true;
        break;
      }
      _uniqueFound++;
      _uniqueBytes += item.size;
      if (_retainItems) _resultItems.add(item);
      accepted.add(item);
    }
    if (accepted.isNotEmpty) _onItems?.call(accepted);
    if (_limitReached) {
      for (final worker in _workers) {
        worker.controlSendPort?.send(_ScanControl.cancel);
      }
    }
  }

  void _acceptIssue(ScanIssue issue) {
    if (_finished) return;
    _issues.add(issue);
    _onIssue?.call(issue);
  }

  void _handleWorkerDone(_WorkerHandle worker, ScanResult summary) {
    if (_finished) return;
    worker.done = true;
    worker.summary = summary;
    _maybeFinish();
  }

  void _maybeFinish() {
    if (_finished || !_workersReady) return;
    if (_workers.any((worker) => !worker.done)) return;
    var scannedFiles = 0;
    for (final worker in _workers) {
      scannedFiles += worker.summary?.scannedFiles ?? 0;
    }
    _finish(
      result: _composeResult(
        scannedFiles: scannedFiles,
        cancelled: _userCancelled,
      ),
    );
  }

  ScanResult _composeResult({
    required int scannedFiles,
    required bool cancelled,
    Duration? elapsed,
  }) {
    return ScanResult(
      items: _retainItems
          ? List<JunkItem>.unmodifiable(_resultItems)
          : const [],
      scannedFiles: scannedFiles,
      directoryErrors: _issues.length,
      truncated: _limitReached,
      cancelled: cancelled,
      issues: List<ScanIssue>.unmodifiable(_issues),
      elapsed: elapsed ?? _stopwatch.elapsed,
    );
  }

  void _fail(Object error) {
    _finish(error: error);
  }

  void _finish({ScanResult? result, Object? error}) {
    if (_finished) return;
    _finished = true;
    _inProcessCancel = true;
    final completer = _completer;
    _completer = null;
    _stopwatch.stop();

    for (final worker in _workers) {
      worker.isolate?.kill(priority: Isolate.immediate);
      worker.isolate = null;
      worker.eventSubscription?.cancel();
      worker.errorSubscription?.cancel();
      worker.exitSubscription?.cancel();
      worker.events?.close();
      worker.errors?.close();
      worker.exits?.close();
      worker.control?.close();
      worker.events = null;
      worker.errors = null;
      worker.exits = null;
      worker.control = null;
      worker.controlSendPort = null;
    }
    _workers.clear();
    _inProcessControl?.close();
    _inProcessControl = null;

    if (_priorityActive) {
      _priorityActive = false;
      unawaited(priorityController.endLowPriority());
    }

    if (completer == null || completer.isCompleted) return;
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(result);
    }
  }
}

void _scanWorkerEntry(_WorkerRequest request) async {
  // Platform channels, and therefore the native directory enumerator, need the
  // root isolate's messenger to be shared with this isolate. Without it the
  // scanner simply keeps using `Directory.list` plus `stat`.
  final token = request.rootIsolateToken;
  if (token != null) {
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    } catch (_) {
      // Enumeration falls back to dart:io when the messenger is unavailable.
    }
  }

  var cancelled = false;
  final control = ReceivePort();
  final subscription = control.listen((message) {
    if (message == _ScanControl.cancel) cancelled = true;
  });

  try {
    final scanner = JunkScanner(
      jobs: request.jobs,
      excludedPaths: request.excludedPaths,
      batchSize: request.batchSize,
      semantics: request.semantics,
      jobIndexBase: request.jobIndexBase,
      jobCountOverride: request.jobCount,
      useDetailedListing: request.useDetailedListing,
    );
    final result = await scanner.scan(
      retainItems: false,
      onProgress: (progress) => request.events.send(_WorkerProgress(progress)),
      onItems: (items) => request.events.send(_WorkerItems(items)),
      onIssue: (issue) => request.events.send(_WorkerIssue(issue)),
      isCancelled: () => cancelled,
    );
    Isolate.exit(request.events, _WorkerDone(result));
  } catch (error, stackTrace) {
    request.events.send(_WorkerFailed('$error\n$stackTrace'));
  } finally {
    await subscription.cancel();
    control.close();
  }
}

enum _ScanControl { cancel }

class _WorkerRequest {
  const _WorkerRequest({
    required this.jobs,
    required this.jobIndexBase,
    required this.jobCount,
    required this.excludedPaths,
    required this.batchSize,
    required this.semantics,
    required this.events,
    required this.control,
    this.rootIsolateToken,
    this.useDetailedListing = false,
  });

  final List<ScanJob> jobs;
  final int jobIndexBase;
  final int jobCount;
  final List<String> excludedPaths;
  final int batchSize;
  final PathSemantics semantics;
  final SendPort events;
  final SendPort control;
  final RootIsolateToken? rootIsolateToken;
  final bool useDetailedListing;
}

class _WorkerHandle {
  Isolate? isolate;
  ReceivePort? events;
  ReceivePort? errors;
  ReceivePort? exits;
  ReceivePort? control;
  SendPort? controlSendPort;
  // These subscriptions are cancelled together in `_closeWorker`.
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? eventSubscription;
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? errorSubscription;
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? exitSubscription;
  bool done = false;
  ScanProgress? progress;
  ScanResult? summary;
}

class _WorkerProgress {
  const _WorkerProgress(this.progress);

  final ScanProgress progress;
}

class _WorkerItems {
  const _WorkerItems(this.items);

  final List<JunkItem> items;
}

class _WorkerIssue {
  const _WorkerIssue(this.issue);

  final ScanIssue issue;
}

class _WorkerDone {
  const _WorkerDone(this.summary);

  final ScanResult summary;
}

class _WorkerFailed {
  const _WorkerFailed(this.message);

  final String message;
}
