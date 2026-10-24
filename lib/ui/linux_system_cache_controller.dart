import 'package:flutter/foundation.dart';

import '../core/platform/linux_system_maintenance.dart';
import '../l10n/broom_strings.dart';

enum LinuxSystemCachePhase { idle, cleaning, done }

/// Drives the Linux system-cache page.
///
/// Unlike the Windows per-file controller this one never scans directories: the
/// helper only exposes fixed operation ids, so the UI can only select
/// operations that the installed helper reported as available.
class LinuxSystemCacheController extends ChangeNotifier {
  LinuxSystemCacheController({required this.maintenance});

  final LinuxSystemMaintenance maintenance;

  LinuxSystemAvailability? _availability;
  LinuxSystemCachePhase _phase = LinuxSystemCachePhase.idle;
  bool _probing = false;
  bool _probed = false;
  Set<LinuxSystemOperation> _selected = <LinuxSystemOperation>{};
  LinuxSystemCleanupReport? _lastReport;
  String? _notice;
  String? _error;
  bool _disposed = false;

  LinuxSystemAvailability? get availability => _availability;
  LinuxSystemCapabilities? get capabilities => _availability?.capabilities;
  bool get isAvailable => _availability?.isAvailable ?? false;
  LinuxSystemUnavailableReason? get unavailableReason => _availability?.reason;
  String? get unavailableDetail => _availability?.detail;
  LinuxSystemCachePhase get phase => _phase;
  bool get probing => _probing;
  bool get probed => _probed;
  bool get cleaning => _phase == LinuxSystemCachePhase.cleaning;
  LinuxSystemCleanupReport? get lastReport => _lastReport;
  String? get notice => _notice;
  String? get error => _error;
  bool get isBusy => _probing || cleaning;

  /// Only operations the helper marked available may reach the UI. This keeps
  /// distro-specific tools such as DNF hidden on Debian and APT hidden on
  /// Fedora without hard-coding the distribution in Dart.
  List<LinuxSystemOperationCapability> get availableOperations {
    final values = capabilities?.operations;
    if (values == null) return const [];
    return [
      for (final capability in values)
        if (capability.available) capability,
    ];
  }

  List<LinuxSystemOperation> get selectedOperations {
    return [
      for (final operation in LinuxSystemOperation.values)
        if (_selected.contains(operation) &&
            (capabilities?.capabilityFor(operation)?.available ?? false))
          operation,
    ];
  }

  int get selectedCount => selectedOperations.length;

  bool isSelected(LinuxSystemOperation operation) =>
      _selected.contains(operation);

  bool isOperationAvailable(LinuxSystemOperation operation) =>
      capabilities?.capabilityFor(operation)?.available ?? false;

  Future<void> probe() async {
    if (_probing || cleaning) return;
    _probing = true;
    _phase = LinuxSystemCachePhase.idle;
    _lastReport = null;
    _error = null;
    _notice = null;
    _notify();
    try {
      _availability = await maintenance.probe();
    } catch (error) {
      _availability = LinuxSystemAvailability.unavailable(
        LinuxSystemUnavailableReason.helperFailed,
        detail: '$error',
      );
    } finally {
      _probing = false;
      _probed = true;
      _selected = selectedOperations.toSet();
      if (!isAvailable) _selected.clear();
      _notify();
    }
  }

  void toggleOperation(LinuxSystemOperation operation) {
    if (cleaning || !isOperationAvailable(operation)) return;
    if (!_selected.add(operation)) {
      _selected.remove(operation);
    }
    _notice = null;
    _notify();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected = <LinuxSystemOperation>{};
    _notify();
  }

  /// Resets the visible result and re-checks the helper, for example after a
  /// cleanup or after the helper was reinstalled.
  Future<void> refresh() async {
    if (cleaning) return;
    _phase = LinuxSystemCachePhase.idle;
    _lastReport = null;
    _selected = <LinuxSystemOperation>{};
    await probe();
  }

  Future<void> cleanSelected() async {
    if (cleaning || _probing) return;
    final operations = selectedOperations;
    if (operations.isEmpty) return;

    _phase = LinuxSystemCachePhase.cleaning;
    _lastReport = null;
    _error = null;
    _notice = null;
    _notify();

    try {
      _lastReport = await maintenance.clean(operations.toSet());
      _phase = LinuxSystemCachePhase.done;
    } on LinuxSystemMaintenanceException catch (failure) {
      _phase = LinuxSystemCachePhase.idle;
      if (failure.cancelled) {
        _notice = failure.message.isEmpty
            ? tr('已取消授权，未做任何更改。')
            : failure.message;
      } else if (_isMissingInstallation(failure.code)) {
        _selected = <LinuxSystemOperation>{};
        _availability = LinuxSystemAvailability.unavailable(
          _reasonForCode(failure.code),
          detail: failure.message,
        );
        _error = failure.message;
      } else {
        _error = failure.message;
      }
    } catch (failure) {
      _phase = LinuxSystemCachePhase.idle;
      _error = trf('系统清理失败：{error}', {'error': failure});
    } finally {
      _notify();
    }
  }

  void returnToIdle() {
    _phase = LinuxSystemCachePhase.idle;
    _lastReport = null;
    _notice = null;
    _error = null;
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

  static bool _isMissingInstallation(String? code) {
    return code == 'helper_missing' ||
        code == 'policy_missing' ||
        code == 'pkexec_missing';
  }

  static LinuxSystemUnavailableReason _reasonForCode(String? code) {
    return switch (code) {
      'policy_missing' => LinuxSystemUnavailableReason.policyMissing,
      'pkexec_missing' => LinuxSystemUnavailableReason.pkexecMissing,
      'helper_missing' => LinuxSystemUnavailableReason.helperMissing,
      _ => LinuxSystemUnavailableReason.helperFailed,
    };
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
