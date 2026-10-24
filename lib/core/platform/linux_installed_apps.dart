import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/leftover_models.dart';
import 'installed_apps.dart';
import 'path_semantics.dart';

typedef LinuxProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Read-only Linux application inventory.
///
/// Package managers are queried with fixed executables and arguments; no user
/// input reaches a command line and nothing is installed or removed. A package
/// manager that exists but fails makes the inventory incomplete, which makes
/// leftover detection fail closed instead of guessing that an app is gone.
class LinuxInstalledApps implements InstalledApps {
  LinuxInstalledApps({
    Map<String, String>? environment,
    PathSemantics? semantics,
    LinuxProcessRunner? runner,
    this.availableExecutables,
    this.timeout = const Duration(seconds: 10),
  }) : _environment = {
         for (final entry in (environment ?? Platform.environment).entries)
           entry.key: entry.value,
       },
       _semantics = semantics ?? const PosixPathSemantics(),
       _runner = runner ?? _runProcess;

  final Map<String, String> _environment;
  final PathSemantics _semantics;
  final LinuxProcessRunner _runner;
  final Set<String>? availableExecutables;
  final Duration timeout;

  @override
  Future<InstalledAppInventory> list() async {
    final apps = <String, InstalledApp>{};
    final errors = <String>[];

    Future<void> collect(
      String executable,
      List<String> arguments,
      void Function(String output) parse,
    ) async {
      if (!_isAvailable(executable)) return;
      try {
        final result = await _runner(executable, arguments).timeout(timeout);
        if (result.exitCode != 0) {
          final detail = _stderrSummary(result.stderr);
          errors.add(
            '${_semantics.basename(executable)} 退出码 ${result.exitCode}'
            '${detail.isEmpty ? '' : '：$detail'}',
          );
          return;
        }
        parse(
          result.stdout is String ? result.stdout as String : '$result.stdout',
        );
      } on TimeoutException {
        errors.add('${_semantics.basename(executable)} 读取超时');
      } on ProcessException catch (error) {
        errors.add('${_semantics.basename(executable)} 无法执行：${error.message}');
      } on FormatException catch (error) {
        errors.add('${_semantics.basename(executable)} 输出无效：${error.message}');
      } catch (error) {
        errors.add('${_semantics.basename(executable)} 读取失败：$error');
      }
    }

    await collect('/usr/bin/dpkg-query', const [
      '-W',
      r'-f=${db:Status-Abbrev}\t${Package}\t${Version}\n',
    ], (output) => _parseDpkg(output, apps));
    await collect('/usr/bin/rpm', const [
      '-qa',
      r'--qf',
      r'%{NAME}\t%{VERSION}\n',
    ], (output) => _parseRpm(output, apps));
    await collect('/usr/bin/flatpak', const [
      'list',
      '--app',
      '--columns=application,name,origin',
    ], (output) => _parseFlatpak(output, apps));
    await collect('/usr/bin/snap', const [
      'list',
    ], (output) => _parseSnap(output, apps));

    await _collectDesktopEntries(apps);

    return InstalledAppInventory(
      apps: List.unmodifiable(apps.values),
      complete: errors.isEmpty,
      error: errors.isEmpty ? null : errors.join('；'),
    );
  }

  bool _isAvailable(String executable) {
    final available = availableExecutables;
    if (available != null) return available.contains(executable);
    return File(executable).existsSync();
  }

  void _parseDpkg(String output, Map<String, InstalledApp> apps) {
    for (final line in const LineSplitter().convert(output)) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length < 2) {
        throw FormatException('dpkg-query 行格式无效：$line');
      }
      // Status-Abbrev has three positions; only `ii` means installed.
      if (!parts[0].trim().startsWith('ii')) continue;
      final package = parts[1].trim();
      if (package.isEmpty) throw const FormatException('dpkg-query 缺少包名');
      apps['dpkg:$package'] = InstalledApp(
        displayName: package,
        publisher: 'dpkg',
        uninstallKey: 'dpkg:$package',
        scope: InstalledAppScope.machine,
      );
    }
  }

  void _parseRpm(String output, Map<String, InstalledApp> apps) {
    for (final line in const LineSplitter().convert(output)) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length < 2 || parts[0].trim().isEmpty) {
        throw FormatException('rpm 行格式无效：$line');
      }
      final package = parts[0].trim();
      apps['rpm:$package'] = InstalledApp(
        displayName: package,
        publisher: 'rpm',
        uninstallKey: 'rpm:$package',
        scope: InstalledAppScope.machine,
      );
    }
  }

  void _parseFlatpak(String output, Map<String, InstalledApp> apps) {
    for (final line in const LineSplitter().convert(output)) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      if (parts.isEmpty || parts[0].trim().isEmpty) {
        throw FormatException('flatpak 行格式无效：$line');
      }
      final id = parts[0].trim();
      if (id.toLowerCase() == 'application') continue;
      final name = parts.length > 1 && parts[1].trim().isNotEmpty
          ? parts[1].trim()
          : id;
      apps['flatpak:$id'] = InstalledApp(
        displayName: name,
        publisher: 'flatpak',
        uninstallKey: 'flatpak:$id',
        scope: InstalledAppScope.unknown,
      );
    }
  }

  void _parseSnap(String output, Map<String, InstalledApp> apps) {
    final lines = const LineSplitter().convert(output);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      // The first non-empty line is the table header.
      if (index == 0 ||
          line.toLowerCase().startsWith('name ') ||
          line.toLowerCase() == 'name') {
        continue;
      }
      final parts = line.split(RegExp(r'\s+'));
      final name = parts.first.trim();
      if (name.isEmpty) throw FormatException('snap 行格式无效：$line');
      apps['snap:$name'] = InstalledApp(
        displayName: name,
        publisher: 'snap',
        uninstallKey: 'snap:$name',
        scope: InstalledAppScope.unknown,
      );
    }
  }

  Future<void> _collectDesktopEntries(Map<String, InstalledApp> apps) async {
    for (final directory in _desktopDirectories()) {
      final Directory entries;
      try {
        entries = Directory(directory);
        if (!await entries.exists()) continue;
        await for (final entity in entries.list(followLinks: false)) {
          if (entity is! File || !entity.path.endsWith('.desktop')) continue;
          final entry = await _parseDesktopEntry(entity);
          if (entry == null) continue;
          apps.putIfAbsent(entry.uninstallKey!, () => entry);
        }
      } on FileSystemException {
        // Desktop files supplement package inventories. An unreadable data
        // directory must not make every installed app look orphaned.
        continue;
      }
    }
  }

  Future<InstalledApp?> _parseDesktopEntry(File file) async {
    final List<String> lines;
    try {
      lines = await file.readAsLines();
    } on FileSystemException {
      return null;
    }

    var inDesktopEntry = false;
    String? name;
    String? flatpakId;
    String? snapName;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        if (inDesktopEntry) break;
        inDesktopEntry = trimmed == '[Desktop Entry]';
        continue;
      }
      if (!inDesktopEntry || trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      final key = trimmed.substring(0, separator).trim();
      final value = trimmed.substring(separator + 1).trim();
      switch (key) {
        case 'Name':
          if (name == null || name.isEmpty) name = value;
        case 'X-Flatpak':
          flatpakId = value;
        case 'X-SnapInstanceName':
          snapName = value;
      }
    }

    if (name == null || name.isEmpty) return null;
    final fileId = _semantics.basename(file.path);
    final userRoot = _environment['XDG_DATA_HOME'];
    final normalizedRoot = userRoot == null
        ? null
        : _semantics.normalize(userRoot);
    final normalizedPath = _semantics.normalize(file.path);
    final isUser =
        normalizedRoot != null &&
        (normalizedPath == normalizedRoot ||
            normalizedPath.startsWith('$normalizedRoot/'));
    final key = flatpakId != null && flatpakId.isNotEmpty
        ? 'flatpak:$flatpakId'
        : snapName != null && snapName.isNotEmpty
        ? 'snap:$snapName'
        : 'desktop:$fileId';
    return InstalledApp(
      displayName: name,
      publisher: 'desktop',
      installLocation: file.path,
      uninstallKey: key,
      scope: isUser ? InstalledAppScope.user : InstalledAppScope.machine,
    );
  }

  Iterable<String> _desktopDirectories() sync* {
    final home = _environment['HOME'];
    final dataHome =
        _environment['XDG_DATA_HOME'] ??
        (home == null ? null : _semantics.join(home, '.local/share'));
    if (dataHome != null && dataHome.isNotEmpty) {
      yield _semantics.join(dataHome, 'applications');
    }

    final configured = _environment['XDG_DATA_DIRS'];
    final dataDirs = (configured == null || configured.trim().isEmpty)
        ? const ['/usr/local/share', '/usr/share']
        : configured.split(':');
    for (final directory in dataDirs) {
      if (directory.trim().isEmpty) continue;
      yield _semantics.join(directory.trim(), 'applications');
    }
  }

  static String _stderrSummary(Object? stderr) {
    if (stderr is! String) return '';
    final trimmed = stderr.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.length <= 200 ? trimmed : '${trimmed.substring(0, 200)}…';
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(
      executable,
      arguments,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }
}
