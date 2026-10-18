import 'dart:async';
import 'dart:isolate';

import '../models/scan_models.dart';
import 'junk_scanner.dart';

class ScanService {
  Isolate? _isolate;
  ReceivePort? _eventPort;
  ReceivePort? _errorPort;
  ReceivePort? _exitPort;
  ReceivePort? _controlPort;
  SendPort? _controlSendPort;
  StreamSubscription<dynamic>? _eventSubscription;
  StreamSubscription<dynamic>? _errorSubscription;
  StreamSubscription<dynamic>? _exitSubscription;
  Completer<ScanResult>? _completer;
  bool _finished = false;
  bool _cancelRequested = false;

  bool get isRunning => _completer != null && !_finished;

  Future<ScanResult> scan({
    required List<ScanJob> jobs,
    required List<String> excludedPaths,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    if (isRunning) {
      throw StateError('A scan is already running.');
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

    final completer = Completer<ScanResult>();
    _completer = completer;

    try {
      _isolate = await Isolate.spawn(
        _scanEntry,
        _ScanRequest(
          jobs: jobs,
          excludedPaths: excludedPaths,
          events: events.sendPort,
          control: control.sendPort,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
        debugName: 'broom-junk-scan',
      );
    } catch (error) {
      _finish(error: error);
      return completer.future;
    }

    _eventSubscription = events.listen((message) {
      switch (message) {
        case ScanProgress():
          onProgress?.call(message);
        case _ScanDone():
          _finish(result: message.result);
        case _ScanFailed():
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
          _finish(
            error: StateError(
              _cancelRequested ? '扫描已取消' : '扫描进程意外退出',
            ),
          );
        }
      });
    });

    return completer.future;
  }

  void cancel() {
    if (!isRunning) return;
    _cancelRequested = true;
    _controlSendPort?.send(_ScanControl.cancel);
  }

  void dispose() {
    if (_finished) return;
    _finished = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    final completer = _completer;
    _completer = null;
    _release();
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('扫描已中止'));
    }
  }

  void _finish({ScanResult? result, Object? error}) {
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
      completer.complete(result);
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

void _scanEntry(_ScanRequest request) async {
  var cancelled = false;
  final control = ReceivePort();
  final subscription = control.listen((message) {
    if (message == _ScanControl.cancel) cancelled = true;
  });

  try {
    final scanner = JunkScanner(
      jobs: request.jobs,
      excludedPaths: request.excludedPaths,
    );
    final result = await scanner.scan(
      onProgress: (progress) => request.events.send(progress),
      isCancelled: () => cancelled,
    );
    Isolate.exit(request.events, _ScanDone(result));
  } catch (error, stackTrace) {
    request.events.send(_ScanFailed('$error\n$stackTrace'));
  } finally {
    subscription.cancel();
    control.close();
  }
}

enum _ScanControl { cancel }

class _ScanRequest {
  const _ScanRequest({
    required this.jobs,
    required this.excludedPaths,
    required this.events,
    required this.control,
  });

  final List<ScanJob> jobs;
  final List<String> excludedPaths;
  final SendPort events;
  final SendPort control;
}

class _ScanDone {
  const _ScanDone(this.result);

  final ScanResult result;
}

class _ScanFailed {
  const _ScanFailed(this.message);

  final String message;
}
