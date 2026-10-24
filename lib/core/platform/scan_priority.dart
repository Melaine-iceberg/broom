import 'package:flutter/services.dart';

/// Lowers the process/thread priority while a scan runs.
///
/// Windows drops to below-normal CPU priority; Linux lowers both CPU (`nice`)
/// and block-device I/O (`ionice`) priority. Both are best effort and must
/// never prevent a scan from starting.
abstract interface class ScanPriorityController {
  Future<String?> beginLowPriority();
  Future<void> endLowPriority();
}

class NoopScanPriorityController implements ScanPriorityController {
  const NoopScanPriorityController();

  @override
  Future<String?> beginLowPriority() async => null;

  @override
  Future<void> endLowPriority() async {}
}

class MethodChannelScanPriorityController implements ScanPriorityController {
  const MethodChannelScanPriorityController([
    this._channel = const MethodChannel('broom/scan_priority'),
  ]);

  final MethodChannel _channel;

  @override
  Future<String?> beginLowPriority() async {
    try {
      final value = await _channel.invokeMethod<String>('begin');
      return value;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> endLowPriority() async {
    try {
      await _channel.invokeMethod<void>('end');
    } on PlatformException {
      // Priority restoration is best effort and must never fail a scan.
    } on MissingPluginException {
      // Channel unavailable on unsupported platforms / tests.
    }
  }
}
