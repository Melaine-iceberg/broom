import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

/// Best-effort preview signal for files that another process is using in a way
/// that blocks a move or delete. A positive result is advisory: it can change
/// between preview and cleanup, and cleanup always reports the real outcome.
abstract interface class FileLockProbe {
  Future<List<bool>> probePossiblyLocked(List<String> paths);
}

class NoopFileLockProbe implements FileLockProbe {
  const NoopFileLockProbe();

  @override
  Future<List<bool>> probePossiblyLocked(List<String> paths) async =>
      List<bool>.filled(paths.length, false);
}

class FileLockProbeException implements Exception {
  const FileLockProbeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MethodChannelFileLockProbe implements FileLockProbe {
  const MethodChannelFileLockProbe();

  static const channel = MethodChannel('broom/file_lock');

  @override
  Future<List<bool>> probePossiblyLocked(List<String> paths) async {
    if (paths.isEmpty) return const [];
    try {
      final values = await channel.invokeListMethod<bool>('probe', {
        'paths': paths,
      });
      if (values == null || values.length != paths.length) {
        throw const FileLockProbeException('占用检测结果不完整');
      }
      return [for (final value in values) value];
    } on MissingPluginException {
      throw const FileLockProbeException('当前系统不支持文件占用检测');
    } on PlatformException catch (error) {
      throw FileLockProbeException('文件占用检测失败：${error.message ?? error.code}');
    }
  }
}

FileLockProbe createFileLockProbe() => Platform.isWindows
    ? const MethodChannelFileLockProbe()
    : const NoopFileLockProbe();

/// Probes [paths] in batches and reports locked paths. Probe errors stop the
/// run silently: the preview stays usable and cleanup still classifies every
/// file. Returns the number of paths for which a result was received.
Future<int> runLockProbe({
  required FileLockProbe probe,
  required List<String> paths,
  required bool Function() isActive,
  required Future<void> Function(List<String> lockedPaths, int checked)?
  onBatch,
  int batchSize = 512,
}) async {
  assert(batchSize > 0);
  var checked = 0;
  for (var start = 0; start < paths.length; start += batchSize) {
    if (!isActive()) return checked;
    final end = min(start + batchSize, paths.length);
    final batch = paths.sublist(start, end);
    List<bool> results;
    try {
      results = await probe.probePossiblyLocked(batch);
    } catch (_) {
      return checked;
    }
    if (!isActive()) return checked;
    final locked = <String>[
      for (var index = 0; index < batch.length; index++)
        if (results[index]) batch[index],
    ];
    checked = end;
    await onBatch?.call(locked, checked);
  }
  return checked;
}
