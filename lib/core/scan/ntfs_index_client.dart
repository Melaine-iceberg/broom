import 'dart:async';

import 'package:flutter/services.dart';

import 'ntfs_index.dart';

class NtfsIndexException implements Exception {
  const NtfsIndexException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Bidirectional channel client for the native NTFS USN index.
///
/// Native code pushes `batch` / `done` calls back on the same channel after
/// `start` returns. Results are bound to the root isolate, which is why the
/// scan coordinator runs indexed scans itself instead of inside a worker.
class NtfsIndexClient implements NtfsIndex {
  factory NtfsIndexClient({
    MethodChannel channel = const MethodChannel('broom/ntfs_index'),
  }) => NtfsIndexClient._(channel);

  NtfsIndexClient._(this._channel) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  final Map<int, StreamController<NtfsIndexEntry>> _requests = {};
  final Map<String, NtfsIndexAvailability> _probeCache = {};
  int _nextId = 1;
  bool _disposed = false;

  @override
  Future<NtfsIndexAvailability> probe(String root) async {
    final cached = _probeCache[root.toLowerCase()];
    if (cached != null) return cached;
    NtfsIndexAvailability availability;
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'probe',
        {'root': root},
      );
      availability = _parseAvailability(response);
    } on MissingPluginException {
      availability = const NtfsIndexAvailability(
        NtfsIndexStatus.unsupported,
        message: '当前运行环境不支持 NTFS 索引',
      );
    } on PlatformException catch (error) {
      availability = NtfsIndexAvailability(
        NtfsIndexStatus.error,
        message: error.message ?? error.code,
      );
    }
    _probeCache[root.toLowerCase()] = availability;
    return availability;
  }

  NtfsIndexAvailability _parseAvailability(Map<String, dynamic>? value) {
    if (value == null) {
      return const NtfsIndexAvailability(
        NtfsIndexStatus.error,
        message: 'NTFS 索引探测没有返回结果',
      );
    }
    final status = switch (value['status']) {
      'available' => NtfsIndexStatus.available,
      'not_ntfs' => NtfsIndexStatus.notNtfs,
      'unprivileged' => NtfsIndexStatus.unprivileged,
      'journal_inactive' => NtfsIndexStatus.journalInactive,
      'unsupported' => NtfsIndexStatus.unsupported,
      _ => NtfsIndexStatus.error,
    };
    return NtfsIndexAvailability(
      status,
      message: value['message'] is String ? value['message'] as String : null,
    );
  }

  @override
  Stream<NtfsIndexEntry> enumerate(
    String root, {
    Set<String>? extensions,
    int? maxItems,
    bool Function()? isCancelled,
  }) {
    if (_disposed) return const Stream.empty();
    final id = _nextId++;
    final controller = StreamController<NtfsIndexEntry>();
    _requests[id] = controller;
    controller
      ..onListen = () async {
        try {
          await _channel.invokeMethod<void>('start', {
            'requestId': id,
            'roots': [root],
            'extensions': extensions?.toList(),
            'maxItems': maxItems,
          });
        } on MissingPluginException {
          _finish(id, controller, NtfsIndexException('当前运行环境不支持 NTFS 索引'));
        } on PlatformException catch (error) {
          _finish(
            id,
            controller,
            NtfsIndexException(error.message ?? error.code),
          );
        }
      }
      ..onCancel = () {
        _requests.remove(id);
        unawaited(_cancelNative(id));
      };
    if (isCancelled != null) {
      final timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (isCancelled()) {
          _requests.remove(id);
          unawaited(_cancelNative(id));
          controller.close();
        }
      });
      controller.onCancel = () {
        timer.cancel();
        _requests.remove(id);
        unawaited(_cancelNative(id));
      };
      controller.done.whenComplete(timer.cancel);
    }
    return controller.stream;
  }

  Future<void> _cancelNative(int id) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'requestId': id});
    } on PlatformException {
      // Cancellation is best effort.
    } on MissingPluginException {
      // Ignore.
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'batch' && call.method != 'done') {
      throw MissingPluginException();
    }
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final id = arguments['requestId'];
    if (id is! int) return;
    final controller = _requests[id];
    if (controller == null) return;

    if (call.method == 'batch') {
      final rawPaths = arguments['paths'];
      if (rawPaths is List) {
        for (final path in rawPaths) {
          if (path is String && path.isNotEmpty) {
            controller.add(NtfsIndexEntry(path));
          }
        }
      }
      return;
    }

    final error = arguments['error'];
    if (error is String && error.isNotEmpty) {
      _finish(id, controller, NtfsIndexException(error));
    } else {
      _finish(id, controller, null);
    }
  }

  void _finish(
    int id,
    StreamController<NtfsIndexEntry> controller,
    Object? error,
  ) {
    _requests.remove(id);
    if (error != null) {
      controller.addError(error);
    }
    unawaited(controller.close());
  }

  void dispose() {
    _disposed = true;
    for (final entry in _requests.entries) {
      unawaited(_cancelNative(entry.key));
      unawaited(entry.value.close());
    }
    _requests.clear();
    _channel.setMethodCallHandler(null);
  }
}
