import 'dart:async';
import 'dart:io';

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class ServiceControlException implements Exception {
  const ServiceControlException(this.serviceName, this.message);

  final String serviceName;
  final String message;

  @override
  String toString() {
    if (serviceName.isEmpty) return 'Windows 服务操作失败：$message';
    return 'Windows 服务 $serviceName 操作失败：$message';
  }
}

abstract interface class ServiceControl {
  /// Stops the requested services and returns those that were actually
  /// stopped, so callers only restart services they changed.
  Future<Set<String>> stopServices(Iterable<String> names);

  /// Attempts to start services and returns human-readable issues.
  Future<List<String>> startServices(Iterable<String> names);
}

class WindowsServiceManager implements ServiceControl {
  WindowsServiceManager({
    ProcessRunner? runner,
    this.stopTimeout = const Duration(seconds: 20),
    this.pollInterval = const Duration(milliseconds: 300),
  }) : _runner = runner ?? _runProcess;

  final ProcessRunner _runner;
  final Duration stopTimeout;
  final Duration pollInterval;

  static const _stopped = 1;
  static const _startPending = 2;
  static const _stopPending = 3;
  static const _running = 4;
  static const _continuePending = 5;
  static const _pausePending = 6;
  static const _paused = 7;

  static final RegExp _serviceNamePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$',
  );
  static final RegExp _statePattern = RegExp(
    r'(?:STATE|状态)\s*:\s*(\d+)',
    caseSensitive: false,
  );
  static final RegExp _numericStatePattern = RegExp(r':\s*([1-7])\s+');

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments, runInShell: false);
  }

  @override
  Future<Set<String>> stopServices(Iterable<String> names) async {
    final ordered = _unique(names);
    final stopped = <String>{};
    try {
      for (final name in ordered) {
        _validateName(name);
        if (await _stopOne(name)) {
          stopped.add(name);
        }
      }
      return stopped;
    } catch (error) {
      final recoveryIssues = await _startInternal(stopped);
      if (recoveryIssues.isNotEmpty) {
        final suffix = '已停止的服务无法恢复：${recoveryIssues.join('；')}';
        if (error is ServiceControlException) {
          throw ServiceControlException(
            error.serviceName,
            '${error.message}。$suffix',
          );
        }
        throw ServiceControlException('', '$error。$suffix');
      }
      rethrow;
    }
  }

  @override
  Future<List<String>> startServices(Iterable<String> names) async {
    final ordered = <String>[];
    for (final name in _unique(names)) {
      _validateName(name);
      ordered.add(name);
    }
    return _startInternal(ordered);
  }

  Future<bool> _stopOne(String name) async {
    var state = await _queryState(name);
    if (state == null || state == _stopped) return false;

    if (state == _stopPending) {
      final finalState = await _waitForState(name, {_stopped});
      if (finalState == _stopped) return true;
      throw ServiceControlException(
        name,
        '服务未能在限定时间内停止（当前状态 ${_stateLabel(finalState)}）。',
      );
    }

    if (state == _startPending ||
        state == _continuePending ||
        state == _pausePending) {
      final settled = await _waitForState(name, {_stopped, _running, _paused});
      if (settled == _stopped) return true;
      if (settled == null) {
        throw ServiceControlException(name, '服务在等待期间消失了。');
      }
    }

    final result = await _runSc(name, ['stop', name]);
    if (result.exitCode != 0 &&
        result.exitCode != 1061 &&
        result.exitCode != 1062) {
      throw ServiceControlException(name, _scFailure(result));
    }

    final finalState = await _waitForState(name, {_stopped});
    if (finalState != _stopped) {
      throw ServiceControlException(
        name,
        '服务未能在限定时间内停止（当前状态 ${_stateLabel(finalState)}）。',
      );
    }
    return true;
  }

  Future<List<String>> _startInternal(Iterable<String> names) async {
    final issues = <String>[];
    for (final name in names) {
      try {
        final result = await _runSc(name, ['start', name]);
        if (result.exitCode != 0 && result.exitCode != 1056) {
          issues.add('$name：${_scFailure(result)}');
        }
      } on ServiceControlException catch (error) {
        issues.add('$name：${error.message}');
      }
    }
    return issues;
  }

  Future<int?> _queryState(String name) async {
    final result = await _runSc(name, ['query', name]);
    if (result.exitCode == 1060) return null;
    if (result.exitCode != 0) {
      throw ServiceControlException(name, _scFailure(result));
    }
    final output = '${result.stdout}\n${result.stderr}';
    final match =
        _statePattern.firstMatch(output) ??
        _numericStatePattern.firstMatch(output);
    final state = match == null ? null : int.tryParse(match.group(1)!);
    if (state == null) {
      throw ServiceControlException(name, '无法解析 Windows 服务状态。');
    }
    return state;
  }

  Future<int?> _waitForState(String name, Set<int> targets) async {
    final deadline = DateTime.now().add(stopTimeout);
    while (true) {
      final state = await _queryState(name);
      if (state == null) return null;
      if (targets.contains(state)) return state;
      if (!DateTime.now().isBefore(deadline)) return state;
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<ProcessResult> _runSc(String name, List<String> arguments) async {
    try {
      return await _runner('sc.exe', arguments);
    } on ServiceControlException {
      rethrow;
    } catch (error) {
      throw ServiceControlException(name, '无法调用 Windows 服务管理器：$error');
    }
  }

  static void _validateName(String name) {
    if (!_serviceNamePattern.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', '非法的 Windows 服务名');
    }
  }

  static List<String> _unique(Iterable<String> names) {
    final seen = <String>{};
    return [
      for (final name in names)
        if (seen.add(name)) name,
    ];
  }

  static String _stateLabel(int? state) => switch (state) {
    null => '服务不存在',
    _stopped => '已停止',
    _startPending => '正在启动',
    _stopPending => '正在停止',
    _running => '运行中',
    _continuePending => '正在恢复',
    _pausePending => '正在暂停',
    _paused => '已暂停',
    _ => '未知（$state）',
  };

  static String _scFailure(ProcessResult result) {
    final detail = _firstLine(result.stderr) ?? _firstLine(result.stdout);
    final reason = switch (result.exitCode) {
      5 => '没有访问权限',
      1058 => '服务已被禁用',
      1060 => '服务不存在',
      1061 => '服务目前无法接受控制命令',
      1062 => '服务没有运行',
      _ => 'Windows 服务命令执行失败（退出码 ${result.exitCode}）',
    };
    return detail == null ? reason : '$reason：$detail';
  }

  static String? _firstLine(String text) {
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      return trimmed.length > 240 ? '${trimmed.substring(0, 240)}…' : trimmed;
    }
    return null;
  }
}
