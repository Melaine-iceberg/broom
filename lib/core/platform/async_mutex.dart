import 'dart:async';

/// Serializes asynchronous work in FIFO order.
///
/// Used by [QuarantineService] so clean, resume, undo and purge cannot race on
/// the same session directory even if a caller bypasses the controller's phase
/// checks. Errors are never shared between waiters: each completed action
/// releases the next one in the queue.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// True while an action is running or waiting for its turn.
  bool get isBusy => _pending > 0;

  Future<T> run<T>(Future<T> Function() action) async {
    _pending++;
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      _pending--;
      release.complete();
    }
  }
}
