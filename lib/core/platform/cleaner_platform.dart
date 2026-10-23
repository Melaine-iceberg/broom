import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/cleaner_rule.dart';
import '../rules/linux_rules.dart';
import '../rules/windows_rules.dart';
import 'path_semantics.dart';
import 'windows_rule_resolver.dart';

abstract interface class CleanerPlatform {
  bool get isSupported;
  String get displayName;
  String? get quarantineRoot;
  Map<String, String> get environment;
  List<CleanerRule> get rules;

  /// Path semantics used by every path-consuming engine component.
  PathSemantics get pathSemantics;

  /// Directories no cleanup target may ever fall into.
  List<String> get protectedRoots;

  /// Identifies the active rule catalog (built-in or a verified online
  /// update). Persisted scan results are considered stale when this changes.
  String get rulesVersion;
  Future<List<String>> resolveRoots(CleanerRule rule);
}

class WindowsCleanerPlatform implements CleanerPlatform {
  factory WindowsCleanerPlatform({
    Map<String, String>? environment,
    List<CleanerRule>? rules,
    String rulesVersion = 'builtin',
  }) {
    return WindowsCleanerPlatform._(
      environment ?? Platform.environment,
      rules ?? windowsCleanupRules,
      rulesVersion,
    );
  }

  WindowsCleanerPlatform._(
    this.environment,
    List<CleanerRule> rules,
    this._rulesVersion,
  ) : _rules = List.unmodifiable(rules) {
    _resolver = WindowsRuleResolver(environment: environment);
  }

  @override
  final Map<String, String> environment;
  late final WindowsRuleResolver _resolver;
  List<CleanerRule> _rules;
  String _rulesVersion;

  @override
  bool get isSupported => Platform.isWindows;

  @override
  String get displayName => 'Windows';

  @override
  PathSemantics get pathSemantics => const WindowsPathSemantics();

  @override
  List<String> get protectedRoots => [
    for (final name in const [
      'WINDIR',
      'ProgramFiles',
      'ProgramFiles(x86)',
      'ProgramData',
    ])
      ?_lookup(name),
  ];

  @override
  List<CleanerRule> get rules => _rules;

  @override
  String get rulesVersion => _rulesVersion;

  void applyRuleCatalog(List<CleanerRule> rules, String version) {
    _rules = List.unmodifiable(rules);
    _rulesVersion = version;
  }

  @override
  String? get quarantineRoot {
    final localAppData = _lookup('LOCALAPPDATA');
    if (localAppData != null) {
      return p.windows.join(localAppData, 'Broom', 'quarantine');
    }
    final userProfile = _lookup('USERPROFILE');
    if (userProfile != null) {
      return p.windows.join(
        userProfile,
        'AppData',
        'Local',
        'Broom',
        'quarantine',
      );
    }
    return null;
  }

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) =>
      _resolver.resolve(rule);

  String? _lookup(String name) {
    final value =
        environment[name] ??
        environment.entries
            .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
            .map((entry) => entry.value)
            .firstOrNull;
    return value == null || value.isEmpty ? null : value;
  }
}

/// Linux platform using the XDG Base Directory layout.
///
/// [environment] is normalized with the XDG defaults so rule patterns can
/// reference `$XDG_CACHE_HOME`, `$XDG_CONFIG_HOME` and `$XDG_DATA_HOME` even
/// when those variables are not explicitly set by the desktop session.
class LinuxCleanerPlatform implements CleanerPlatform {
  factory LinuxCleanerPlatform({
    Map<String, String>? environment,
    List<CleanerRule>? rules,
    String rulesVersion = 'builtin-linux-2',
  }) {
    final env = {
      for (final entry in (environment ?? Platform.environment).entries)
        entry.key: entry.value,
    };
    final home = _nonEmpty(env['HOME']);
    if (home != null) {
      env.putIfAbsent('XDG_CACHE_HOME', () => p.posix.join(home, '.cache'));
      env.putIfAbsent('XDG_CONFIG_HOME', () => p.posix.join(home, '.config'));
      env.putIfAbsent(
        'XDG_DATA_HOME',
        () => p.posix.join(home, '.local', 'share'),
      );
    }
    return LinuxCleanerPlatform._(
      env,
      rules ?? linuxCleanupRules,
      rulesVersion,
    );
  }

  LinuxCleanerPlatform._(
    this.environment,
    List<CleanerRule> rules,
    this._rulesVersion,
  ) : _rules = List.unmodifiable(rules) {
    _resolver = PosixRuleResolver(environment: environment);
  }

  @override
  final Map<String, String> environment;
  late final PosixRuleResolver _resolver;
  final List<CleanerRule> _rules;
  final String _rulesVersion;

  @override
  bool get isSupported => Platform.isLinux;

  @override
  String get displayName => 'Linux';

  @override
  PathSemantics get pathSemantics => const PosixPathSemantics();

  @override
  List<String> get protectedRoots => const [
    '/usr',
    '/etc',
    '/boot',
    '/dev',
    '/proc',
    '/sys',
    '/run',
    '/bin',
    '/sbin',
    '/lib',
    '/lib64',
    '/opt',
    '/var',
    '/snap',
    '/nix',
  ];

  @override
  List<CleanerRule> get rules => _rules;

  @override
  String get rulesVersion => _rulesVersion;

  @override
  String? get quarantineRoot {
    final dataHome = _absoluteDirectory(_lookup('XDG_DATA_HOME'));
    if (dataHome != null) {
      return p.posix.join(dataHome, 'Broom', 'quarantine');
    }
    final home = _lookup('HOME');
    if (home == null) return null;
    return p.posix.join(home, '.local', 'share', 'Broom', 'quarantine');
  }

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) =>
      _resolver.resolve(rule);

  String? _lookup(String name) => _nonEmpty(environment[name]);

  String? _absoluteDirectory(String? path) {
    if (path == null || !p.posix.isAbsolute(path)) return null;
    return p.posix.normalize(path);
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}

class UnsupportedCleanerPlatform implements CleanerPlatform {
  const UnsupportedCleanerPlatform();

  @override
  String get displayName => Platform.operatingSystem;

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => false;

  @override
  String? get quarantineRoot => null;

  @override
  PathSemantics get pathSemantics => PathSemanticsFactory.forCurrentPlatform();

  @override
  List<String> get protectedRoots => const [];

  @override
  List<CleanerRule> get rules => const [];

  @override
  String get rulesVersion => 'builtin';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

CleanerPlatform createCleanerPlatform() {
  if (Platform.isWindows) return WindowsCleanerPlatform();
  if (Platform.isLinux) return LinuxCleanerPlatform();
  return const UnsupportedCleanerPlatform();
}
