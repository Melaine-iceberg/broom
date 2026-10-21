import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/scan_models.dart';

class ScanWriterException implements Exception {
  const ScanWriterException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Encoded lines are coalesced into writes of at least this size.
///
/// Flushing once per 256-item append added one sink round-trip per batch
/// (~3,900 for a million items). The file is not published until `_Complete`
/// runs, so holding the tail in memory changes no observable semantics; small
/// scans simply flush their remaining bytes in `_Complete`.
const int _writeBufferBytes = 4 * 1024 * 1024;

/// Encodes and writes `items.jsonl` in a dedicated isolate.
///
/// The writer owns the [IOSink]; the calling isolate only ships
/// [JunkItem] batches and waits for the acknowledgement. Encoding 256-item
/// batches and flushing the sink used to run on the UI isolate for the whole
/// scan. The protocol is sequential: one outstanding request at a time.
class ScanWriterIsolate {
  ScanWriterIsolate._(
    this._isolate,
    this._inbox,
    this._replies,
    this._errors,
    this._exits,
  ) {
    _subscriptions = [
      _replies.listen(_handleReply),
      _errors.listen(_handleError),
      _exits.listen(_handleExit),
    ];
  }

  final Isolate _isolate;
  final SendPort _inbox;
  final ReceivePort _replies;
  final ReceivePort _errors;
  final ReceivePort _exits;
  late final List<StreamSubscription<Object?>> _subscriptions;

  final Map<int, Completer<_Reply>> _pending = {};
  int _nextId = 0;
  bool _shuttingDown = false;
  String? _failure;

  int bytesWritten = 0;
  int itemsWritten = 0;
  bool limited = false;
  String? error;

  static Future<ScanWriterIsolate> start({
    required String path,
    required ScanRoots roots,
    required int maxBytes,
  }) async {
    final ready = ReceivePort();
    final replies = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final isolate = await Isolate.spawn(
      _writerWorker,
      (ready.sendPort, replies.sendPort),
      onError: errors.sendPort,
      onExit: exits.sendPort,
      errorsAreFatal: true,
      debugName: 'broom-scan-writer',
    );
    final inbox = await ready.first as SendPort;
    ready.close();
    final worker = ScanWriterIsolate._(isolate, inbox, replies, errors, exits);
    try {
      final reply = await worker._send(
        (id) => _Open(id, path, roots, maxBytes),
      );
      worker._apply(reply);
      if (reply.fatalError != null) {
        throw ScanWriterException(reply.fatalError!);
      }
      return worker;
    } catch (_) {
      worker._shutdown();
      rethrow;
    }
  }

  Future<void> append(List<JunkItem> items) async {
    if (_failure != null) throw ScanWriterException(_failure!);
    if (limited || items.isEmpty) return;
    final reply = await _send((id) => _Append(id, items));
    _apply(reply);
  }

  Future<void> complete() async {
    if (_failure != null) throw ScanWriterException(_failure!);
    try {
      final reply = await _send(_Complete.new);
      _apply(reply);
      if (reply.fatalError != null) {
        throw ScanWriterException(reply.fatalError!);
      }
    } finally {
      _shutdown();
    }
  }

  Future<void> abort() async {
    if (_failure == null) {
      try {
        await _send(_Abort.new);
      } catch (_) {
        // Best effort; the caller deletes the directory.
      }
    }
    _shutdown();
  }

  Future<_Reply> _send(_Request Function(int id) build) {
    if (_failure != null) {
      return Future<_Reply>.error(ScanWriterException(_failure!));
    }
    final id = ++_nextId;
    final completer = Completer<_Reply>();
    _pending[id] = completer;
    _inbox.send(build(id));
    return completer.future;
  }

  void _handleReply(Object? message) {
    if (message is! _Reply) return;
    final completer = _pending.remove(message.id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
  }

  void _handleError(Object? message) {
    final text = switch (message) {
      List() when message.isNotEmpty => '${message.first}',
      _ => '$message',
    };
    _failAll('持久化 isolate 异常：$text');
  }

  void _handleExit(Object? message) {
    if (_shuttingDown) return;
    _failAll('持久化 isolate 已退出');
  }

  void _failAll(String message) {
    if (_failure != null) return;
    _failure = message;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(ScanWriterException(message));
      }
    }
    _pending.clear();
    _shutdown();
  }

  void _apply(_Reply reply) {
    bytesWritten = reply.bytesWritten;
    itemsWritten = reply.itemsWritten;
    limited = reply.limited;
    if (reply.error != null) {
      error = reply.error;
      limited = true;
    }
  }

  void _shutdown() {
    if (_shuttingDown) return;
    _shuttingDown = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _replies.close();
    _errors.close();
    _exits.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

sealed class _Request {
  const _Request(this.id);

  final int id;
}

class _Open extends _Request {
  const _Open(super.id, this.path, this.roots, this.maxBytes);

  final String path;
  final ScanRoots roots;
  final int maxBytes;
}

class _Append extends _Request {
  const _Append(super.id, this.items);

  final List<JunkItem> items;
}

class _Complete extends _Request {
  const _Complete(super.id);
}

class _Abort extends _Request {
  const _Abort(super.id);
}

class _Reply {
  const _Reply(
    this.id, {
    required this.bytesWritten,
    required this.itemsWritten,
    required this.limited,
    this.error,
    this.fatalError,
  });

  final int id;
  final int bytesWritten;
  final int itemsWritten;
  final bool limited;
  final String? error;
  final String? fatalError;
}

Future<void> _writerWorker((SendPort, SendPort) ports) async {
  final (ready, replies) = ports;
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);

  IOSink? sink;
  ScanRoots? roots;
  var maxBytes = 0;
  var bytesWritten = 0;
  var itemsWritten = 0;
  var limited = false;
  String? error;
  var pending = BytesBuilder(copy: false);

  Future<void> flushPending(IOSink target) async {
    try {
      target.add(pending.takeBytes());
      await target.flush();
    } on FileSystemException catch (failure) {
      error = failure.message;
      limited = true;
    }
  }

  void reply(int id, {String? fatalError}) {
    replies.send(
      _Reply(
        id,
        bytesWritten: bytesWritten,
        itemsWritten: itemsWritten,
        limited: limited,
        error: error,
        fatalError: fatalError,
      ),
    );
  }

  await for (final message in inbox) {
    switch (message) {
      case _Open(
        :final id,
        path: final openPath,
        roots: final openRoots,
        maxBytes: final openMaxBytes,
      ):
        try {
          sink = File(openPath).openWrite();
        } on FileSystemException catch (failure) {
          error = failure.message;
          limited = true;
          reply(id, fatalError: failure.message);
          continue;
        }
        roots = openRoots;
        maxBytes = openMaxBytes;
        error = null;
        limited = false;
        bytesWritten = 0;
        itemsWritten = 0;
        pending = BytesBuilder(copy: false);
        reply(id);
      case _Append(:final id, :final items):
        final activeSink = sink;
        if (activeSink == null) {
          reply(id, fatalError: '扫描结果写入器尚未打开');
          continue;
        }
        if (limited || items.isEmpty) {
          reply(id);
          continue;
        }
        for (final item in items) {
          final root = roots!.at(item.rootIndex);
          final line = jsonEncode({
            'ruleId': root.ruleId,
            'rootPath': root.rootPath,
            'path': item.path,
            'size': item.size,
            'modified': DateTime.fromMicrosecondsSinceEpoch(item.modifiedMicros)
                .toUtc()
                .toIso8601String(),
          });
          final lineBytes = utf8.encode(line);
          final cost = lineBytes.length + 1;
          if (bytesWritten + cost > maxBytes) {
            limited = true;
            break;
          }
          pending
            ..add(lineBytes)
            ..addByte(0x0A);
          bytesWritten += cost;
          itemsWritten++;
        }
        if (pending.length >= _writeBufferBytes) {
          await flushPending(activeSink);
        }
        reply(id);
      case _Complete(:final id):
        String? fatalError;
        final activeSink = sink;
        try {
          if (activeSink != null && pending.isNotEmpty) {
            activeSink.add(pending.takeBytes());
          }
          await activeSink?.flush();
          await activeSink?.close();
        } on FileSystemException catch (failure) {
          fatalError = failure.message;
        }
        pending = BytesBuilder(copy: false);
        sink = null;
        reply(id, fatalError: fatalError);
      case _Abort(:final id):
        try {
          await sink?.close();
        } on FileSystemException {
          // Best effort; the caller deletes the directory.
        }
        pending = BytesBuilder(copy: false);
        sink = null;
        limited = true;
        reply(id);
    }
  }
}
